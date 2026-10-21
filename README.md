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
- Still images can be converted to 8-bit with `image.to8Bit(allocator)`. Use
  `image.to8BitOwned(allocator)` when the original image can be consumed;
  already-8-bit sample data is reused without an allocation or copy.
- Raw YUV/Y4M frames can be converted with `frame.to8Bit(allocator)`.

## Zig Usage

Requires Zig 0.17.0 or newer.

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

Y4M headers and decoded frames retain `color_range` and `chroma_location`. An
omitted chroma tag remains unspecified; `C420` and `C420jpeg` are centered,
`C420mpeg2` is left-sited, and `C420paldv` is top-left-sited, matching FFmpeg's
Y4M demuxer. `XCOLORRANGE=FULL` and `XCOLORRANGE=LIMITED` are preserved.
Requantizing a frame preserves these fields.

`YuvRgbConverter.init(allocator, width, height)` creates reusable scratch
storage. Call `convert(frame, rgb)` with a `width * height * 3` float slice,
then `deinit()` when finished. The output is interleaved linear RGB for SDR
metric inputs. Conversion follows Vship's defaults: unspecified range is
limited, unspecified chroma location is left, the matrix is BT.709 above 650
lines and BT.601 otherwise, with BT.709 primaries and gamma 2.4 above 650 lines,
or BT.470 BG primaries and gamma 2.6 otherwise. Output uses linear BT.709
primaries; the SD primary conversion preserves Vship's RGB-to-XYZ coefficients.
Chroma is reconstructed with separable cubic Hermite interpolation, and samples
retain their source bit depth until conversion. A 4096-interval transfer lookup
interpolates linear values with less than 0.000001 absolute error. Override
range or location on the frame before conversion when the source metadata is
missing or incorrect.

## Development

Run the tests with `zig build test`. Optimized configurations use
`-Doptimize=safe`, `-Doptimize=fast`, or `-Doptimize=small` with Zig 0.17.

Build the 1080p performance workloads with `zig build bench -Doptimize=fast`,
then run `zig-out/bin/simpleimgio-bench`. Each line reports the workload,
nanoseconds per iteration, and an output checksum. Fixture generation is excluded
from timing; file workloads measure warm filesystem-cache reads. Allocating
operations include allocation and cleanup; RGB conversion reuses its scratch
storage. The owned 8-bit image workload measures ownership transfer alone.

To compare two prebuilt binaries on the same idle machine:

```sh
python3 bench/compare.py /path/to/baseline /path/to/candidate \
    --samples 16 --output results.json
```

The script warms both binaries, alternates execution order, checks matching
output checksums, and saves all measurements. It reports paired geometric mean
ratios with bootstrap 95% confidence intervals. A workload passes when the upper
confidence bound is within the default 5% slowdown limit; regressions and
inconclusive results both cause a nonzero exit. These measurements cover the
included workloads and host, rather than every possible input or architecture.

For a Zig 0.16 comparison, apply the same benchmark files and build step to the
baseline source, keep its `minimum_zig_version` at 0.16.0, and build it using
`zig build bench -Doptimize=ReleaseFast --prefix /path/to/baseline-prefix`.

The [Zig 0.17 upgrade measurements](bench/results/zig-0.17-aarch64-macos.json)
contain all 24 paired samples, source/binary hashes, host details, and results
for the 19 workloads on arm64 macOS. All workloads passed the 5% limit; 16-bit
image and 10-bit YUV conversion times decreased by about 25% and 63% respectively.
