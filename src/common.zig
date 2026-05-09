const std = @import("std");

pub const ImageKind = enum {
    bitmap,
    grayscale,
    grayscale_alpha,
    rgb,
    rgba,
    pam,
};

pub const Image = struct {
    width: usize,
    height: usize,
    depth: u8,
    maxval: u16,
    kind: ImageKind,
    data: []u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }

    pub fn sampleCount(self: Image) !usize {
        return checkedMul(try checkedMul(self.width, self.height), self.depth);
    }

    pub fn bytesPerSample(self: Image) usize {
        return bytesPerNetpbmSample(self.maxval);
    }

    pub fn to8Bit(self: Image, allocator: std.mem.Allocator) !Image {
        const samples = try self.sampleCount();
        const data = try allocator.alloc(u8, samples);
        errdefer allocator.free(data);

        if (self.kind == .bitmap) {
            if (self.data.len != samples) return error.BadImageData;
            for (self.data, data) |src, *dst| {
                dst.* = if (src == 0) 255 else 0;
            }
        } else if (self.maxval <= 255) {
            if (self.data.len != samples) return error.BadImageData;
            for (self.data, data) |src, *dst| {
                dst.* = requantizeTo8(src, self.maxval);
            }
        } else {
            if (self.data.len != samples * 2) return error.BadImageData;
            for (data, 0..) |*dst, i| {
                const in_idx = i * 2;
                const sample = (@as(u16, self.data[in_idx]) << 8) | self.data[in_idx + 1];
                dst.* = requantizeTo8(sample, self.maxval);
            }
        }

        return .{
            .width = self.width,
            .height = self.height,
            .depth = self.depth,
            .maxval = 255,
            .kind = self.kind,
            .data = data,
        };
    }
};

pub const Chroma = enum {
    yuv420,
};

pub const BitDepth = enum(u8) {
    b8 = 8,
    b9 = 9,
    b10 = 10,
    b12 = 12,
    b16 = 16,

    pub fn fromInt(value: u8) !BitDepth {
        return switch (value) {
            8 => .b8,
            9 => .b9,
            10 => .b10,
            12 => .b12,
            16 => .b16,
            else => error.UnsupportedBitDepth,
        };
    }
};

pub inline fn bytesPerSample(bit_depth: BitDepth) usize {
    return switch (bit_depth) {
        .b8 => 1,
        .b9, .b10, .b12, .b16 => 2,
    };
}

pub inline fn planeBytes(bit_depth: BitDepth, width: usize, height: usize) usize {
    return width * height * bytesPerSample(bit_depth);
}

pub inline fn chromaWidth(width: usize, chroma: Chroma) usize {
    return switch (chroma) {
        .yuv420 => (width + 1) / 2,
    };
}

pub inline fn chromaHeight(height: usize, chroma: Chroma) usize {
    return switch (chroma) {
        .yuv420 => (height + 1) / 2,
    };
}

pub inline fn requantizeBlinnish(x: u32, fm_bits: u5) u8 {
    const to_N: u32 = 255;
    const fm_N: u32 = (@as(u32, 1) << fm_bits) - 1;
    const clamped = if (x > fm_N) fm_N else x;
    const half: u32 = @as(u32, 1) << (fm_bits - 1);
    const t = clamped * to_N + half;
    return @intCast((t + (t >> fm_bits)) >> fm_bits);
}

pub inline fn requantizeTo8(x: u32, maxval: u32) u8 {
    if (maxval == 0) return 0;
    return @intCast((@as(u64, @min(maxval, x)) * 255 + maxval / 2) / maxval);
}

pub inline fn bytesPerNetpbmSample(maxval: u16) usize {
    return if (maxval <= 255) 1 else 2;
}

pub fn checkedMul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch return error.ImageTooLarge;
}

pub fn checkedAdd(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch return error.ImageTooLarge;
}

pub fn readFileAlloc(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
    max_size: usize,
) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(sys_io, filename, .{});
    defer file.close(sys_io);

    const file_size_u64 = try file.length(sys_io);
    if (file_size_u64 > max_size) return error.FileTooLarge;
    if (file_size_u64 > std.math.maxInt(usize)) return error.FileTooLarge;

    const file_size: usize = @intCast(file_size_u64);
    const bytes = try allocator.alloc(u8, file_size);
    errdefer allocator.free(bytes);

    const read = try file.readPositionalAll(sys_io, bytes, 0);
    if (read != file_size) return error.UnexpectedEof;
    return bytes;
}
