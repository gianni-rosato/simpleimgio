const std = @import("std");
const common = @import("common.zig");

pub const Image = common.Image;
pub const ImageKind = common.ImageKind;

pub fn decodeBytes(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    var parser: Parser = .{ .bytes = bytes };
    const magic = try parser.nextToken();
    if (magic.len != 2 or magic[0] != 'P') return error.NotPnm;

    return switch (magic[1]) {
        '1' => decodePbmAscii(allocator, &parser),
        '2' => decodeGrayOrRgbAscii(allocator, &parser, .grayscale),
        '3' => decodeGrayOrRgbAscii(allocator, &parser, .rgb),
        '4' => decodePbmBinary(allocator, &parser),
        '5' => decodeGrayOrRgbBinary(allocator, &parser, .grayscale),
        '6' => decodeGrayOrRgbBinary(allocator, &parser, .rgb),
        '7' => decodePam(allocator, bytes),
        else => error.UnsupportedPnmMagic,
    };
}

pub fn decodeFile(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
    max_size: usize,
) !Image {
    const bytes = try common.readFileAlloc(sys_io, allocator, filename, max_size);
    defer allocator.free(bytes);
    return decodeBytes(allocator, bytes);
}

pub fn decodePpmBytes(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    if (!std.mem.startsWith(u8, bytes, "P3") and !std.mem.startsWith(u8, bytes, "P6"))
        return error.NotPpm;
    return decodeBytes(allocator, bytes);
}

pub fn decodePamBytes(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    if (!std.mem.startsWith(u8, bytes, "P7")) return error.NotPam;
    return decodeBytes(allocator, bytes);
}

pub fn decodePpmFile(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
    max_size: usize,
) !Image {
    const bytes = try common.readFileAlloc(sys_io, allocator, filename, max_size);
    defer allocator.free(bytes);
    return decodePpmBytes(allocator, bytes);
}

pub fn decodePamFile(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
    max_size: usize,
) !Image {
    const bytes = try common.readFileAlloc(sys_io, allocator, filename, max_size);
    defer allocator.free(bytes);
    return decodePamBytes(allocator, bytes);
}

fn decodePbmAscii(allocator: std.mem.Allocator, parser: *Parser) !Image {
    const width = try parseDimension(try parser.nextToken());
    const height = try parseDimension(try parser.nextToken());
    const samples = try common.checkedMul(width, height);
    const data = try allocator.alloc(u8, samples);
    errdefer allocator.free(data);

    for (data) |*dst| {
        dst.* = @intCast(try parseSample(try parser.nextToken(), 1));
    }

    return .{
        .width = width,
        .height = height,
        .depth = 1,
        .maxval = 1,
        .kind = .bitmap,
        .data = data,
    };
}

fn decodePbmBinary(allocator: std.mem.Allocator, parser: *Parser) !Image {
    const width = try parseDimension(try parser.nextToken());
    const height = try parseDimension(try parser.nextToken());
    try parser.consumeRasterSeparator();

    const row_bytes = (width + 7) / 8;
    const input_len = try common.checkedMul(row_bytes, height);
    const end = try common.checkedAdd(parser.pos, input_len);
    if (end > parser.bytes.len) return error.InsufficientData;

    const samples = try common.checkedMul(width, height);
    const data = try allocator.alloc(u8, samples);
    errdefer allocator.free(data);

    for (0..height) |y| {
        for (0..width) |x| {
            const packed_byte = parser.bytes[parser.pos + y * row_bytes + x / 8];
            const bit: u3 = @intCast(7 - (x & 7));
            data[y * width + x] = @intCast((packed_byte >> bit) & 1);
        }
    }

    parser.pos = end;
    return .{
        .width = width,
        .height = height,
        .depth = 1,
        .maxval = 1,
        .kind = .bitmap,
        .data = data,
    };
}

fn decodeGrayOrRgbAscii(allocator: std.mem.Allocator, parser: *Parser, kind: ImageKind) !Image {
    const width = try parseDimension(try parser.nextToken());
    const height = try parseDimension(try parser.nextToken());
    const maxval = try parseMaxval(try parser.nextToken());
    const depth = depthForKind(kind);
    const samples = try common.checkedMul(try common.checkedMul(width, height), depth);
    const bytes_per_sample: usize = if (maxval <= 255) 1 else 2;
    const data = try allocator.alloc(u8, try common.checkedMul(samples, bytes_per_sample));
    errdefer allocator.free(data);

    if (maxval <= 255) {
        for (0..samples) |i| {
            data[i] = @intCast(try parseSample(try parser.nextToken(), maxval));
        }
    } else {
        for (0..samples) |i| {
            const sample: u16 = @intCast(try parseSample(try parser.nextToken(), maxval));
            std.mem.writeInt(u16, @as(*[2]u8, @ptrCast(&data[i * 2])), sample, .big);
        }
    }

    return .{
        .width = width,
        .height = height,
        .depth = depth,
        .maxval = @intCast(maxval),
        .kind = kind,
        .data = data,
    };
}

