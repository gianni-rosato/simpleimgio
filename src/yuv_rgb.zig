const std = @import("std");
const yuv = @import("yuv.zig");

pub const Converter = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    horizontal: []f32,
    gamma: [4097]f32,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Converter {
        if (width == 0 or height == 0) return error.InvalidDimensions;
        const count = try std.math.mul(usize, width, try std.math.mul(usize, (height + 1) / 2, 2));
        var self: Converter = .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .horizontal = try allocator.alloc(f32, count),
            .gamma = undefined,
        };
        for (&self.gamma, 0..) |*v, i| v.* = std.math.pow(f32, @as(f32, @floatFromInt(i)) / 4096.0, if (height > 650) 2.4 else 2.6);
        return self;
    }

    pub fn deinit(self: *Converter) void {
        self.allocator.free(self.horizontal);
        self.* = undefined;
    }

    pub fn convert(self: *Converter, frame: yuv.Frame, rgb: []f32) !void {
        if (frame.width != self.width or frame.height != self.height) return error.DimensionMismatch;
        if (frame.chroma != .yuv420) return error.UnsupportedChroma;
        if (rgb.len != self.width * self.height * 3) return error.BadImageData;
        const bits: u5 = @intCast(@intFromEnum(frame.bit_depth));
        const bytes: usize = if (bits == 8) 1 else 2;
        const cw = (self.width + 1) / 2;
        const ch = (self.height + 1) / 2;
        if (frame.y.len != self.width * self.height * bytes or frame.u.len != cw * ch * bytes or frame.v.len != cw * ch * bytes) return error.BadPlaneSize;
        const full = frame.color_range == .full;
        const scale: f32 = @floatFromInt(@as(u32, 1) << (bits - 8));
        const peak: f32 = @floatFromInt((@as(u32, 1) << bits) - 1);
        const yoff: f32 = if (full) 0 else 16 * scale;
        const yscale: f32 = 1 / (if (full) peak else 219 * scale);
        const coff: f32 = if (full) peak * 0.5 else 128 * scale;
        const cscale: f32 = 1 / (if (full) peak else 224 * scale);
        const center = frame.chroma_location == .center;
        const top = frame.chroma_location == .top_left;
        const planes = [_][]const u8{ frame.u, frame.v };
        for (planes, 0..) |plane, c| {
            for (0..ch) |yy| {
                for (0..self.width) |xx| {
                    const pos = (@as(f32, @floatFromInt(xx)) - @as(f32, if (center) 0.5 else 0)) * 0.5;
                    const base: isize = @intFromFloat(@floor(pos));
                    var p: [4]f32 = undefined;
                    for (&p, 0..) |*v, k| {
                        const x: usize = @intCast(std.math.clamp(base + @as(isize, @intCast(k)) - 1, 0, @as(isize, @intCast(cw)) - 1));
                        v.* = (sample(plane, yy * cw + x, bytes) - coff) * cscale;
                    }
                    self.horizontal[(c * ch + yy) * self.width + xx] = cubic(p, pos - @floor(pos));
                }
            }
        }
        const kr: f32 = if (self.height > 650) 0.2126 else 0.299;
        const kb: f32 = if (self.height > 650) 0.0722 else 0.114;
        for (0..self.height) |yy| {
            const pos = (@as(f32, @floatFromInt(yy)) - @as(f32, if (top) 0 else 0.5)) * 0.5;
            const base: isize = @intFromFloat(@floor(pos));
            var rows: [4]usize = undefined;
            for (&rows, 0..) |*v, k| v.* = @intCast(std.math.clamp(base + @as(isize, @intCast(k)) - 1, 0, @as(isize, @intCast(ch)) - 1));
            for (0..self.width) |xx| {
                var uv: [2]f32 = undefined;
                for (&uv, 0..) |*v, c| {
                    var p: [4]f32 = undefined;
                    for (&p, rows) |*a, row| a.* = self.horizontal[(c * ch + row) * self.width + xx];
                    v.* = cubic(p, pos - @floor(pos));
                }
                const i = yy * self.width + xx;
                const y = (sample(frame.y, i, bytes) - yoff) * yscale;
                const r = y + 2 * (1 - kr) * uv[1];
                const b = y + 2 * (1 - kb) * uv[0];
                const g = (y - kr * r - kb * b) / (1 - kr - kb);
                const lr = self.linear(r);
                const lg = self.linear(g);
                const lb = self.linear(b);
                rgb[i * 3] = lr;
                rgb[i * 3 + 1] = lg;
                rgb[i * 3 + 2] = lb;
                if (self.height <= 650) {
                    rgb[i * 3] = 1.04375680 * lr - 0.0439694773 * lg - 0.0000922670094 * lb;
                    rgb[i * 3 + 1] = 0.000131826807 * lr + 0.999990747 * lg + 0.00000768246702 * lb;
                    rgb[i * 3 + 2] = 0.0000418516525 * lr + 0.0118355748 * lg + 0.988007223 * lb;
                }
            }
        }
    }

    fn linear(self: *const Converter, value: f32) f32 {
        const x = std.math.clamp(value, 0, 1) * 4096;
        const i: usize = @min(@as(usize, @intFromFloat(x)), 4095);
        const t = x - @as(f32, @floatFromInt(i));
        return self.gamma[i] + t * (self.gamma[i + 1] - self.gamma[i]);
    }
};

