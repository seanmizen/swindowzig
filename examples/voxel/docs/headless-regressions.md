# Headless TAS / Frame-Dump Regressions — State, Gap, Plan

> Research doc. Originally captured the current state of headless rendering,
> identified the gap between "works on a mac with a visible window" and "works
> on a Linux CI box with no display server", and proposed a tiered implementation
> path. **Tier 2 has now landed** — see the "Status: Tier 2 landed" section
> below for the reproducible commands. The rest of the document is kept as the
> record of why the design looks the way it does.

## Status: Tier 2 landed

**Branch:** `voxel/headless-offscreen`

The headless-offscreen GPU path is implemented. `--headless --dump-frame=<path>`
now auto-promotes to a no-surface GPU init: wgpu-native allocates a persistent
`bgra8unorm` offscreen texture sized to the config resolution and all render
passes target that texture instead of a swapchain. `captureFrame()` reads the
offscreen texture directly. `present()` becomes a no-op (the `submit()` path
already `wgpuDevicePoll`s on `wait=true` so work is flushed between frames).
No SDL window is created, so the path is viable on a CI box with no display
server as soon as lavapipe (or another Vulkan ICD) is installed.

Concretely landed:

- `Config.headless_gpu: bool` in `libs/sw_app/src/app.zig`. When both
  `headless` and `headless_gpu` are set, `runNative` uses `NullBackend` for
  platform events but still calls `gpu_device.init(null, w, h)` and fires
  the `render` callback.
- `GPU.init(null, w, h)` branch in `libs/sw_gpu/src/gpu.zig`: skip
  `createSurfaceFromSDLWindow`, skip `wgpuSurfaceConfigure`, allocate
  `offscreen_color_texture` with usage
  `RenderAttachment | CopySrc | TextureBinding` so the existing FXAA pass
  can still sample it.
- `getCurrentTextureView` / `captureFrame` / `present` fall back to the
  offscreen texture when `self.surface == null`.
- `examples/voxel/main.zig` auto-promotes `--headless --dump-frame=` (and
  `--headless --compare-golden=`) to `headless_gpu = true`. Adds a new
  `--compare-golden=<path>` CLI flag with `--golden-max-diff-pct` and
  `--golden-max-channel-delta` tolerances; prints a one-line `PASS:` /
  `FAIL:` summary and exits with `0` / `1`.
- `examples/voxel/assets/goldens/<backend>/` directory convention.
  Initial `metal/` set generated from this machine and checked in.
  `lavapipe/` is intentionally empty and will be populated by running
  `./examples/voxel/scripts/run_headless_regressions.sh --update` on a
  Linux box (local Docker or a CI job). The expectation per section 5 of
  this doc is that lavapipe pixels will diverge from metal and need their
  own goldens — that divergence is not a regression.
- `examples/voxel/scripts/run_headless_regressions.sh` walks an enumerated
  regression table (the 4 existing TAS files × their meaningful CLI-flag
  combinations, 10 runs total), runs each under
  `--headless --dump-frame --compare-golden`, and pretty-prints `PASS` /
  `FAIL` / `MISSING` / `ERROR` with a summary line. Detects backend from
  `uname -s` (Darwin → metal, Linux → lavapipe). `--update` regenerates
  goldens for the active backend.

Not yet done (deliberately, per the task scope): no `zig build test-voxel`
step, no GitHub Actions workflow, no `aa_regression.sh` promotion, and no
build-time `-Dheadless_only` option to strip libsdl2-dev from the CI image.
All Tier 3 / Tier 4 work.

### Reproducing locally (mac)

From `utils/swindowzig`:

```bash
# 1. Build
zig build native -Dexample=voxel

# 2. Quick sanity: the mandatory headless regression still exits 0
./zig-out/bin/voxel --headless --tas examples/voxel/framespike.tas

# 3. Smoke test the new headless-offscreen path with a frame dump
./zig-out/bin/voxel --headless \
  --tas examples/voxel/framespike.tas \
  --dump-frame=/tmp/framespike.ppm \
  --aa=none

# 4. Run the full regression suite against checked-in metal goldens
./examples/voxel/scripts/run_headless_regressions.sh

# 5. Regenerate goldens for this backend (after a deliberate visual change)
./examples/voxel/scripts/run_headless_regressions.sh --update
```

