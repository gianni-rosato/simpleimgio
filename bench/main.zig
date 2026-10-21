const std = @import("std");
const img = @import("simpleimgio");
const qoi = @import("qoilib");

const width = 1920;
const height = 1080;
const pixels = width * height;
const allocator = std.heap.page_allocator;

const Case = enum {
    ppm8,
    ppm16,
    pam16,
    pbm,
    qoi_noise,
    qoi_runs,
    yuv8,
    yuv10,
    yuva16,
    y4m_memory,
    y4m_file,
    ppm_file,
    yuv_file,
    image8_copy,
    image8_owned,
    image16_to8,
    yuv10_to8,
    rgb8,
    rgb10,
};

pub fn main(init: std.process.Init) !void {
    // Setup and fixture encoding are deliberately outside the timed regions.
    const rgb = try allocator.alloc(u8, pixels * 3);
    defer allocator.free(rgb);
    var rng = std.Random.DefaultPrng.init(42);
    rng.random().bytes(rgb);
    const ppm8 = try std.mem.concat(allocator, u8, &.{ "P6\n1920 1080\n255\n", rgb });
    defer allocator.free(ppm8);
    const samples16 = try allocator.alloc(u8, pixels * 6);
    defer allocator.free(samples16);
    rng.random().bytes(samples16);
    const ppm16 = try std.mem.concat(allocator, u8, &.{ "P6\n1920 1080\n65535\n", samples16 });
    defer allocator.free(ppm16);
    const pam16 = try std.mem.concat(allocator, u8, &.{ "P7\nWIDTH 1920\nHEIGHT 1080\nDEPTH 3\nMAXVAL 65535\nTUPLTYPE RGB\nENDHDR\n", samples16 });
    defer allocator.free(pam16);
    const pbm = try std.mem.concat(allocator, u8, &.{ "P4\n1920 1080\n", rgb[0 .. pixels / 8] });
    defer allocator.free(pbm);
    const qoi_noise = try qoi.encQoi(allocator, rgb, width, height, 3, .{});
    defer allocator.free(qoi_noise);
    @memset(rgb, 127);
    const qoi_runs = try qoi.encQoi(allocator, rgb, width, height, 3, .{});
    defer allocator.free(qoi_runs);

    const raw8 = try allocator.alloc(u8, pixels * 3 / 2);
    defer allocator.free(raw8);
    rng.random().bytes(raw8);
    const raw10 = try allocator.alloc(u8, pixels * 3);
    defer allocator.free(raw10);
    for (0..raw10.len / 2) |i| {
        std.mem.writeInt(u16, raw10[i * 2 ..][0..2], rng.random().int(u10), .little);
    }
    const raw16 = try allocator.alloc(u8, pixels * 5);
    defer allocator.free(raw16);
    rng.random().bytes(raw16);
    const y4m = try std.mem.concat(allocator, u8, &.{ "YUV4MPEG2 W1920 H1080 F24:1 Ip C420p10\nFRAME\n", raw10 });
    defer allocator.free(y4m);

    // Each process gets its own directory; remove it even if a benchmark fails.
    var name_buf: [80]u8 = undefined;
    const dirname = try std.fmt.bufPrint(&name_buf, ".simpleimgio-bench-{x}", .{std.Io.Timestamp.now(init.io, .real).nanoseconds});
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(init.io, dirname, .{});
    defer cwd.deleteTree(init.io, dirname) catch {};
    defer dir.close(init.io);
    try dir.writeFile(init.io, .{ .sub_path = "input.ppm", .data = ppm8 });
    try dir.writeFile(init.io, .{ .sub_path = "input.yuv", .data = raw10 });
    try dir.writeFile(init.io, .{ .sub_path = "input.y4m", .data = y4m });
    const ppm_path = try std.fmt.allocPrint(allocator, "{s}/input.ppm", .{dirname});
    defer allocator.free(ppm_path);
    const yuv_path = try std.fmt.allocPrint(allocator, "{s}/input.yuv", .{dirname});
    defer allocator.free(yuv_path);
    const y4m_path = try std.fmt.allocPrint(allocator, "{s}/input.y4m", .{dirname});
    defer allocator.free(y4m_path);

    var image8 = try img.decodePpmBytes(allocator, ppm8);
    defer image8.deinit(allocator);
    var image16 = try img.decodePpmBytes(allocator, ppm16);
    defer image16.deinit(allocator);
    var frame8 = try img.decodeYuv420Bytes(allocator, raw8, .{ .width = width, .height = height });
    defer frame8.deinit(allocator);
    var frame10 = try img.decodeYuv420Bytes(allocator, raw10, .{ .width = width, .height = height, .bit_depth = .b10 });
    defer frame10.deinit(allocator);
    var converter = try img.YuvRgbConverter.init(allocator, width, height);
    defer converter.deinit();
    const linear_rgb = try allocator.alloc(f32, pixels * 3);
    defer allocator.free(linear_rgb);

    inline for (comptime std.meta.tags(Case)) |case| {
        const iterations: usize = switch (case) {
            .rgb8, .rgb10 => 12,
            .qoi_noise, .qoi_runs => 24,
            .image8_owned => 5_000_000,
            else => 100,
        };
        var checksum: u64 = 0;
        // One untimed warmup, then a fixed amount of work for both compilers.
        var start: std.Io.Timestamp = undefined;
        for (0..iterations + 1) |iteration| {
            if (iteration == 1) start = .now(init.io, .awake);
            switch (case) {
                .ppm8, .ppm16, .pam16, .pbm, .qoi_noise, .qoi_runs, .ppm_file, .image8_copy, .image8_owned, .image16_to8 => {
                    var decoded = switch (case) {
                        .ppm8 => try img.decodePpmBytes(allocator, ppm8),
                        .ppm16 => try img.decodePpmBytes(allocator, ppm16),
                        .pam16 => try img.decodePamBytes(allocator, pam16),
                        .pbm => try img.decodePnmBytes(allocator, pbm),
                        .qoi_noise => try img.decodeQoiBytes(allocator, qoi_noise),
                        .qoi_runs => try img.decodeQoiBytes(allocator, qoi_runs),
                        .ppm_file => try img.decodePpmFile(init.io, allocator, ppm_path),
                        .image8_copy => try image8.to8Bit(allocator),
                        .image8_owned => blk: {
                            // Ownership moves without allocation. Restore it below.
                            std.mem.doNotOptimizeAway(&image8);
                            break :blk try image8.to8BitOwned(allocator);
                        },
                        .image16_to8 => try image16.to8Bit(allocator),
                        else => unreachable,
                    };
                    std.mem.doNotOptimizeAway(decoded.data);
                    if (iteration == 0) checksum = std.hash.Wyhash.hash(0, decoded.data);
                    checksum +%= decoded.data[iteration % decoded.data.len];
                    if (case == .image8_owned) image8 = decoded else decoded.deinit(allocator);
                },
                .yuv8, .yuv10, .yuva16, .yuv_file, .yuv10_to8 => {
                    var decoded = switch (case) {
                        .yuv8 => try img.decodeYuv420Bytes(allocator, raw8, .{ .width = width, .height = height }),
                        .yuv10 => try img.decodeYuv420Bytes(allocator, raw10, .{ .width = width, .height = height, .bit_depth = .b10 }),
                        .yuva16 => try img.decodeYuv420Bytes(allocator, raw16, .{ .width = width, .height = height, .bit_depth = .b16, .has_alpha = true }),
                        .yuv_file => try img.decodeYuv420File(init.io, allocator, yuv_path, .{ .width = width, .height = height, .bit_depth = .b10 }),
                        .yuv10_to8 => try frame10.to8Bit(allocator),
                        else => unreachable,
                    };
                    std.mem.doNotOptimizeAway(decoded.y);
                    if (iteration == 0) checksum = std.hash.Wyhash.hash(0, decoded.backing_mem.?);
                    checksum +%= decoded.y[iteration % decoded.y.len];
                    decoded.deinit(allocator);
                },
                .y4m_memory, .y4m_file => {
                    var decoder = if (comptime case == .y4m_memory)
                        try img.Y4mMemoryDecoder.init(allocator, y4m)
                    else
                        try img.y4m.decodeFile(init.io, allocator, y4m_path);
                    defer if (comptime case == .y4m_file) decoder.deinit();
                    var decoded = (try decoder.readFrame()) orelse return error.MissingFrame;
                    defer decoded.deinit(allocator);
                    std.mem.doNotOptimizeAway(decoded.y);
                    if (iteration == 0) checksum = std.hash.Wyhash.hash(0, decoded.backing_mem.?);
                    checksum +%= decoded.y[iteration % decoded.y.len];
                    if (try decoder.readFrame() != null) return error.ExtraFrame;
                },
                .rgb8, .rgb10 => {
                    try converter.convert(if (case == .rgb8) frame8 else frame10, linear_rgb);
                    std.mem.doNotOptimizeAway(linear_rgb);
                    if (iteration == 0) checksum = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(linear_rgb));
                    checksum +%= @as(u32, @bitCast(linear_rgb[iteration % linear_rgb.len]));
                },
            }
        }
        const elapsed = start.durationTo(.now(init.io, .awake)).toNanoseconds();
        // Machine-readable output on stderr, like std.debug.print elsewhere in this project.
        std.debug.print("{s} {d:.6} {d}\n", .{ @tagName(case), @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations)), checksum });
    }
}
