# swindowzig: overview

The old README text. The [README](../README.md) is the short version.

**A thin WebGPU wrapper for game development.**
Write once, run anywhere: web browsers (WASM) and native desktops (Windows/macOS/Linux).

The engine progress is in the [README](../README.md).

---

## What It Is

**Imperative infrastructure for 3D games, not a framework.**

You get:
- Window management (SDL2 on native, canvas on web)
- Input handling (keyboard, mouse)
- Fixed timestep game loop (deterministic)
- Full WebGPU API access
- Event recording/replay

You decide everything else.

---

## Quick Example

```zig
const sw = @import("sw_app");

pub fn main() !void {
    try sw.run(.{
        .title = "My Game",
        .size = .{ .w = 1280, .h = 720 },
        .tick_hz = 60,
    }, GameCallbacks);
}

const GameCallbacks = struct {
    pub fn init(ctx: *sw.Context) !void { ... }
    pub fn tick(ctx: *sw.Context) !void { ... }
    pub fn render(ctx: *sw.Context) !void { ... }
    pub fn shutdown(ctx: *sw.Context) !void { ... }
};
```

---

## Quick Start

### Prerequisites

- **Zig 0.17.x**: the version in `build.zig.zon` (`minimum_zig_version`). The build stops on any other major.minor.
- **SDL2**
- **wgpu-native** v22.1.0.5 (bindings are pinned to this version's header; re-diff when upgrading)
- **Bun** for the web build and the dev server

### Install Dependencies

**Linux / WSL:**
```bash
sudo apt install libsdl2-dev

mkdir -p ~/.local/lib ~/.local/include/webgpu && cd /tmp
wget https://github.com/gfx-rs/wgpu-native/releases/download/v22.1.0.5/wgpu-linux-x86_64-release.zip
unzip wgpu-linux-x86_64-release.zip
cp lib/libwgpu_native.a ~/.local/lib/
cp include/webgpu/webgpu.h ~/.local/include/webgpu/

curl -fsSL https://bun.sh/install | bash
```

On WSL, `which bun` must show `~/.bun/bin/bun`. A Windows bun on the PATH
(for example `/mnt/c/.../bun`) runs through `cmd.exe`, which cannot use a
`\\wsl.localhost` working directory. The scripts then fail with
`Script not found`. Put `~/.bun/bin` before the Windows entries in PATH:

```bash
export PATH="$HOME/.bun/bin:$PATH"
```

**Windows (cross-compiled from Linux or WSL):**

WSL has no Vulkan driver for the GPU, so a Linux build in WSL uses lavapipe
(the CPU). A Windows `.exe` uses D3D12 or Vulkan on the GPU. Zig
cross-compiles it from Linux to `x86_64-windows-gnu`:

```bash
yarn voxel:windows   # build zig-out/bin/voxel.exe, then start it (WSL only)
```

`scripts/windows-deps.sh` downloads the Windows files to `~/.local/windows`:
SDL2 2.32.10 (MinGW development files) and wgpu-native v22.1.0.5
(`x86_64-gnu`). `yarn voxel:windows` runs it first. The build copies
`SDL2.dll` and `wgpu_native.dll` next to `voxel.exe` in `zig-out/bin`. In
WSL, the script copies the three files to `%TEMP%\swindowzig-voxel` and
starts `voxel.exe` there. Outside WSL, it only builds. To build another
example, or to use another folder:

```bash
./scripts/windows-deps.sh <dir>
zig build native -Dexample=<name> -Dtarget=x86_64-windows-gnu -Dwindows-deps=<dir>
```

The log line `sw_gpu: adapter "<name>" backend=<backend> type=<type>` names
the GPU. On Windows, the backend is `d3d12` or `vulkan`.

**macOS (arm64):**
```bash
brew install sdl2

mkdir -p ~/.local/lib ~/.local/include/webgpu && cd /tmp
wget https://github.com/gfx-rs/wgpu-native/releases/download/v22.1.0.5/wgpu-macos-aarch64-release.zip
unzip wgpu-macos-aarch64-release.zip
cp lib/libwgpu_native.a ~/.local/lib/
cp include/webgpu/webgpu.h ~/.local/include/webgpu/
```

**macOS (x86_64):**
```bash
brew install sdl2

mkdir -p ~/.local/lib ~/.local/include/webgpu && cd /tmp
wget https://github.com/gfx-rs/wgpu-native/releases/download/v22.1.0.5/wgpu-macos-x86_64-release.zip
unzip wgpu-macos-x86_64-release.zip
cp lib/libwgpu_native.a ~/.local/lib/
cp include/webgpu/webgpu.h ~/.local/include/webgpu/
```

### Run

```bash
zig build run                      # justabox (default) — spinning colored box
zig build run -Dexample=voxel     # voxel chunk demo
zig build run -Dexample=windows   # triangle with mouse drag
zig build run -Dexample=flat2d    # 2D renderer: rectangles, outline, textured quad
zig build run -Dexample=mipmaps   # GPU mip levels, texture array, anisotropy (Space: sampler)
zig build run -Dexample=atlas     # sw_render texture atlas with animated sprites
zig build run -Dexample=sky       # sw_render sky, fog, day-night cycle, clouds and weather (C: cube map, G: fog, K: clouds, R: weather)
zig build run -Dexample=models    # sw_render instanced box models (Space: animation, D: first-person depth range)
```

### Voxel Demo — CLI Flags

All flags below apply to the voxel example binary (`./zig-out/bin/voxel`).
Build first with `zig build native -Dexample=voxel`.

| Flag | Description |
|------|-------------|
| `--tas <path>` | Load and play a TAS script. Physical input is blocked during playback. |
| `--headless` | No window, no GPU. Ticks as fast as possible. Exits when TAS finishes. |
| `--tas-step` | Frame-by-frame TAS mode. Press Right arrow to advance one TAS tick. Implies `--gpu-debug`. |
| `--gpu-debug` | Highlight freshly rebuilt mesh faces with an orange tint that fades over ~0.5s. |

### Useful Setups

```bash
# Normal play
./zig-out/bin/voxel

# TAS playback — watch a script run in real time
./zig-out/bin/voxel --tas examples/voxel/framespike.tas

# Headless TAS — deterministic simulation, no rendering, exits on completion
./zig-out/bin/voxel --headless --tas examples/voxel/framespike.tas

# Frame-by-frame TAS debugging — step with Right arrow, GPU debug auto-enabled
./zig-out/bin/voxel --tas examples/voxel/framespike.tas --tas-step

# GPU debug in normal play — see mesh rebuild blast radius when placing/removing blocks
./zig-out/bin/voxel --gpu-debug

# Build + run (one-liner)
zig build native -Dexample=voxel && ./zig-out/bin/voxel --tas examples/voxel/framespike.tas --tas-step
```

### Runtime Keyboard Shortcuts (Voxel Demo)

| Shortcut | Action |
|----------|--------|
| WASD | Move (when mouse captured) |
| Mouse | Look (when mouse captured) |
| Left click | Capture mouse / destroy block |
| Right click | Place block |
| Space | Jump / fly up (in fly mode) |
| Space (double-tap) | Toggle fly mode |
| Shift | Sprint / fly down (in fly mode) |
| Escape | Pause menu |
| Cmd+D / Ctrl+D | Toggle debug mode (hitbox cylinder, keyboard HUD) |
| Cmd+G / Ctrl+G | Toggle GPU debug (highlight rebuilt faces) |
| Cmd+V / Ctrl+V | Cycle camera view: first-person → back → front |
| Right arrow | Advance one TAS tick (in `--tas-step` mode) |

---

## Use it as a Zig package

swindowzig publishes tagged releases. A dependent repo pins one release by URL
and hash:

```bash
zig fetch --save https://github.com/seanmizen/swindowzig/releases/download/v<version>/swindowzig.tar.gz
```

```zig
// build.zig
const swindowzig = b.dependency("swindowzig", .{});
exe.root_module.addImport("sw_app", swindowzig.module("sw_app"));
```

The package exports `sw_core`, `sw_platform`, `sw_gpu`, `sw_audio`, `sw_math`,
`sw_gfx2d`, `sw_net`, `sw_jobs` and `sw_app`. The `platform` option picks the platform of these modules:
`web` (the default, no SDL) or `native` (SDL2 from `addTranslateC`):

```zig
const swindowzig = b.dependency("swindowzig", .{ .platform = .native });
```

### Build an example to wasm from a dependent package

`addWebExample` in the `build.zig` of swindowzig builds one example to
wasm32-freestanding. It gives the same artifacts as `zig build web` in this
repo: `app.wasm`, and `chunks.wasm` for `voxel` (`chunks` is null for the
other examples). The build runs in the build of the dependent package. It
starts no second `zig build`.

```zig
// build.zig of the dependent package
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const sw = b.dependency("swindowzig", .{});
    const web = @import("swindowzig").addWebExample(b, sw, .{
        .example = "voxel",
        .optimize = optimize,
    });
    b.installArtifact(web.app); // zig-out/bin/app.wasm
    if (web.chunks) |chunks| b.installArtifact(chunks); // zig-out/bin/chunks.wasm
}
```

The sources come from the dependency, so `--fork` (below) builds the
example from the local checkout.

### Local engine work

To build a dependent repo against a local checkout of swindowzig, use `--fork`.
It replaces the pinned release with the local path:

```bash
zig build --fork=<path to local swindowzig>
```

### Cut a release

1. Set `.version` in `build.zig.zon` (for example `0.2.0`).
2. Merge that change to `main`.
3. Push a tag that matches the version: `git tag v0.2.0 && git push origin v0.2.0`.

`.github/workflows/swindowzig-release.yml` runs on the tag. It makes
`swindowzig.tar.gz` from the `.paths` in `build.zig.zon`, and builds a small
consumer project against the archive. If that build fails, nothing publishes.
If it passes, the workflow attaches the archive to a GitHub Release with the
same tag name. The release notes give the `zig fetch --save` command.

---

## Status (Apr 2026)

### Working
- Window management (SDL2)
- WebGPU rendering — native (Metal/Vulkan) + web (WASM)
- Fixed timestep game loop
- Input (keyboard, mouse)
- Event recording/replay
- 3D math (Vec3, Mat4, perspective, lookAt)
- Indexed drawing with back-face culling
- Hardware depth testing (`depth24plus`)

### Not Yet
- Text rendering
- Texture loading
- Mesh loading (.obj / .gltf)
- Lighting

---

## Examples

| Example | Command | Description |
|---------|---------|-------------|
| `justabox` | `zig build run` | Single colored box, slowly spinning. Default. |
| `windows` | `zig build run -Dexample=windows` | Colored triangle, mouse-drag rotation. |
| `voxel` | `zig build run -Dexample=voxel` | 16x16x16 voxel chunk, Minecraft creative mode. |

---

## Architecture

```
Your Game Code  (init / tick / render / shutdown)
      ↓
swindowzig
  sw_core      — timeline, events, input, record/replay
  sw_platform  — SDL2 (native) | canvas (web)
  sw_gpu       — WebGPU wrapper
  sw_math      — Vec3, Mat4, transforms
  sw_gfx2d     — 2D rectangles, outlines, textured quads (batched)
      ↓
WebGPU
  Native → wgpu-native (Metal / Vulkan / DX12)
  Web    → navigator.gpu
```

---

## Philosophy

Call functions, things happen. No ECS. No magic. Never hide the GPU.

---

## Docs

Heavy reference material lives in [`docs/`](./) — not in CLAUDE.md — so
agents only pay for what they open.

| File | Contents |
|------|----------|
| [`docs/antialiasing.md`](antialiasing.md) | MSAA vs FXAA for voxel worlds; olive-edge explanation; FXAA impl architecture; embedded pixel-diff PNGs; regeneration commands |

Regression runners live under [`examples/voxel/tests/`](../examples/voxel/tests/).
Current:

- [`aa_regression.sh`](../examples/voxel/tests/aa_regression.sh) — captures
  none/fxaa/msaa4 on `msaa_flatland.tas`, emits normalized + amplified diffs,
  prints coverage stats.

---

## TODOs

### Rendering bugs

- [ ] **MSAA edge surface bleed-through.** 4× MSAA currently shows unwanted
  colour bleed across block-on-block silhouette edges (neighbouring surface
  colour leaks into the foreground sample). FXAA does not exhibit this.
  Investigate: sample-shading, depth-resolve interaction, and whether
  bgra8unorm MSAA resolve is averaging
  samples from behind the silhouette. Tracked as a defect against `--aa=msaa`;
  see [`docs/antialiasing.md`](antialiasing.md) for context.
- [ ] **AO shadows lookthrough.** If you're above a voxel looking down
  diagonally, and there's a shadow on the far side, the shadowed face bleeds
  through the roof — it appears "above" the roof on screen, when the roof
  should be occluding it. AO compositing order bug.
- [ ] **Camera clipping exploit.** The purple-block-view-when-inside-a-voxel
  overlay currently only fires when the camera is centrally inside a voxel.
  If the 3PV camera partially clips into a voxel (off-center), the clipped
  portion of the block becomes see-through — an exploit you can use to peek
  through walls. Seek a low-cost fix: sample the camera near-plane corners
  for occlusion, or push the camera back along the view vector until it's
  fully outside any solid block.
- [ ] **FXAA over UI is blurry.** FXAA looks great on terrain and blocks but
  smears menu text and HUD glyphs. Treat UI as a separate render layer that
  isn't FXAA'd — either a second render pass after FXAA that writes UI
  directly to the swapchain, or a UI-to-texture composite. Pick whichever
  is cheaper and cleaner.

### Lighting

- [ ] **Glowstone should produce light.** Block is placed and scattered in
  world gen, but doesn't actually emit visible light into the world yet.
  Hook into block-light BFS so nearby blocks are actually illuminated.
- [ ] **Ambient occlusion depth.** Current per-vertex AO feels shallow —
  likely only sampling von Neumann / face-plane neighbours. Investigate
  Moore-neighbourhood sampling, chunk-level updates, or per-chunk light
  propagation at distance N. Add a configurable shadow strategy (CLI flag
  now, in-game settings menu later).

### UI & settings

- [ ] **Settings menu tidy-up.** Expand the esc menu into Resume / Settings /
  Exit. Settings probably needs Game / Video / Audio tabs. Make the settings
  items actually clickable again. Gateway for AA method, AO strategy, render
  distance, and tunables currently buried in CLI flags. Exit shows a confirm
  prompt. Needs a multi-screen menu state machine rather than the current
  single-pane pause overlay.
- [ ] **Configurable fog distance.** The current fog cutoff is too short —
  want to go much much much further out. Expose as a settings slider (and
  CLI flag in the interim).
- [ ] **Web: cursor not visible when paused.** Even when the game is paused,
  the cursor stays hidden in the web build. Should be visible whenever the
  mouse isn't captured.

### World gen & simulation

- [ ] **Water.** Spawn rivers, then let flow work. This introduces the concept
  of simulation — if outside simulation distance, water should not flow.
- [ ] **Biomes.** Hills, grassland, ocean, river (maybe). Do it the Minecraft
  way — biome map first, then terrain shaped per-biome.
- [ ] **Caves.** Underground cave systems. Carver pass after heightmap gen.
- [ ] **Trees.** Just Oak for now. Place at world gen time above surface.
- [ ] **First-spawn flow in non-flatland worlds.** Today we spawn into rock
  until first input nudges the player free. Fix the order: (a) generate at
  least the first chunk while showing the existing purple loading screen +
  "WORLD LOADING!!!" text, (b) then spawn the player. The first-ever spawn
  resets to the overworld Y. Subsequent spawns keep the stored location
  unless it's blocked — if blocked, scan upward for the lowest available
  1×1×2 air column above the stored spawn point.

### CI / infra

- [ ] **Headless AA regression.** `aa_regression.sh` requires a display + GPU and
  so is not yet part of the mandatory pre-handback checklist. Resolve by
  finding a headless GPU path (offscreen surface creation without a platform
  window) so it can run in CI.

---

**See [CLAUDE.md](../CLAUDE.md) for build instructions, known bugs, and technical details.**