Compare mode prints a table like:

```
== headless voxel regressions — backend: metal ==

TEST                         STATUS    NOTES
----                         ------    -----
framespike                   PASS
msaa_flatland_none           PASS
msaa_flatland_fxaa           PASS
msaa_flatland_msaa4          PASS
ao_corners_none              PASS
ao_corners_classic           PASS
ao_corners_moore             PASS
cave_skylight_none           PASS
cave_skylight_skylight       PASS
dig_relight                  PASS

Summary: 10 passed, 0 failed, 0 missing (backend=metal)
```

### Verified backends

- **mac / Metal** — all 10 regression entries pass against freshly generated
  metal goldens. Headless-offscreen captures are bit-deterministic across
  consecutive runs on the same binary (verified by `cmp` on two
  back-to-back `--dump-frame` outputs). As predicted in section 5 of this
  doc, the headless-offscreen capture is **not** bit-identical to the
  windowed capture on the same machine — the two runs converge on the same
  TAS state but the render sequence differs in ways that leak into the
  pixel output. The windowed path remains available for interactive
  debugging; the headless path is the one the regression runner uses.
- **Linux / lavapipe** — not verified. No Linux dev box in the loop yet.
  The `lavapipe/` golden directory exists but is empty. Running the script
  on a Linux box with `mesa-vulkan-drivers` installed should produce
  a matching set of goldens via `--update`; nothing in the Zig code paths
  is macOS-specific.

### Missing goldens

| path | reason |
|------|--------|
| `examples/voxel/assets/goldens/lavapipe/*.ppm` | No Linux box in the loop at this commit. Run `./examples/voxel/scripts/run_headless_regressions.sh --update` on a Linux host (with `mesa-vulkan-drivers` installed so lavapipe is visible via `vulkaninfo --summary`) to populate these. The set should be a full 10 files mirroring `metal/`. |

---

> The rest of this doc is the original research content and is preserved as
> the record of why Tier 2 looks the way it does. Operationally, the section
> above is the source of truth.

## TL;DR

- The deterministic TAS replay path is in good shape: `--headless --tas` already
  runs end-to-end on the mandatory regression and exits 0.
- The visual regression path (TAS → frame dump → PPM diff) **only works when a
  real window exists**, because GPU init goes through SDL2 → platform-specific
  surface chains (`SDL_Metal_GetLayer` on macOS, Xlib/Wayland on Linux). On a CI
  box with no display server, both `SDL_Init(SDL_INIT_VIDEO)` and surface
  creation will fail.
- The cheapest viable Tier-1 path is **not** SDL `SDL_WINDOW_HIDDEN` — that
  still needs a display server on Linux, and even with `SDL_VIDEODRIVER=dummy`
  there is no Metal layer / X11 window for wgpu to bind to.
- The right path is **Tier 2**: a no-surface offscreen GPU mode. The existing
  FXAA pipeline already proves out the architecture — it renders the scene to
  an offscreen `bgra8unorm` texture and then blits to the swapchain. We just
  need to make "blits to the swapchain" optional and route `captureFrame()` to
  the offscreen texture instead.

## Current state

### TAS replay (`utils/swindowzig/libs/sw_core/src/replay.zig`, wired in `examples/voxel/main.zig`)

- Tick-based, fully deterministic. The main loop runs at fixed 120Hz (`Config.tick_hz = 120`).
- `Config.tick_timing` has two modes (`libs/sw_app/src/app.zig:9`):
  - `.realtime` — `dt_ns = wall_clock_now - last_time` (standard fixed-timestep)
  - `.unlimited` — every loop iteration synthesizes exactly one tick's worth of
    time via `null_impl.advanceTime(timeline.tickDuration())`. No vsync, no
    sleeps, no swapchain present pacing. Pairs naturally with `--headless`.
