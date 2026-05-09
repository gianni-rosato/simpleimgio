const std = @import("std");
const common = @import("common.zig");
const yuv = @import("yuv.zig");

pub const Chroma = common.Chroma;
pub const BitDepth = common.BitDepth;
pub const Frame = yuv.Frame;

pub const Header = struct {
    width: usize,
    height: usize,
    fps_num: u32 = 0,
    fps_den: u32 = 1,
    chroma: Chroma = .yuv420,
    bit_depth: BitDepth = .b8,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    sys_io: std.Io,
    owns_file: bool = false,
    reader: std.Io.File.Reader,
    reader_buffer: []u8,

    header: Header,
    frame_bytes: usize,

    line_buf: [4096]u8,

    pub fn init(allocator: std.mem.Allocator, sys_io: std.Io, file: std.Io.File) !Decoder {
        const reader_buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(reader_buffer);

        var d: Decoder = .{
            .allocator = allocator,
            .file = file,
            .sys_io = sys_io,
            .owns_file = false,
            .reader_buffer = reader_buffer,
            .reader = undefined,
            .header = .{ .width = 0, .height = 0 },
            .frame_bytes = 0,
            .line_buf = undefined,
        };

        d.reader = file.readerStreaming(sys_io, d.reader_buffer);

        const line = (try d.readLineOrEof()) orelse return error.UnexpectedEof;
        d.header = try parseStreamHeader(line);
        d.frame_bytes = computeFrameBytes(d.header);

        return d;
    }

    pub fn deinit(self: *Decoder) void {
        if (self.owns_file) self.file.close(self.sys_io);
        self.allocator.free(self.reader_buffer);
        self.* = undefined;
    }

    pub fn readFrame(self: *Decoder) !?Frame {
        const line = try self.readLineOrEof();
        if (line == null) return null;
        if (!std.mem.startsWith(u8, line.?, "FRAME")) return error.BadFrameMarker;
        return try readFramePayload(self.allocator, self.header, &self.reader.interface);
    }

    fn readLineOrEof(self: *Decoder) !?[]const u8 {
        const line = self.reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => return error.LineTooLong,
        };
        if (line == null) return null;
        if (line.?.len > self.line_buf.len) return error.LineTooLong;
        @memcpy(self.line_buf[0..line.?.len], line.?);
        return self.line_buf[0..line.?.len];
    }
};

pub const MemoryDecoder = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pos: usize = 0,
    header: Header,
    frame_bytes: usize,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !MemoryDecoder {
        var d: MemoryDecoder = .{
            .allocator = allocator,
            .bytes = bytes,
            .header = .{ .width = 0, .height = 0 },
            .frame_bytes = 0,
        };
        const line = (try d.readLineOrEof()) orelse return error.UnexpectedEof;
        d.header = try parseStreamHeader(line);
        d.frame_bytes = computeFrameBytes(d.header);
        return d;
    }

    pub fn readFrame(self: *MemoryDecoder) !?Frame {
        const line = try self.readLineOrEof();
        if (line == null) return null;
        if (!std.mem.startsWith(u8, line.?, "FRAME")) return error.BadFrameMarker;

        const end = try common.checkedAdd(self.pos, self.frame_bytes);
        if (end > self.bytes.len) return error.UnexpectedEof;
        const frame = try frameFromBytes(self.allocator, self.header, self.bytes[self.pos..end]);
        self.pos = end;
        return frame;
    }

    fn readLineOrEof(self: *MemoryDecoder) !?[]const u8 {
        if (self.pos >= self.bytes.len) return null;
        const start = self.pos;
        const newline = std.mem.indexOfScalarPos(u8, self.bytes, self.pos, '\n') orelse
            return error.UnexpectedEof;
        self.pos = newline + 1;
        return self.bytes[start..newline];
    }
};

pub fn decodeFile(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
) !Decoder {
    const file = try std.Io.Dir.cwd().openFile(sys_io, filename, .{});
    errdefer file.close(sys_io);
    var decoder = try Decoder.init(allocator, sys_io, file);
    decoder.owns_file = true;
    return decoder;
}

fn parseStreamHeader(line: []const u8) !Header {
    if (!std.mem.startsWith(u8, line, "YUV4MPEG2")) return error.NotY4M;

    var header: Header = .{ .width = 0, .height = 0 };
    var have_w = false;
    var have_h = false;

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const magic = it.next() orelse return error.NotY4M;
    if (!std.mem.eql(u8, magic, "YUV4MPEG2")) return error.NotY4M;

    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        switch (tok[0]) {
            'W' => {
                header.width = try parseUsize(tok[1..]);
                have_w = true;
            },
            'H' => {
                header.height = try parseUsize(tok[1..]);
                have_h = true;
            },
            'F' => {
                const frac = tok[1..];
                const colon = std.mem.indexOfScalar(u8, frac, ':') orelse return error.BadFps;
                header.fps_num = try parseU32(frac[0..colon]);
                header.fps_den = try parseU32(frac[colon + 1 ..]);
                if (header.fps_den == 0) return error.BadFps;
            },
            'I' => {
                if (tok.len < 2) return error.BadInterlace;
                if (tok[1] != 'p') return error.UnsupportedInterlace;
            },
            'C' => try parseChromaToken(&header, tok[1..]),
            else => {},
        }
    }

    if (!have_w or !have_h) return error.MissingDimensions;
    if (header.width == 0 or header.height == 0) return error.InvalidDimensions;
    return header;
}