fn decodeGrayOrRgbBinary(allocator: std.mem.Allocator, parser: *Parser, kind: ImageKind) !Image {
    const width = try parseDimension(try parser.nextToken());
    const height = try parseDimension(try parser.nextToken());
    const maxval = try parseMaxval(try parser.nextToken());
    try parser.consumeRasterSeparator();

    const depth = depthForKind(kind);
    const samples = try common.checkedMul(try common.checkedMul(width, height), depth);
    const bytes_per_sample: usize = if (maxval <= 255) 1 else 2;
    const input_len = try common.checkedMul(samples, bytes_per_sample);
    const end = try common.checkedAdd(parser.pos, input_len);
    if (end > parser.bytes.len) return error.InsufficientData;

    const data = try allocator.alloc(u8, input_len);
    errdefer allocator.free(data);
    @memcpy(data, parser.bytes[parser.pos..end]);
    try validateSamples(data, samples, @intCast(maxval));

    parser.pos = end;
    return .{
        .width = width,
        .height = height,
        .depth = depth,
        .maxval = @intCast(maxval),
        .kind = kind,
        .data = data,
    };
}

fn decodePam(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    if (!std.mem.startsWith(u8, bytes, "P7")) return error.NotPam;
    const end_header =
        std.mem.indexOf(u8, bytes, "ENDHDR\n") orelse
        std.mem.indexOf(u8, bytes, "ENDHDR\r\n") orelse
        return error.HeaderNotFound;

    const data_start = if (std.mem.startsWith(u8, bytes[end_header..], "ENDHDR\r\n"))
        end_header + "ENDHDR\r\n".len
    else
        end_header + "ENDHDR\n".len;

    var width: usize = 0;
    var height: usize = 0;
    var depth: u8 = 0;
    var maxval: u32 = 0;
    var kind: ImageKind = .pam;

    var lines = std.mem.tokenizeAny(u8, bytes[0..end_header], "\r\n");
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;

        var it = std.mem.tokenizeAny(u8, line, " \t");
        const key = it.next() orelse continue;
        const value = it.next() orelse continue;

        if (std.mem.eql(u8, key, "WIDTH")) {
            width = try parseDimension(value);
        } else if (std.mem.eql(u8, key, "HEIGHT")) {
            height = try parseDimension(value);
        } else if (std.mem.eql(u8, key, "DEPTH")) {
            const parsed = try parseDimension(value);
            if (parsed > std.math.maxInt(u8)) return error.InvalidDepth;
            depth = @intCast(parsed);
        } else if (std.mem.eql(u8, key, "MAXVAL")) {
            maxval = try parseMaxval(value);
        } else if (std.mem.eql(u8, key, "TUPLTYPE")) {
            kind = pamKind(value);
        }
    }

    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (depth == 0) return error.InvalidDepth;
    if (maxval == 0) return error.InvalidMaxval;

    const samples = try common.checkedMul(try common.checkedMul(width, height), depth);
    const bytes_per_sample: usize = if (maxval <= 255) 1 else 2;
    const input_len = try common.checkedMul(samples, bytes_per_sample);
    const end = try common.checkedAdd(data_start, input_len);
    if (end > bytes.len) return error.InsufficientData;

    const data = try allocator.alloc(u8, input_len);
    errdefer allocator.free(data);
    @memcpy(data, bytes[data_start..end]);
    try validateSamples(data, samples, @intCast(maxval));

    return .{
        .width = width,
        .height = height,
        .depth = depth,
        .maxval = @intCast(maxval),
        .kind = if (kind == .pam) kindFromDepth(depth) else kind,
        .data = data,
    };
}

fn validateSamples(data: []const u8, samples: usize, maxval: u16) !void {
    if (maxval <= 255) {
        if (data.len != samples) return error.BadImageData;
        for (data) |sample| {
            if (sample > maxval) return error.SampleOutOfRange;
        }
    } else {
        if (data.len != samples * 2) return error.BadImageData;
        for (0..samples) |i| {
            const sample = (@as(u16, data[i * 2]) << 8) | data[i * 2 + 1];
            if (sample > maxval) return error.SampleOutOfRange;
        }
    }
}

fn depthForKind(kind: ImageKind) u8 {
    return switch (kind) {
        .grayscale => 1,
        .rgb => 3,
        else => unreachable,
    };
}

