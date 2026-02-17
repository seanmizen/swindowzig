# swindowzig - Claude Guide

> **Docs policy: CLAUDE.md and README.md only. Never create additional markdown files.**

---

## Build Commands

```bash
# Default example (justabox spinning box)
zig build run

# Specific example
zig build run -Dexample=voxel
zig build run -Dexample=windows

# Compile only
zig build native

# Clean build (fixes mysterious segfaults from stale cache)
rm -rf zig-out zig-cache .zig-cache && zig build native

# Web (WASM)
zig build web
bun backends/wasm/dev-server.ts
```

---

## Project Structure

```
swindowzig/
├── libs/
│   ├── sw_core/        # Timeline, events, input, record/replay
│   ├── sw_platform/    # SDL2 (native) + canvas (web)
│   ├── sw_app/         # Entry point — run() function + Context
│   ├── sw_gpu/         # WebGPU wrapper (active development)
│   │   ├── gpu.zig              # Main API — GPU struct, all create* methods
│   │   ├── native_webgpu.zig    # C bindings for wgpu-native
│   │   ├── types.zig            # Shared descriptor types
│   │   └── web_bridge.zig       # WASM JS bindings
│   └── sw_math/        # Vec3, Mat4, perspective(), lookAt()
├── examples/
│   ├── justabox/       # Default: single spinning colored box
│   ├── windows/        # Triangle with mouse drag
│   └── voxel/          # Voxel chunk demo (16×16×16)
└── backends/
    └── wasm/           # Web platform boot + dev server
```

---

## Critical Lessons

### extern struct initialization (CRITICAL)
Always `std.mem.zeroes()` for extern structs passed to C APIs — aggregate init
does NOT apply default field values:
```zig
// WRONG — padding and optional fields are undefined
const desc = WGPUFooDescriptor{ .field = value };

// CORRECT
var desc = std.mem.zeroes(WGPUFooDescriptor);
desc.field = value;
```

### IndexFormat enum mismatch (fixed in gpu.zig)
`types.IndexFormat` starts at 0, but native `WGPUIndexFormat` has `undefined=0`,
`uint16=1`, `uint32=2`. The `setIndexBuffer` wrapper now uses an explicit switch
to map correctly. Do not use raw `@intFromEnum` for this conversion.

### Hardware depth testing (macOS/Metal)
`wgpuDeviceCreateRenderPipeline` crashes (bus error at 0x29) when depth stencil
is enabled — wgpu-native v0.19.4.1 bug on Metal. **Workaround: painter's
algorithm** (sort quads back-to-front in software before uploading index buffer).
See `examples/voxel/mesher.zig` `sortByDepth()`.

### Voxel face winding (fixed in mesher.zig)
+Y, -Y, +Z, -Z faces had CW winding (inside-out). Fixed by reversing vertex
order so geometric normal matches the intended outward face normal. +X and -X
were already correct.

### Zig 0.15.2 ArrayList API
```zig
var list = std.ArrayList(T){};           // init (no allocator arg)
try list.append(allocator, item);        // pass allocator per-op
list.deinit(allocator);
```

---

## Common Crashes

**Bus error / segfault in render pass or pipeline creation**
→ `extern struct` has uninitialized fields. Use `std.mem.zeroes()`.

**`invalid index format: 0`**
→ Passing `IndexFormat.uint16` (value 0) raw to native; use the named switch
in `gpu.zig:setIndexBuffer`.

**`CommandBuffer cannot be destroyed because still in use`**
→ Missing `wgpuDevicePoll()` after submit, or missing `release()` calls.

---

## Adding New WebGPU Features

1. Check wgpu-native headers: `~/.local/include/webgpu/webgpu.h`
2. Add C binding to `native_webgpu.zig`
3. Add Zig wrapper in `gpu.zig`
4. Add corresponding web path in `web_bridge.zig`
5. Release anything you create (wgpu uses reference counting)
