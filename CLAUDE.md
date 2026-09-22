# swindowzig - Claude Guide

> **Docs policy.** Operational command sequences (>5 steps) → executable script under
> `examples/voxel/tests/*.sh`. Deep reference material (>20 lines on one topic) →
> `docs/<topic>.md`. Both cases: leave a ≤3-line breadcrumb in CLAUDE.md pointing
> at the real artifact. Do NOT inline heavy reference or long command runs directly
> into CLAUDE.md — it is loaded into every agent's context and the budget is finite.

---

## Build Commands

```bash
# Default example (justabox spinning box)
zig build run

# Specific example
zig build run -Dexample=voxel
zig build run -Dexample=windows

# Compile only (default example is justabox)
zig build native -Dexample=voxel

# Clean build (fixes mysterious segfaults from stale cache)
rm -rf zig-out zig-cache .zig-cache && zig build native -Dexample=voxel

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
│   └── voxel/          # Voxel chunk demo (16×256×16)
└── backends/
    └── wasm/           # Web platform boot + dev server
```

---

## Where the detail lives

More rules load only when you touch matching files:

- `.claude/rules/swindowzig-libs.md` loads for `libs/**`. It holds the WebGPU C
  ABI lessons, the enum-mismatch fixes, how to add a WebGPU feature, the core
  file map, and the event and context API.
- `.claude/rules/swindowzig-voxel.md` loads for `examples/voxel/**`. It holds
  the voxel CLI flags, world loading, regression tests, anti-aliasing, async
  chunks, lighting, the GPU debug system, trackpad latency, and the voxel file
  map.

---

## Zig 0.15.2 ArrayList API
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
→ Passing `IndexFormat.uint16` (value 0) raw to native. Use the named switch
in `gpu.zig:setIndexBuffer`.

**`CommandBuffer cannot be destroyed because still in use`**
→ Missing `wgpuDevicePoll()` after submit, or missing `release()` calls.

---

## Voxel Demo — Development Principles

**No function keys.** Do not use F1–F12 for any gameplay or debug feature in the voxel demo.
Function keys are excluded from the keyboard HUD and are not a reliable cross-platform input.
Use letter/modifier combos (e.g. Cmd+D, Cmd+G, Cmd+T) instead.

---

## Voxel Demo — Mandatory Testing

**Before handing any voxel changes back to the user, ALL three checks must pass:**

```bash
# 1. Clean compile
zig build native -Dexample=voxel

# 2. Headless TAS run — must exit 0
./zig-out/bin/voxel --headless --tas examples/voxel/framespike.tas

# 3. GPU smoke test — must not crash within 5 seconds
timeout 5 ./zig-out/bin/voxel 2>&1 | grep -v "^\[" | head -20
```

Do **NOT** hand changes back until all three pass. The GPU smoke test catches wgpu validation
errors (buffer overruns, bad descriptors) that only appear when the renderer actually runs.

---
