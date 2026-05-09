const std = @import("std");
const common = @import("common.zig");
const qoilib = @import("qoilib");

pub const Image = common.Image;
pub const ImageKind = common.ImageKind;

pub fn decodeBytes(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    const decoded = try qoilib.decQoi(allocator, bytes);
    return .{
        .width = decoded.width,
        .height = decoded.height,
        .depth = decoded.channels,
        .maxval = 255,
        .kind = switch (decoded.channels) {
            3 => .rgb,
            4 => .rgba,
            else => return error.UnsupportedChannels,
        },
        .data = decoded.data,
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

test "decode qoi bytes" {
    const allocator = std.testing.allocator;
    const encoded = try qoilib.encQoi(allocator, &[_]u8{
        255, 0,   0,
        0,   255, 0,
    }, 2, 1, 3, .{});
    defer allocator.free(encoded);

    var image = try decodeBytes(allocator, encoded);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), image.width);
    try std.testing.expectEqual(@as(usize, 1), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.depth);
    try std.testing.expectEqual(@as(u16, 255), image.maxval);
    try std.testing.expectEqual(.rgb, image.kind);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        255, 0,   0,
        0,   255, 0,
    }, image.data);
}
