const std = @import("std");

pub const common = @import("common.zig");
pub const pnm = @import("pnm.zig");
pub const qoi = @import("qoi.zig");
pub const y4m = @import("y4m.zig");
pub const yuv = @import("yuv.zig");

pub const Image = common.Image;
pub const ImageKind = common.ImageKind;
pub const BitDepth = common.BitDepth;
pub const Chroma = common.Chroma;
pub const YuvFrame = yuv.Frame;

pub const MAX_FILE_SZ: usize = 512 * 1024 * 1024;
pub const RawYuvOptions = yuv.DecodeOptions;

pub fn decodePnmBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !Image {
    return pnm.decodeBytes(allocator, bytes);
}

pub fn decodePnmFile(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
) !Image {
    return pnm.decodeFile(sys_io, allocator, filename, MAX_FILE_SZ);
}

pub fn decodePamBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !Image {
    return pnm.decodePamBytes(allocator, bytes);
}

pub fn decodePamFile(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
) !Image {
    return pnm.decodePamFile(sys_io, allocator, filename, MAX_FILE_SZ);
}

pub fn decodePpmBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !Image {
    return pnm.decodePpmBytes(allocator, bytes);
}

pub fn decodePpmFile(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
) !Image {
    return pnm.decodePpmFile(sys_io, allocator, filename, MAX_FILE_SZ);
}

pub fn decodeQoiBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !Image {
    return qoi.decodeBytes(allocator, bytes);
}

pub fn decodeQoiFile(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
) !Image {
    return qoi.decodeFile(sys_io, allocator, filename, MAX_FILE_SZ);
}

pub fn decodeYuv420Bytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: RawYuvOptions,
) !YuvFrame {
    return yuv.decode420Bytes(allocator, bytes, options);
}

pub fn decodeYuv420File(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
    options: RawYuvOptions,
) !YuvFrame {
    return yuv.decode420File(sys_io, allocator, filename, options);
}

pub const Y4mDecoder = y4m.Decoder;
pub const Y4mMemoryDecoder = y4m.MemoryDecoder;

pub const YuvRgbConverter = @import("yuv_rgb.zig").Converter;

test {
    std.testing.refAllDecls(@This());
}

test "file helpers preserve decoded pixels" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rgb = &[_]u8{ 255, 0, 0, 0, 255, 0 };
    const encoded_qoi = try @import("qoilib").encQoi(allocator, rgb, 2, 1, 3, .{});
    defer allocator.free(encoded_qoi);
    const fixtures = .{
        .{ "input.pnm", "P6\n2 1\n255\n" ++ rgb.*, decodePnmFile },
        .{ "input.ppm", "P6\n2 1\n255\n" ++ rgb.*, decodePpmFile },
        .{ "input.pam", "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 3\nMAXVAL 255\nTUPLTYPE RGB\nENDHDR\n" ++ rgb.*, decodePamFile },
        .{ "input.qoi", encoded_qoi, decodeQoiFile },
    };
    inline for (fixtures) |fixture| {
        try tmp.dir.writeFile(io, .{ .sub_path = fixture[0], .data = fixture[1] });
        const path = try tmp.dir.realPathFileAlloc(io, fixture[0], allocator);
        defer allocator.free(path);
        var image = try fixture[2](io, allocator, path);
        defer image.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), image.width);
        try std.testing.expectEqual(@as(usize, 1), image.height);
        try std.testing.expectEqualSlices(u8, rgb, image.data);
    }

    const raw = &[_]u8{ 1, 2, 3, 4, 5, 6 };
    try tmp.dir.writeFile(io, .{ .sub_path = "input.yuv", .data = raw });
    const path = try tmp.dir.realPathFileAlloc(io, "input.yuv", allocator);
    defer allocator.free(path);
    var frame = try decodeYuv420File(io, allocator, path, .{ .width = 2, .height = 2 });
    defer frame.deinit(allocator);
    try std.testing.expectEqualSlices(u8, raw[0..4], frame.y);
    try std.testing.expectEqualSlices(u8, raw[4..5], frame.u);
    try std.testing.expectEqualSlices(u8, raw[5..6], frame.v);
}