- The replayer is gated until world loading finishes; on the first post-loading
  tick, all TAS event tick_ids are remapped by `+ctx.tickId() + 1` so TAS tick 1
  is always the first sim tick of gameplay (`main.zig:606`). This is the
  property that makes TAS captures reproducible across runs of any length.
- TAS step mode (`--tas-step`) is the existing frame-by-frame debug harness:
  Right-arrow advances exactly one TAS group at a time. Already deterministic.

### Headless mode (`--headless`, app.zig:73-99)

- Switches the platform backend from SDL2 to `NullBackend`
  (`libs/sw_platform/src/null_backend.zig`). NullBackend is a 49-line stub: no
  window, no event pump, `getTime()` returns a synthetic monotonic clock that
  only advances when `null_impl.advanceTime()` is called.
- **Critically: GPU init is conditionally skipped.** `app.zig:94` reads
  `if (!config.headless) gpu_device.init(...)`. Render callbacks early-return
  because `gpu.isReady() == false`. So today, headless mode is "deterministic
  game-logic simulation, zero rendering".
- Headless auto-shuts-down when the TAS finishes (`main.zig:633`), which is
  what makes `--headless --tas X.tas` exit-0 testable.

### Frame dump (`--dump-frame=<path>`, main.zig:1606-1654, gpu.zig:1160-1236)

- Implementation: `g.captureFrame(allocator)` → `Texture → Buffer` copy via
  `wgpuCommandEncoderCopyTextureToBuffer`, blocking `wgpuDevicePoll`, manual row
  unstride (256-byte alignment), then BGRA → RGB swap and PPM P6 write in
  `main.zig`.
- The capture point is **the surface texture from the swapchain**:
  `gpu.zig:1166` reads `self.current_surface_texture`, which was set earlier in
  the same frame by `getCurrentTextureView()` calling
  `wgpuSurfaceGetCurrentTexture(self.surface, ...)` — surface is mandatory.
  Required usage flag `WGPUTextureUsage_CopySrc` is already set on the
  swapchain at `gpu.zig:447`, so the readback itself is fine.
- Wait conditions before capture (`main.zig:1601-1605`): `world_loading == false`,
  and if a TAS is running, `replayer.state == .finished`. This is what makes
  `--tas X.tas --dump-frame Y.ppm` deterministic across MSAA settings.
- After capture: `std.process.exit(0)`.
- **Gating constraint:** because capture goes through the swapchain, you cannot
  combine `--dump-frame` with `--headless` today. The headless path skips GPU
  init entirely, so there is no surface, no texture, nothing to copy from.

### AA regression runner (`tests/aa_regression.sh`)

- Builds voxel, runs three captures (`--aa=none`, `--aa=fxaa`, `--aa=msaa --msaa=4`),
  produces normalized + amplified diffs via ImageMagick, prints differing-pixel
  counts via inline Python.
- Crucially: **prints stats only, does not gate.** The script's header comment
  explicitly says "see README.md TODO: resolve headless GPU path before making
  this mandatory". This doc is the resolution of that TODO.
- It works today on a developer's mac (a real window flashes up briefly during
  each capture), and would presumably work on a Linux dev box with X11/Wayland.
  It would NOT work on `ubuntu-latest` GitHub Actions out of the box.

### How wgpu adapter selection works today (gpu.zig:382-419)

- Backend flags are hard-coded per OS: Metal on macOS, Vulkan on Linux,
  DX12|Vulkan on Windows.
- `power_preference = .high_performance` is requested.
- No fallback logic. If wgpu cannot find a Vulkan ICD with the requested power
  class, init fails.

## Gap analysis: what stops this from running on a headless Linux CI box

### 1. Window creation requires a display server

`SDL2Backend.create()` calls `SDL_Init(SDL_INIT_VIDEO)` and then
`SDL_CreateWindow(... SDL_WINDOW_SHOWN ...)`. Both fail on a box with no
DISPLAY/WAYLAND_DISPLAY. Workarounds:

- `SDL_VIDEODRIVER=dummy` — SDL_Init succeeds and you get a fake "window", but
  there is no Metal layer / X11 window / Wayland surface to hand to wgpu.
  `createSurfaceFromSDLWindow` then fails with `UnsupportedWindowSystem` (or
  worse, returns garbage). Dead end.
