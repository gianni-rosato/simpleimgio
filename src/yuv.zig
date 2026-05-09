const std = @import("std");
const common = @import("common.zig");

pub const Chroma = common.Chroma;
pub const BitDepth = common.BitDepth;

pub const DecodeOptions = struct {
    width: usize,
    height: usize,
    bit_depth: BitDepth = .b8,
    has_alpha: bool = false,
    chroma: Chroma = .yuv420,
};

pub const Frame = struct {
    width: usize,
    height: usize,
    chroma: Chroma = .yuv420,
    bit_depth: BitDepth = .b8,

    y: []u8,
    u: []u8,
    v: []u8,
    a: ?[]u8 = null,

    backing_mem: ?[]u8 = null,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        if (self.backing_mem) |mem| {
            allocator.free(mem);
        } else {
            allocator.free(self.y);
            allocator.free(self.u);
            allocator.free(self.v);
            if (self.a) |alpha| allocator.free(alpha);
        }
        self.* = undefined;
    }

    pub fn yAsU16LE(self: Frame) ![]align(1) const u16 {
        return asU16LE(self.y, self.bit_depth);
    }

    pub fn uAsU16LE(self: Frame) ![]align(1) const u16 {
        return asU16LE(self.u, self.bit_depth);
    }

    pub fn vAsU16LE(self: Frame) ![]align(1) const u16 {
        return asU16LE(self.v, self.bit_depth);
    }

    pub fn aAsU16LE(self: Frame) !?[]align(1) const u16 {
        const alpha = self.a orelse return null;
        return try asU16LE(alpha, self.bit_depth);
    }

    pub fn to8Bit(self: Frame, allocator: std.mem.Allocator) !Frame {
        if (self.bit_depth == .b8) {
            const total = try self.totalBytes();
            const mem = try allocator.alloc(u8, total);
            errdefer allocator.free(mem);

            var offset: usize = 0;
            @memcpy(mem[offset .. offset + self.y.len], self.y);
            const y = mem[offset .. offset + self.y.len];
            offset += self.y.len;

            @memcpy(mem[offset .. offset + self.u.len], self.u);
            const u = mem[offset .. offset + self.u.len];
            offset += self.u.len;

            @memcpy(mem[offset .. offset + self.v.len], self.v);
            const v = mem[offset .. offset + self.v.len];
            offset += self.v.len;

            var a: ?[]u8 = null;
            if (self.a) |alpha| {
                @memcpy(mem[offset .. offset + alpha.len], alpha);
                a = mem[offset .. offset + alpha.len];
            }

            return .{
                .width = self.width,
                .height = self.height,
                .chroma = self.chroma,
                .bit_depth = .b8,
                .y = y,
                .u = u,
                .v = v,
                .a = a,
                .backing_mem = mem,
            };
        }

        const y_samples = self.width * self.height;
        const cw = common.chromaWidth(self.width, self.chroma);
        const ch = common.chromaHeight(self.height, self.chroma);
        const c_samples = cw * ch;
        const a_samples = if (self.a != null) y_samples else 0;
        const total = y_samples + c_samples + c_samples + a_samples;
        const mem = try allocator.alloc(u8, total);
        errdefer allocator.free(mem);

        var offset: usize = 0;
        const y = mem[offset .. offset + y_samples];
        offset += y_samples;
        const u = mem[offset .. offset + c_samples];
        offset += c_samples;
        const v = mem[offset .. offset + c_samples];
        offset += c_samples;
        const a = if (self.a != null) mem[offset .. offset + a_samples] else null;

        const bits: u5 = @intCast(@intFromEnum(self.bit_depth));
        requantizePlaneLE(y, self.y, bits);
        requantizePlaneLE(u, self.u, bits);
        requantizePlaneLE(v, self.v, bits);
        if (a) |dst_alpha| requantizePlaneLE(dst_alpha, self.a.?, bits);

        return .{
            .width = self.width,
            .height = self.height,
            .chroma = self.chroma,
            .bit_depth = .b8,
            .y = y,
            .u = u,
            .v = v,
            .a = a,
            .backing_mem = mem,
        };
    }

    fn totalBytes(self: Frame) !usize {
        var total = try common.checkedAdd(self.y.len, self.u.len);
        total = try common.checkedAdd(total, self.v.len);
        if (self.a) |alpha| total = try common.checkedAdd(total, alpha.len);
        return total;
    }
};