fn parseChromaToken(header: *Header, ctoken: []const u8) !void {
    if (!std.mem.startsWith(u8, ctoken, "420")) return error.UnsupportedChroma;

    header.chroma = .yuv420;
    if (indexOfAsciiNoCase(ctoken, "p9") != null)
        header.bit_depth = .b9
    else if (indexOfAsciiNoCase(ctoken, "p10") != null)
        header.bit_depth = .b10
    else if (indexOfAsciiNoCase(ctoken, "p12") != null)
        header.bit_depth = .b12
    else if (indexOfAsciiNoCase(ctoken, "p16") != null)
        header.bit_depth = .b16
    else
        header.bit_depth = .b8;
}

fn readFramePayload(allocator: std.mem.Allocator, header: Header, reader: *std.Io.Reader) !Frame {
    const total = computeFrameBytes(header);
    const mem = try allocator.alloc(u8, total);
    errdefer allocator.free(mem);

    reader.readSliceAll(mem) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.UnexpectedEof,
    };

    return frameFromOwnedMemory(header, mem);
}

fn frameFromBytes(allocator: std.mem.Allocator, header: Header, bytes: []const u8) !Frame {
    const mem = try allocator.alloc(u8, bytes.len);
    errdefer allocator.free(mem);
    @memcpy(mem, bytes);
    return frameFromOwnedMemory(header, mem);
}

fn frameFromOwnedMemory(header: Header, mem: []u8) Frame {
    const y_bytes = common.planeBytes(header.bit_depth, header.width, header.height);
    const cw = common.chromaWidth(header.width, header.chroma);
    const ch = common.chromaHeight(header.height, header.chroma);
    const c_bytes = common.planeBytes(header.bit_depth, cw, ch);
    const total = y_bytes + c_bytes + c_bytes;

    return .{
        .width = header.width,
        .height = header.height,
        .chroma = header.chroma,
        .bit_depth = header.bit_depth,
        .y = mem[0..y_bytes],
        .u = mem[y_bytes .. y_bytes + c_bytes],
        .v = mem[y_bytes + c_bytes .. total],
        .backing_mem = mem,
    };
}

fn computeFrameBytes(header: Header) usize {
    const yb = common.planeBytes(header.bit_depth, header.width, header.height);
    const cw = common.chromaWidth(header.width, header.chroma);
    const ch = common.chromaHeight(header.height, header.chroma);
    const cb = common.planeBytes(header.bit_depth, cw, ch);
    return yb + cb + cb;
}

fn parseUsize(s: []const u8) !usize {
    if (s.len == 0) return error.BadNumber;
    return std.fmt.parseInt(usize, s, 10) catch return error.BadNumber;
}

fn parseU32(s: []const u8) !u32 {
    if (s.len == 0) return error.BadNumber;
    return std.fmt.parseInt(u32, s, 10) catch return error.BadNumber;
}

fn indexOfAsciiNoCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const a = std.ascii.toLower(haystack[i + j]);
            const b = std.ascii.toLower(needle[j]);
            if (a != b) {
                ok = false;
                break;
            }
        }
        if (ok) return i;
    }
    return null;
}

test "decode multiple y4m frames from memory" {
    const allocator = std.testing.allocator;
    const stream =
        "YUV4MPEG2 W2 H2 F30:1 Ip C420jpeg\n" ++
        "FRAME\n" ++
        "\x01\x02\x03\x04\x05\x06" ++
        "FRAME\n" ++
        "\x07\x08\x09\x0a\x0b\x0c";

    var decoder = try MemoryDecoder.init(allocator, stream);
    try std.testing.expectEqual(@as(usize, 2), decoder.header.width);
    try std.testing.expectEqual(@as(u32, 30), decoder.header.fps_num);

    var first = (try decoder.readFrame()).?;
    defer first.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, first.y);
    try std.testing.expectEqualSlices(u8, &[_]u8{5}, first.u);

    var second = (try decoder.readFrame()).?;
    defer second.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 7, 8, 9, 10 }, second.y);
    try std.testing.expectEqual(@as(?Frame, null), try decoder.readFrame());
}

test "decode first y4m frame from file-backed decoder" {
    const allocator = std.testing.allocator;
    const sys_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stream =
        "YUV4MPEG2 W2 H2 F25:1 Ip A1:1 C420p10 XYSCSS=420P10\n" ++
        "FRAME\n" ++
        "\x00\x01\x00\x02\x00\x03\x00\x04" ++
        "\x00\x05" ++
        "\x00\x06";

    const file = try tmp.dir.createFile(sys_io, "first-frame.y4m", .{ .read = true });
    defer file.close(sys_io);
    try file.writePositionalAll(sys_io, stream, 0);

    var decoder = try Decoder.init(allocator, sys_io, file);
    defer decoder.deinit();

    try std.testing.expectEqual(@as(usize, 2), decoder.header.width);
    try std.testing.expectEqual(@as(usize, 2), decoder.header.height);
    try std.testing.expectEqual(BitDepth.b10, decoder.header.bit_depth);

    var frame = (try decoder.readFrame()).?;
    defer frame.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "\x00\x01\x00\x02\x00\x03\x00\x04", frame.y);
    try std.testing.expectEqualSlices(u8, "\x00\x05", frame.u);
    try std.testing.expectEqualSlices(u8, "\x00\x06", frame.v);
    try std.testing.expectEqual(@as(?Frame, null), try decoder.readFrame());
}