fn sample(plane: []const u8, i: usize, bytes: usize) f32 {
    return @floatFromInt(if (bytes == 1) @as(u16, plane[i]) else std.mem.readInt(u16, plane[i * 2 ..][0..2], .little));
}

fn cubic(p: [4]f32, t: f32) f32 {
    const m0 = (p[2] - p[0]) * 0.5;
    const m1 = (p[3] - p[1]) * 0.5;
    return ((2 * p[1] + m0 - 2 * p[2] + m1) * t + (-3 * p[1] + 3 * p[2] - 2 * m0 - m1)) * t * t + m0 * t + p[1];
}

test "limited and full range neutral ramps retain high bit depth" {
    const allocator = std.testing.allocator;
    var converter = try Converter.init(allocator, 2, 2);
    defer converter.deinit();
    var rgb: [12]f32 = undefined;
    var frame = try yuv.decode420Bytes(allocator, &.{ 16, 235, 126, 127, 128, 128 }, .{ .width = 2, .height = 2 });
    defer frame.deinit(allocator);
    try converter.convert(frame, &rgb);
    try std.testing.expectEqual(@as(f32, 0), rgb[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99969506), rgb[3], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16685293), rgb[6], 0.000001);
    frame.color_range = .full;
    try converter.convert(frame, &rgb);
    try std.testing.expectApproxEqAbs(@as(f32, 0.00084222), rgb[0], 0.000001);
    var ten = try yuv.decode420Bytes(allocator, &.{ 64, 0, 172, 3, 245, 1, 246, 1, 0, 2, 0, 2 }, .{ .width = 2, .height = 2, .bit_depth = .b10 });
    defer ten.deinit(allocator);
    try converter.convert(ten, &rgb);
    try std.testing.expectEqual(@as(f32, 0), rgb[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99969506), rgb[3], 0.000001);
    try std.testing.expect(rgb[9] > rgb[6]);
}

test "centered cubic chroma uses fractional sample positions" {
    const allocator = std.testing.allocator;
    var converter = try Converter.init(allocator, 4, 2);
    defer converter.deinit();
    var frame = try yuv.decode420Bytes(allocator, &.{ 126, 126, 126, 126, 126, 126, 126, 126, 112, 144, 128, 128 }, .{ .width = 4, .height = 2, .chroma_location = .center });
    defer frame.deinit(allocator);
    var rgb: [24]f32 = undefined;
    try converter.convert(frame, &rgb);
    try std.testing.expectApproxEqAbs(@as(f32, 0.11033326), rgb[5], 0.000001);
    const center = rgb[5];
    frame.chroma_location = .left;
    try converter.convert(frame, &rgb);
    try std.testing.expect(rgb[5] > center);
}

test "transfer lookup agrees with SDR gamma across 16 bit input" {
    for ([_]usize{ 1, 720 }) |height| {
        var converter = try Converter.init(std.testing.allocator, 1, height);
        defer converter.deinit();
        for (0..65536) |i| {
            const x = @as(f32, @floatFromInt(i)) / 65535;
            try std.testing.expectApproxEqAbs(std.math.pow(f32, x, if (height > 650) 2.4 else 2.6), converter.linear(x), 0.000001);
        }
    }
}

test "odd dimensions and top-left chroma" {
    const allocator = std.testing.allocator;
    var converter = try Converter.init(allocator, 3, 3);
    defer converter.deinit();
    var frame = try yuv.decode420Bytes(allocator, &.{ 126, 126, 126, 126, 126, 126, 126, 126, 126, 112, 144, 144, 112, 128, 128, 128, 128 }, .{ .width = 3, .height = 3, .chroma_location = .top_left });
    defer frame.deinit(allocator);
    var rgb: [27]f32 = undefined;
    try converter.convert(frame, &rgb);
    try std.testing.expectApproxEqAbs(@as(f32, 0.07975806), rgb[2], 0.000001);
    try std.testing.expectApproxEqAbs(rgb[2], rgb[26], 0.000001);
    try std.testing.expectError(error.BadImageData, converter.convert(frame, rgb[0..3]));
}
