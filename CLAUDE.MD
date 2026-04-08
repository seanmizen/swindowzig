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

### Incremental mesh update (voxel/mesher.zig)
Full `generateMesh` scans 27,648 blocks — O(chunk_volume). For block add/remove,
only 7 blocks are affected (changed block + 6 neighbours). Use `updateForBlockChange`:

```zig
// After chunk.setBlock(bx, by, bz, .air):
mesh.updateForBlockChange(&chunk, bx, by, bz, camera_pos) catch {
    mesh_dirty = true; // fallback to full regen
};
mesh_incremental_dirty = true; // GPU buffers need recreation
```

**How it works:**
- `quad_block: ArrayList(u32)` — parallel array tracking which block owns each quad
- `swapRemoveQuad(qi)` — O(1) removal: moves last quad into slot `qi`, rewrites its 6 indices
- Collects affected quads via linear scan of `quad_block` (~6k entries), removes them, re-meshes 7 blocks
- Maintains `sort_scratch` through the update so `sortByDepth` uses insertion sort (O(n)) instead of pdqsort (O(n log n)) on the next frame. Scratch is compacted by filtering entries with `.idx >= new_quad_count`, then new entries are appended with computed distances. Scratch is grown with +64 headroom when quad count increases.

**Measured improvement (48×12×48 chunk, ~6144 quads):**
- Before: 3891µs (mesh 2308 + sort 1341 + upload 242)
- After: ~840µs (tick update 210 + sort 565 + upload 280) — **78% reduction**

**`sortByDepth` latent bug fixed:** after scratch reallocation, must set `sort_valid = false`
(previously, growing scratch left it with garbage values but sort_valid could still be true).

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

## Voxel Demo — Development Principles

**No function keys.** Do not use F1–F12 for any gameplay or debug feature in the voxel demo.
Function keys are excluded from the keyboard HUD and are not a reliable cross-platform input.
Use letter/modifier combos (e.g. Cmd+D) or mouse buttons instead.

---

## Voxel Demo — CLI Flags

| Flag | Description |
|------|-------------|
| `--tas <path>` | Load and play a TAS script. Physical input blocked during playback. |
| `--headless` | No window, no GPU. Ticks unlimited speed. Exits when TAS finishes. |
| `--tas-step` | Frame-by-frame TAS stepping. Right arrow = advance one TAS tick. Implies `--gpu-debug`. |
| `--gpu-debug` | Highlight freshly rebuilt mesh faces (orange tint, fades ~0.5s). Also toggled with Cmd+G / Ctrl+G at runtime. |

---

## Voxel Demo — GPU Debug System

Tracks which mesh quads were rebuilt and visualises them with an orange tint.

**Data path:**
- `mesher.zig: quad_highlight: ArrayList(u8)` — parallel to `quad_block`, intensity 0–255 per quad
- `addQuad(..., highlight)` — new quads start at 255 (incremental rebuild and full rebuild)
- `swapRemoveQuad` — keeps `quad_highlight` in sync with other parallel arrays
- `decayHighlights(amount)` — saturating subtract each tick (amount=4 → ~60 ticks / 0.5s fade)
- `uploadMeshToGPU` — encodes highlight into upper 8 bits of `block_type` u32 at GPU upload time, restores after
- `voxel.wgsl` — shader extracts `(block_type >> 16) & 0xFF`, mixes orange `vec3(1.0, 0.5, 0.1)` with base colour

**Key design choices:**
- Piggybacks on existing `block_type: u32` (only uses lower 8 bits) — no vertex layout changes
- Zero overhead when off: highlights are 0, shader multiplies by 0, vertex re-upload skipped
- In TAS step mode, highlights only decay on executing ticks (persists between steps)

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

## Adding New WebGPU Features

1. Check wgpu-native headers: `~/.local/include/webgpu/webgpu.h`
2. Add C binding to `native_webgpu.zig`
3. Add Zig wrapper in `gpu.zig`
4. Add corresponding web path in `web_bridge.zig`
5. Release anything you create (wgpu uses reference counting)