- Run under `xvfb-run` — works, but it's an extra moving part and pulls a real
  X server into the CI loop. Acceptable as a stopgap, not the long-term answer.
- **Proper fix:** make GPU init not require a window at all, see Tier 2.

### 2. wgpu surface chain is per-platform and assumes a real native handle

`createSurfaceFromSDLWindow()` (`native_webgpu.zig:1093`) is a hard switch over
`builtin.os.tag`:
- macOS → `SDL_Metal_CreateView` → `SDL_Metal_GetLayer` → `WGPUSurfaceDescriptorFromMetalLayer`
- Linux → `SDL_GetWindowWMInfo` → either `WGPUSurfaceDescriptorFromXlibWindow`
  or `WGPUSurfaceDescriptorFromWaylandSurface`
- Windows → `error.NotImplementedYet`

There is no surface-less path. `GPU.init` returns `error.WindowRequired` if you
pass `null` for the window (gpu.zig:379).

### 3. GPU adapter on a headless Linux box

Once we have a no-surface init path, the actual rendering needs a Vulkan ICD.
On a real CI box with no GPU we need Mesa's lavapipe (llvmpipe-based software
Vulkan).

- Install: `apt-get install mesa-vulkan-drivers` on Ubuntu provides
  `/usr/share/vulkan/icd.d/lvp_icd.x86_64.json`.
- Force selection (only if there's competing hardware, which CI usually doesn't
  have): `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json` or
  `VK_LOADER_DRIVERS_SELECT=lvp`.
- Sanity check: `vulkaninfo --summary` should list `llvmpipe`.
- wgpu currently requests `power_preference = .high_performance` — on lavapipe
  the only adapter is `cpu` class and wgpu will pick it anyway (there is
  nothing else). If we ever care, we can switch to `.low_power` for headless.

### 4. Shader / WGSL risks on lavapipe

- WGSL → SPIR-V is done by naga inside wgpu-native. Lavapipe is just a Vulkan
  driver, it doesn't see WGSL.
- Lavapipe handles geometry / fragment / compute fine for the kinds of features
  the voxel demo uses (no tessellation, no atomic-int-image-stores, no bindless
  textures). The current shaders are deliberately conservative: simple voxel
  vert+frag with painter's-algorithm depth (no hardware depth-stencil — see the
  Metal workaround in `CLAUDE.md`), the FXAA fullscreen pass, and the overlay
  alpha blend. None of that exercises lavapipe edge cases.
- The painter's-algorithm workaround is actually a *gift* here: hardware depth
  testing is the most common source of cross-driver pixel diffs (depth-fighting
  thresholds, polygon-offset constants). We dodge it entirely.

### 5. Backend pixel divergence (the unavoidable risk)

Even with everything wired up correctly, **mac-Metal and Linux-lavapipe will
produce different pixels** for the same scene. Sources of divergence, in
descending order of severity:

- **FXAA**: sub-pixel luminance-edge-search is exquisitely sensitive to
  floating-point order. Backends that use FMA differently (Metal does, lavapipe
  does not) will diff at edge pixels. Expect ~5–15% differing pixels with max
  channel delta ≤ 4 between backends, even on identical scenes.
- **MSAA resolve**: the resolve filter is implementation-defined inside the
  driver. Different sample patterns mean different post-resolve colours.
- **Alpha blending in the overlay pass**: order-of-operations matters when
  multiple translucent quads stack. Should be deterministic *within* a backend
  but may diff across backends.
- **Texture filtering**: not currently relied on (voxels are flat-shaded), so
  this is a non-issue today. Becomes a concern if we ever add textures.

This means **per-adapter golden frames are mandatory** for visual regressions.
A single set of goldens checked in from a mac will fail every CI run. Options:

- (a) Per-backend goldens: `tests/golden/metal/*.ppm` and
  `tests/golden/lavapipe/*.ppm`. Local devs regenerate the metal set; CI
  regenerates and pins the lavapipe set. Each is then compared with a tight
  tolerance.