fn pamKind(value: []const u8) ImageKind {
    if (std.mem.eql(u8, value, "BLACKANDWHITE")) return .bitmap;
    if (std.mem.eql(u8, value, "GRAYSCALE")) return .grayscale;
    if (std.mem.eql(u8, value, "GRAYSCALE_ALPHA")) return .grayscale_alpha;
    if (std.mem.eql(u8, value, "RGB")) return .rgb;
    if (std.mem.eql(u8, value, "RGB_ALPHA")) return .rgba;
    return .pam;
}

fn kindFromDepth(depth: u8) ImageKind {
    return switch (depth) {
        1 => .grayscale,
        2 => .grayscale_alpha,
        3 => .rgb,
        4 => .rgba,
        else => .pam,
    };
}

fn parseDimension(token: []const u8) !usize {
    if (token.len == 0) return error.BadNumber;
    const value = std.fmt.parseInt(usize, token, 10) catch return error.BadNumber;
    if (value == 0) return error.InvalidDimensions;
    return value;
}

fn parseMaxval(token: []const u8) !u32 {
    if (token.len == 0) return error.BadNumber;
    const value = std.fmt.parseInt(u32, token, 10) catch return error.BadNumber;
    if (value == 0 or value > 65535) return error.InvalidMaxval;
    return value;
}

fn parseSample(token: []const u8, maxval: u32) !u32 {
    if (token.len == 0) return error.BadNumber;
    const value = std.fmt.parseInt(u32, token, 10) catch return error.BadNumber;
    if (value > maxval) return error.SampleOutOfRange;
    return value;
}

const Parser = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn nextToken(self: *Parser) ![]const u8 {
        try self.skipWhitespaceAndComments();
        if (self.pos >= self.bytes.len) return error.UnexpectedEof;

        const start = self.pos;
        while (self.pos < self.bytes.len and !isWhitespace(self.bytes[self.pos])) {
            self.pos += 1;
        }
        return self.bytes[start..self.pos];
    }

    fn skipWhitespaceAndComments(self: *Parser) !void {
        while (self.pos < self.bytes.len) {
            if (isWhitespace(self.bytes[self.pos])) {
                self.pos += 1;
                continue;
            }
            if (self.bytes[self.pos] == '#') {
                while (self.pos < self.bytes.len and self.bytes[self.pos] != '\n') {
                    self.pos += 1;
                }
                continue;
            }
            break;
        }
    }

    fn consumeRasterSeparator(self: *Parser) !void {
        if (self.pos >= self.bytes.len or !isWhitespace(self.bytes[self.pos]))
            return error.MissingRasterSeparator;
        self.pos += 1;
    }
};

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

test "decode binary ppm" {
    const allocator = std.testing.allocator;
    var image = try decodeBytes(allocator, "P6\n2 1\n255\n" ++ "\xff\x00\x00\x00\xff\x00");
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), image.width);
    try std.testing.expectEqual(@as(usize, 1), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.depth);
    try std.testing.expectEqual(@as(u16, 255), image.maxval);
    try std.testing.expectEqual(.rgb, image.kind);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 0, 255, 0 }, image.data);
}

test "decode ascii ppm with comments preserving maxval" {
    const allocator = std.testing.allocator;
    var image = try decodeBytes(allocator,
        \\P3
        \\# comment
        \\1 1
        \\7
        \\0 7 3
        \\
    );
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 7), image.maxval);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 7, 3 }, image.data);

    var eight = try image.to8Bit(allocator);
    defer eight.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 109 }, eight.data);
}

test "decode pam with sixteen-bit samples preserving data" {
    const allocator = std.testing.allocator;
    var image = try decodeBytes(allocator, "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 3\nMAXVAL 65535\nTUPLTYPE RGB\nENDHDR\n" ++
        "\x00\x00\x80\x00\xff\xff");
    defer image.deinit(allocator);

    try std.testing.expectEqual(.rgb, image.kind);
    try std.testing.expectEqual(@as(u16, 65535), image.maxval);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x80, 0x00, 0xff, 0xff }, image.data);

    var eight = try image.to8Bit(allocator);
    defer eight.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 128, 255 }, eight.data);
}

test "decode binary pbm preserving bitmap values" {
    const allocator = std.testing.allocator;
    var image = try decodeBytes(allocator, "P4\n4 1\n" ++ "\xa0");
    defer image.deinit(allocator);

    try std.testing.expectEqual(.bitmap, image.kind);
    try std.testing.expectEqual(@as(u16, 1), image.maxval);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 1, 0 }, image.data);

    var eight = try image.to8Bit(allocator);
    defer eight.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, eight.data);
}