pub fn decode420Bytes(allocator: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) !Frame {
    if (options.width == 0 or options.height == 0) return error.InvalidDimensions;

    const y_samples = try common.checkedMul(options.width, options.height);
    const cw = common.chromaWidth(options.width, options.chroma);
    const ch = common.chromaHeight(options.height, options.chroma);
    const c_samples = try common.checkedMul(cw, ch);
    const a_samples = if (options.has_alpha) y_samples else 0;
    var sample_count = try common.checkedAdd(y_samples, c_samples);
    sample_count = try common.checkedAdd(sample_count, c_samples);
    sample_count = try common.checkedAdd(sample_count, a_samples);
    const total_bytes = try common.checkedMul(sample_count, common.bytesPerSample(options.bit_depth));
    if (bytes.len != total_bytes) return error.InvalidYuvFileSize;

    const mem = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(mem);
    @memcpy(mem, bytes);

    const y_bytes = y_samples * common.bytesPerSample(options.bit_depth);
    const c_bytes = c_samples * common.bytesPerSample(options.bit_depth);
    const a_bytes = a_samples * common.bytesPerSample(options.bit_depth);

    var offset: usize = 0;
    const y = mem[offset .. offset + y_bytes];
    offset += y_bytes;
    const u = mem[offset .. offset + c_bytes];
    offset += c_bytes;
    const v = mem[offset .. offset + c_bytes];
    offset += c_bytes;
    const a = if (options.has_alpha) mem[offset .. offset + a_bytes] else null;

    return .{
        .width = options.width,
        .height = options.height,
        .chroma = options.chroma,
        .bit_depth = options.bit_depth,
        .y = y,
        .u = u,
        .v = v,
        .a = a,
        .backing_mem = mem,
    };
}

pub fn decode420File(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
    options: DecodeOptions,
) !Frame {
    const expected = try expected420Bytes(options);
    const file = try std.Io.Dir.cwd().openFile(sys_io, filename, .{});
    defer file.close(sys_io);

    const file_size = try file.length(sys_io);
    if (file_size != expected) return error.InvalidYuvFileSize;

    const bytes = try allocator.alloc(u8, expected);
    defer allocator.free(bytes);
    const read = try file.readPositionalAll(sys_io, bytes, 0);
    if (read != expected) return error.UnexpectedEof;

    return decode420Bytes(allocator, bytes, options);
}

pub fn expected420Bytes(options: DecodeOptions) !usize {
    if (options.width == 0 or options.height == 0) return error.InvalidDimensions;

    const y_samples = try common.checkedMul(options.width, options.height);
    const c_samples = try common.checkedMul(
        common.chromaWidth(options.width, options.chroma),
        common.chromaHeight(options.height, options.chroma),
    );
    const a_samples = if (options.has_alpha) y_samples else 0;
    var sample_count = try common.checkedAdd(y_samples, c_samples);
    sample_count = try common.checkedAdd(sample_count, c_samples);
    sample_count = try common.checkedAdd(sample_count, a_samples);
    return common.checkedMul(sample_count, common.bytesPerSample(options.bit_depth));
}

fn asU16LE(bytes: []const u8, bit_depth: BitDepth) ![]align(1) const u16 {
    if (bit_depth == .b8) return error.WrongBitDepth;
    if ((bytes.len & 1) != 0) return error.BadPlaneSize;
    const ptr: [*]align(1) const u16 = @ptrCast(bytes.ptr);
    return ptr[0 .. bytes.len / 2];
}

fn requantizePlaneLE(dst: []u8, src: []const u8, bits: u5) void {
    for (dst, 0..) |*d, i| {
        const sample = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(&src[i * 2])), .little);
        d.* = common.requantizeBlinnish(@intCast(sample), bits);
    }
}

test "decode raw yuv420 frame" {
    const allocator = std.testing.allocator;
    var frame = try decode420Bytes(allocator, &[_]u8{ 1, 2, 3, 4, 5, 6 }, .{
        .width = 2,
        .height = 2,
    });
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.width);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, frame.y);
    try std.testing.expectEqualSlices(u8, &[_]u8{5}, frame.u);
    try std.testing.expectEqualSlices(u8, &[_]u8{6}, frame.v);
}

test "requantize high bit-depth raw yuv420 frame" {
    const allocator = std.testing.allocator;
    var frame = try decode420Bytes(allocator, &[_]u8{
        0x00, 0x00, 0xff, 0x03, 0x00, 0x02, 0x00, 0x01, 0xff, 0x03, 0x00, 0x00,
    }, .{
        .width = 2,
        .height = 2,
        .bit_depth = .b10,
    });
    defer frame.deinit(allocator);

    var eight = try frame.to8Bit(allocator);
    defer eight.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 128, 64 }, eight.y);
    try std.testing.expectEqualSlices(u8, &[_]u8{255}, eight.u);
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, eight.v);
}