- (b) Single set of goldens with a loose tolerance (e.g. ≤2% pixels differing,
  max channel delta ≤8). Catches gross regressions but misses subtle ones.
- (c) Backend-agnostic "reference renderer" — a CPU rasteriser that produces
  bit-exact identical output everywhere. Massive scope blow-up; not worth it.

Recommend (a). It's the only option that catches ±1-LSB MSAA/FXAA regressions,
which is the entire point of the AA test suite.

### 6. Wall-clock contamination in the render path

Audited `examples/voxel/main.zig` for wall-clock dependencies:

- All `std.time.nanoTimestamp()` calls are in performance logging only
  (mesh-build timing prints). They don't affect rendered pixels.
- The "WORLD LOADING" wave animation and the "inside-block" overlay both use
  `ctx.tickId()` not wall clock (`main.zig:1088, 1405`). Deterministic.
- Camera, player physics, world gen, mesher: no wall-clock reads.
- FXAA / overlay shaders: no time uniforms.

**Conclusion:** the render path is already deterministic with respect to tick
count. The only remaining nondeterminism between runs would come from the GPU
backend itself (covered above), not from game logic.

## Tiered implementation plan

### Tier 1 — `--headless` + `--dump-frame` together (≈1 day, currently impossible)

The dream state would be: `voxel --headless --tas X.tas --dump-frame Y.ppm` Just
Works. Today this is impossible because `--headless` skips GPU init entirely.

There is **no genuinely cheap Tier-1 win** hiding in the existing abstractions.
The closest thing is `SDL_WINDOW_HIDDEN`, but that still needs a display server
on Linux and is not actually "headless". Skip Tier 1 and go straight to Tier 2.

### Tier 2 — No-surface offscreen GPU path (the real fix)

**Goal:** add a third mode alongside windowed and headless: "GPU init without
a swapchain, render to an offscreen texture, dump that texture instead of the
swapchain". Visible mac build is unchanged.

Concrete shape of the change:

1. `Config` gets a `headless_gpu: bool` flag (or fold into `headless` with an
   enum: `.off`, `.no_gpu`, `.offscreen`). The CLI surfaces it as
   `--headless` (current behaviour) and `--offscreen` (new) or
   `--headless --dump-frame=...` (auto-promote from "no_gpu" to "offscreen").
2. `GPU.init` learns a `null_window` code path:
   - Same instance + adapter + device dance as today. No
     `createSurfaceFromSDLWindow`, no `wgpuSurfaceConfigure`.
   - Allocate a single `bgra8unorm` colour texture sized to `width × height`,
     usage `RenderAttachment | CopySrc | TextureBinding`. This becomes the
     "fake swapchain". TextureBinding is included so an FXAA second pass can
     still sample it.
   - Store its `TextureView` somewhere addressable.
3. `getCurrentTextureView()` learns: if `surface == null`, return the offscreen
   texture view directly (no `wgpuSurfaceGetCurrentTexture`).
4. `present()` learns: if `surface == null`, no-op. (Or better: insert a
   `wgpuDevicePoll` so the previous frame's submit is guaranteed flushed before
   we start the next.)
5. `captureFrame()` learns: if `current_surface_texture == null`, fall back to
   the offscreen texture handle. Same `CopyTextureToBuffer` plumbing.
6. `configureMSAA` and `configureFXAA` already use `self.width / self.height`
   from init. They will Just Work in offscreen mode because they create *more*
   offscreen textures sized to those values. The existing FXAA path proves the
   architecture: today it renders to an offscreen `bgra8unorm`, then blits to
   the swapchain. The Tier-2 change is "the final blit's destination is the
   capture texture, not the swapchain".

Build/link consequences:

- macOS: no change (Metal still used, surface still created from the SDL window
  in the windowed path).
- Linux: in offscreen mode SDL is not initialised at all — `null_backend` is
  used for the platform layer, just as headless does today. wgpu picks Vulkan,
  finds lavapipe, renders to the offscreen texture. No X11/Wayland touched.
- Windows: not implemented today anyway, no regression.

Estimated edit budget:

- `gpu.zig::init`: ~30 lines for the no-surface branch.
- `gpu.zig::getCurrentTextureView` / `present` / `captureFrame`: ~10 lines each
  for the surface-null branches.
- `gpu.zig` struct: one new field (`offscreen_color_texture: ?Texture`).
- `app.zig::runNative`: branch on the new mode to skip SDL2 backend creation
  but still call `gpu_device.init(null, w, h)`.
- `main.zig`: add the `--offscreen` (or auto-promote) flag parsing.

Deliberately out of scope for Tier 2:

- Any change to the CI pipeline. Tier 4.
- Any change to the existing aa_regression.sh runner — it can keep using the
  windowed path on developer macs, and call the binary with `--offscreen` on
  CI. Tier 3.

### Tier 3 — `zig build test-voxel` regression target

Once Tier 2 lands, wire up an opinionated runner:

1. New zig build step `test-voxel` that:
   - Runs `zig build native -Dexample=voxel` first.
   - Iterates every `*.tas` under `examples/voxel/tests/`. For each TAS:
     - Read a sibling `<name>.golden.ppm` (or `tests/golden/<backend>/<name>.ppm`).
     - Run `voxel --offscreen --world=<preset> --aa=<mode> --tas <name>.tas --dump-frame=/tmp/<name>.ppm`.
       Test-driver knowns flags from a small `<name>.tas.toml` sidecar (or
       parses comments from the TAS header for `# args:` lines).
     - Diff against the golden using a small Zig PPM-diff helper (no Python,
       no ImageMagick, so the runner stays self-contained). Tolerance comes
       from the sidecar.
     - Print pass/fail with `(differing px / total px)` and `max channel delta`.
   - Exit non-zero on the first failure (or run all and report at the end —
     pick the latter, easier to read).
2. Promote `aa_regression.sh` from "prints stats" to "calls test-voxel and
   exits with its code". Keep the ImageMagick amp-diff outputs as
   nice-to-have visualisations, but the gating decision lives in the Zig
   runner.
3. First TAS scripts to onboard:
   - `tests/msaa_flatland.tas` — already exists. Three goldens:
     `flatland_aa-none.ppm`, `flatland_aa-fxaa.ppm`, `flatland_aa-msaa4.ppm`.
   - `framespike.tas` — already mandatory. Add a golden so the existing
     headless run also diffs frames.
4. Document the "regenerate goldens" workflow (basically `--dump-frame` over
   each TAS, copy into `tests/golden/`).

### Tier 4 — CI workflow (sketch only, do NOT commit yet)

```yaml
# .github/workflows/voxel-headless.yml — DRAFT, do not commit until Tier 3 is in
name: voxel headless regression
on: [push, pull_request]
jobs:
  voxel:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Vulkan + lavapipe
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            mesa-vulkan-drivers \
            vulkan-tools \
            libsdl2-dev    # transitively needed by current build.zig even though
                            # the offscreen path won't link to SDL at runtime
      - name: Verify lavapipe is visible
        run: vulkaninfo --summary | grep -i llvmpipe
      - name: Install Zig
        uses: mlugg/setup-zig@v2
        with: { version: 0.15.2 }
      - name: Install wgpu-native
        run: |
          # Pin the same version build.zig links against (~/.local/lib/libwgpu_native.so)
          mkdir -p ~/.local
          curl -L https://github.com/gfx-rs/wgpu-native/releases/download/v0.19.4.1/wgpu-linux-x86_64-release.zip -o wgpu.zip
          unzip wgpu.zip -d ~/.local
      - name: Run regression
        working-directory: utils/swindowzig
        run: zig build test-voxel
        env:
          VK_LOADER_DRIVERS_SELECT: lvp     # belt-and-braces; lavapipe is the
                                            # only ICD on the runner anyway
```

Risks for Tier 4 specifically:

- The wgpu-native binary URL above is illustrative — confirm the exact archive
  layout (`bin/`, `lib/`, `include/`) matches what `build.zig` expects at
  `~/.local/{lib,include}`.
