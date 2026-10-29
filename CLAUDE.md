# CLAUDE.md

swindowzig: a thin WebGPU wrapper in Zig for games. One codebase runs in the
browser (wasm, a `<canvas>`, the browser WebGPU) and on the desktop (SDL2,
wgpu-native). It gives a window, input, a fixed-timestep loop that records
and replays its input, and the WebGPU API. The game decides everything else.
The libraries are in `libs/sw_*`, the web backend in `backends/wasm`, and the
demos in `examples/`. It is a Zig package: a `v<version>` tag publishes
`swindowzig.tar.gz` to a GitHub Release (`.github/workflows/swindowzig-release.yml`).

Consumers: `apps/action` (action.seanmizen.com) and
`apps/minecraft.seanmizen.com` in `seanmizen/seanorepo`. The repo started
from `template-seanorepo`, with the engine history from seanorepo's
`utils/swindowzig`.

## Setup

```bash
yarn
```

The repository carries its Yarn 4 release in `.yarn/releases`, and
`.yarnrc.yml` names it in `yarnPath`. Any system `yarn` runs that release,
Yarn 1 included. Do not use corepack. Yarn installs the hooks and Biome. Zig
(the version in `build.zig.zon`), SDL2, wgpu-native and Bun come from the
system: see `README.md`.

## Hard rules

- **Yarn 4 only.** Never `npm install` or `bun install`. Bun is a runtime only.
  Bundling belongs to RSBuild (`rsbuild.config.ts`, `yarn build:js`), never
  `bun build`.
- **Before you finish:** run `yarn fix` (Biome), `zig build test` and
  `zig build web`. Fix every error. A change to the voxel example also runs
  the mandatory headless tests below.
- **Never `--no-verify`.** The hooks run commitlint.
- **Write in STE.** Load the `ste` skill (`.claude/skills/ste/`) before you
  write prose. Use Strict mode for error messages, tool descriptions and agent
  instructions. Use STE-flavored mode for docs, comments, commit messages, PR
  bodies and replies to Sean. Run `.claude/skills/ste/scripts/ste-lint.py` on
  new prose. In code comments and docs, cite the requirement
  (`REQ-<AREA>-<NNN>`) and never the issue or PR number. See
  `requirements/README.md`.
- **A release is a tag.** `v<version>` must match `.version` in
  `build.zig.zon`. Tag only when Sean asks.

## Conventions

- Branch: `SWZ-{issue}/{short-description}`. Lowercase, hyphenated, at most 5
  words.
- Commit and PR title: `[SWZ-{issue}] {type}: {description}`. Types:
  `feat fix chore docs refactor test style perf ci`.
- One ticket = one branch = one PR, squash-merged. Out-of-scope work gets a new
  issue, not a commit on this branch.
- Work in a worktree, never on the `main` checkout.

Full procedure, with `gh` commands: `.claude/skills/workflow/SKILL.md`.

---

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
│   ├── sw_audio/       # Waveforms, WAV and Ogg Vorbis (stb_vorbis), mixer, 3D sound, streams
│   ├── sw_gpu/         # WebGPU wrapper (active development)
│   │   ├── gpu.zig              # Main API — GPU struct, all create* methods
│   │   ├── native_webgpu.zig    # C bindings for wgpu-native
│   │   ├── types.zig            # Shared descriptor types
│   │   └── web_bridge.zig       # WASM JS bindings
│   ├── sw_math/        # Vec2-4, Mat4, Quat, Aabb, Ray, Plane, perspective(), lookAt(), camera controller
│   ├── sw_gfx2d/       # 2D renderer: rects, outlines, textured quads, batching
│   ├── sw_assets/      # loadBytes, PNG decode, zip reader, player files, OPFS/folder cache
│   ├── sw_text/        # Text: TTF and bitmap font chain, bidi, atlas, measure, wrap, draw
│   ├── sw_render/      # Texture atlas, frame graph, uniform ring, staged uploads, WGSL prefix, post chain, sky, box models, shadows, point lights, clouds, rain and snow, translucency, particles, graphics settings, frame pacing, GPU pass timer, frame-time chart
│   ├── sw_net/         # WebSocket client: browser WebSocket (web), RFC 6455 on std.Io with TLS (native)
│   ├── sw_jobs/        # Worker pools: native threads and Web Workers, one Transport API
│   ├── sw_ui/          # UI tree: layout, focus, widgets, screen stack, on-screen keyboard, semantic tree, drawing
│   └── sw_voxel/       # Voxel chunks: storage, light, greedy and model mesher, chunk pipeline, far terrain LOD, cave culling, collision, region files
│       ├── src/                 # Library. content.zig gives the content contract
│       └── testing/content.zig  # Test content: numbered blocks, no game names
├── examples/
│   ├── justabox/       # Default: single spinning colored box
│   ├── windows/        # Triangle with mouse drag
│   ├── flat2d/         # sw_gfx2d + sw_text + sw_ui demo: shapes, text, each sw_ui widget
│   ├── mipmaps/        # GPU mip levels, a texture array, anisotropic sampling. `--check` tests it
│   ├── atlas/          # sw_render atlas and animated sprites. `--check` tests it
│   ├── sky/            # sw_render sky, fog, time of day, clouds and weather. `--check` tests it
│   ├── models/         # sw_render instanced box models, the first-person pass, shadows and a point light. `--check` tests it
│   └── voxel/          # Voxel demo on sw_voxel: content.zig, world_gen, renderer
├── demos/              # Showcase demos (-Ddemo=<name>): scripts, capture, frame hashes. See demos/README.md
│   ├── common/         # Shared frame (demo.zig), CowScene, script, mesher
│   └── cow/            # The turning cow; one setting at a time
└── backends/
    └── wasm/           # Web platform boot + dev server
```

---

## Where the detail lives

More rules load only when you touch matching files:

- `.claude/rules/libs.md` loads for `libs/**`. It holds the WebGPU C
  ABI lessons, the enum-mismatch fixes, how to add a WebGPU feature, the core
  file map, and the event and context API.
- `.claude/rules/voxel.md` loads for `examples/voxel/**` and
  `libs/sw_voxel/**`. It holds the sw_voxel content contract,
  the voxel CLI flags, world loading, regression tests, anti-aliasing, the
  chunk pipeline, lighting, the GPU debug system, trackpad latency, and the voxel file
  map.
- `docs/agent-batch-manual.md` is the procedure for a Claude Code cloud
  session that builds a batch of tickets on one branch, with
  `scripts/cloud-setup.sh` for the sandbox.

---

## Zig version

`minimum_zig_version` in `build.zig.zon` is the one place that names the Zig
version (0.17.x). `build.zig` stops on any other major.minor, and the minecraft
dockerfile downloads the same version. To upgrade: change `build.zig.zon`, then
fix the std API errors.

Zig 0.17 API in this code:
- `var list: std.ArrayList(T) = .empty;` and pass the allocator per call.
- Files, clocks, sleep, `Mutex` and `Condition` take a `std.Io`. Native
  `main(init: std.process.Init)` passes `init.io` to `sw.run`, and callbacks
  get it as `ctx.io` (null on the web). The voxel perf logs use
  `libs/sw_voxel/src/clock.zig`.
- No `@cImport`: `build.zig` translates `libs/sw_platform/src/sdl.h` with
  `addTranslateC`. Only the native build gets the `sdl` module.
- No `**` on arrays: use `@splat(value)`.

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
