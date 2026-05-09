const std = @import("std");

pub const common = @import("common.zig");
pub const pnm = @import("pnm.zig");
pub const y4m = @import("y4m.zig");
pub const yuv = @import("yuv.zig");

pub const Image = common.Image;
pub const ImageKind = common.ImageKind;
pub const BitDepth = common.BitDepth;
pub const Chroma = common.Chroma;
pub const YuvFrame = yuv.Frame;

pub const DecodeStillOptions = struct {
    max_file_size: usize = 512 * 1024 * 1024,
};

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
    options: DecodeStillOptions,
) !Image {
    return pnm.decodeFile(sys_io, allocator, filename, options.max_file_size);
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
    options: DecodeStillOptions,
) !Image {
    return pnm.decodePamFile(sys_io, allocator, filename, options.max_file_size);
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
    options: DecodeStillOptions,
) !Image {
    return pnm.decodePpmFile(sys_io, allocator, filename, options.max_file_size);
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

test {
    std.testing.refAllDecls(@This());
}