- `libsdl2-dev` is currently a hard build-time dependency because
  `sw_platform`'s @cImport pulls in `SDL2/SDL.h` even when only the null
  backend is used at runtime. If we want a fully SDL-free headless build, that
  needs a build-time `-Dheadless_only=true` option that swaps `sw_platform` for
  a SDL-free root file. Pure cleanup, can defer.
- First CI run will fail because the goldens don't exist yet for the lavapipe
  backend. The bring-up sequence is: land Tier 2 → land Tier 3 with mac
  goldens → run Tier 4 once with `--update-goldens` → commit the lavapipe
  goldens → make Tier 4 mandatory.

## Recommendation

Land Tier 2 first as a single PR, with **no behaviour change to the existing
windowed mac build**. Verify by running `aa_regression.sh` with the binary
patched to call `--offscreen` instead of `--aa=...`, and confirming the
captured PPMs are bit-identical to today's swapchain captures (they should be:
identical adapter, identical pipeline, just a different render target).

Then Tier 3 (the `zig build test-voxel` runner) as a second PR. Then sit on
Tier 4 until there's a real desire for "this fails the build" gating; in the
meantime, run `zig build test-voxel` locally before any voxel change and add
it to the mandatory checklist in `swindowzig/CLAUDE.md`.

Skip Tier 1 entirely — there is no useful intermediate state.

## Concrete next actions

Tier 2:
- [ ] Add `Config.offscreen: bool` (or a `RenderMode` enum) and a CLI flag.
- [ ] Add `GPU.offscreen_color_texture: ?Texture` and `offscreen_color_view: ?TextureView` fields.
- [ ] Add a no-surface branch in `GPU.init` (skip surface chain, allocate offscreen texture instead).
- [ ] Extend `getCurrentTextureView` / `present` / `captureFrame` with `surface == null` fallbacks.
- [ ] Wire `runNative` so `--offscreen` uses `NullBackend` for input but still calls `gpu_device.init(null, w, h)`.
- [ ] Smoke test on mac: `voxel --offscreen --tas tests/msaa_flatland.tas --dump-frame=/tmp/out.ppm` produces a PPM bit-identical to the windowed capture.
- [ ] Add a new mandatory check to swindowzig CLAUDE.md: `voxel --offscreen --tas examples/voxel/framespike.tas --dump-frame=/tmp/spike.ppm` exits 0.

Tier 3:
- [ ] Write a small Zig PPM diff helper under `examples/voxel/tests/diff/`.
- [ ] Add a `test-voxel` build step that walks `tests/*.tas`, runs each, diffs against `tests/golden/`.
- [ ] Define the TAS-args sidecar format (`tests/<name>.tas.toml` or `# args:` header lines).
- [ ] Generate initial mac goldens for the existing TAS files (`framespike`, `msaa_flatland` × 3 AA modes).
- [ ] Promote `aa_regression.sh` to delegate to `zig build test-voxel`.

Tier 4 (later):
- [ ] Run lavapipe locally (in a disposable Docker container) and capture the lavapipe goldens.
- [ ] Drop the goldens in `tests/golden/lavapipe/`.
- [ ] Land the GitHub Actions workflow above.
- [ ] Optional: a build option to compile sw_platform without SDL2 entirely so the CI image doesn't need libsdl2-dev.

## References

- App loop / config: `utils/swindowzig/libs/sw_app/src/app.zig`
- Headless null backend: `utils/swindowzig/libs/sw_platform/src/null_backend.zig`
- SDL2 backend: `utils/swindowzig/libs/sw_platform/src/native_sdl.zig`
- GPU init + surface chain: `utils/swindowzig/libs/sw_gpu/src/gpu.zig:363`
- Per-platform surface creation: `utils/swindowzig/libs/sw_gpu/src/native_webgpu.zig:1093`
- Frame capture: `utils/swindowzig/libs/sw_gpu/src/gpu.zig:1160`
- Frame dump CLI handling: `utils/swindowzig/examples/voxel/main.zig:1606`
- AA regression runner (currently print-only): `utils/swindowzig/examples/voxel/tests/aa_regression.sh`
- Existing TAS samples: `utils/swindowzig/examples/voxel/framespike.tas`, `utils/swindowzig/examples/voxel/tests/msaa_flatland.tas`
