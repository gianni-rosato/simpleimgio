# simpleimgio

Pure Zig image input helpers for encoder and image-tooling projects.

I've found myself writing similar code to support simple formats like PPM in a
few projects. This means that when I need to update them, there is redundant
code that I'd rather consolidate in one place.

## Supported Decoders

- Single-frame YUV or YUVA, with the following pixel formats:
  - yuv420p
  - yuv420p9le
  - yuv420p10le
  - yuv420p12le
  - yuv420p16le
- Single- or multi-frame Y4M, progressive 4:2:0:
  - yuv420p
  - yuv420p9le
  - yuv420p10le
  - yuv420p12le
  - yuv420p16le
- PAM (`P7`)
- PNM (`P1` through `P6`), including PPM (`P3`/`P6`)
- QOI (`.qoi`), via [`qoilib`](https://github.com/gianni-rosato/qoilib)

All decoders preserve source sample depth:

- PNM/PAM still images keep their source `maxval`; samples are interleaved, with
  one byte per sample for `maxval <= 255` and two big-endian bytes per sample
  for `maxval > 255`.
- PBM bitmap samples are unpacked as `0` or `1`
- QOI images decode to 8-bit RGB/RGBA with `maxval = 255`, matching the QOI
  format
- Still images can be converted to 8-bit with `image.to8Bit(allocator)`
- Raw YUV/Y4M frames can be converted with `frame.to8Bit(allocator)`.

## Zig Usage

Add as a dependency to your Zig project:

```sh
zig fetch --save git+https://github.com/gianni-rosato/simpleimgio.git
```

In `build.zig`:

```zig
const simpleimgio = b.dependency("simpleimgio", .{});
exe.root_module.addImport("simpleimgio", simpleimgio.module("simpleimgio"));
```

In your code:

```zig
const std = @import("std");
const imgio = @import("simpleimgio");

pub fn readPpm(
    sys_io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    var image = try imgio.decodePpmFile(sys_io, allocator, path);
    defer image.deinit(allocator);

    var eight = try image.to8Bit(allocator);
    defer eight.deinit(allocator);

    std.debug.print("{}x{} depth {}\n", .{ eight.width, eight.height, eight.depth });
}
```

Raw YUV420 input needs explicit dimensions:

```zig
var frame = try imgio.decodeYuv420File(sys_io, allocator, "input.yuv", .{
    .width = 1920,
    .height = 1080,
    .bit_depth = .b10,
    .has_alpha = false,
});
defer frame.deinit(allocator);

var eight = try frame.to8Bit(allocator);
defer eight.deinit(allocator);
```

Y4M can be streamed frame-by-frame:

```zig
const file = try std.Io.Dir.cwd().openFile(sys_io, "input.y4m", .{});
defer file.close(sys_io);

var decoder = try imgio.y4m.Decoder.init(allocator, sys_io, file);
defer decoder.deinit();

while (try decoder.readFrame()) |frame_value| {
    var frame = frame_value;
    defer frame.deinit(allocator);
    // frame.y, frame.u, frame.v are planar YUV420 data.
}
```

See `src/lib.zig` for more info.
