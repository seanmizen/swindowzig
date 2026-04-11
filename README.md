# swindowzig

**A thin WebGPU wrapper for game development.**
Write once, run anywhere: web browsers (WASM) and native desktops (Windows/macOS/Linux).

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

- **Zig 0.15.2+**
- **SDL2**
- **wgpu-native** v22.1.0.5 (bindings are pinned to this version's header; re-diff when upgrading)

### Install Dependencies

**Linux / WSL:**
```bash
sudo apt install libsdl2-dev

mkdir -p ~/.local/lib ~/.local/include/webgpu && cd /tmp
wget https://github.com/gfx-rs/wgpu-native/releases/download/v22.1.0.5/wgpu-linux-x86_64-release.zip
unzip wgpu-linux-x86_64-release.zip
cp lib/libwgpu_native.a ~/.local/lib/
cp include/webgpu/webgpu.h ~/.local/include/webgpu/
```

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

## Status (Apr 2026)

### Working
- Window management (SDL2)
- WebGPU rendering — native (Metal/Vulkan) + web (WASM)
- Fixed timestep game loop
- Input (keyboard, mouse)
- Event recording/replay
- 3D math (Vec3, Mat4, perspective, lookAt)
- Indexed drawing with back-face culling
- Software depth sorting (painter's algorithm — workaround for Metal depth testing bug)

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

Heavy reference material lives in [`docs/`](docs/) — not in CLAUDE.md — so
agents only pay for what they open.

| File | Contents |
|------|----------|
| [`docs/antialiasing.md`](docs/antialiasing.md) | MSAA vs FXAA for voxel worlds; olive-edge explanation; FXAA impl architecture; embedded pixel-diff PNGs; regeneration commands |

Regression runners live under [`examples/voxel/tests/`](examples/voxel/tests/).
Current:

- [`aa_regression.sh`](examples/voxel/tests/aa_regression.sh) — captures
  none/fxaa/msaa4 on `msaa_flatland.tas`, emits normalized + amplified diffs,
  prints coverage stats.

---

## TODOs

- [ ] **MSAA edge surface bleed-through.** 4× MSAA currently shows unwanted
  colour bleed across block-on-block silhouette edges (neighbouring surface
  colour leaks into the foreground sample). FXAA does not exhibit this.
  Investigate: sample-shading, depth-resolve interaction with the painter's-
  algorithm sort order, and whether bgra8unorm MSAA resolve is averaging
  samples from behind the silhouette. Tracked as a defect against `--aa=msaa`;
  see [`docs/antialiasing.md`](docs/antialiasing.md) for context.
- [ ] **Headless AA regression.** `aa_regression.sh` requires a display + GPU and
  so is not yet part of the mandatory pre-handback checklist. Resolve by
  finding a headless GPU path (offscreen surface creation without a platform
  window) so it can run in CI.
- [ ] **Camera clipping exploit.** The purple-block-view-when-inside-a-voxel
  overlay currently only fires when the camera is centrally inside a voxel.
  If the 3PV camera partially clips into a voxel (off-center), the clipped
  portion of the block becomes see-through — an exploit you can use to peek
  through walls. Seek a low-cost fix: sample the camera near-plane corners
  for occlusion, or push the camera back along the view vector until it's
  fully outside any solid block.
- [ ] **Ambient occlusion depth.** Current per-vertex AO feels shallow —
  likely only sampling von Neumann / face-plane neighbours. Investigate
  Moore-neighbourhood sampling, chunk-level updates, or per-chunk light
  propagation at distance N. Add a configurable shadow strategy (CLI flag
  now, in-game settings menu later).
- [ ] **FXAA over UI is blurry.** FXAA looks great on terrain and blocks but
  smears menu text and HUD glyphs. Treat UI as a separate render layer that
  isn't FXAA'd — either a second render pass after FXAA that writes UI
  directly to the swapchain, or a UI-to-texture composite. Pick whichever
  is cheaper and cleaner.
- [ ] **Settings menu.** Expand the esc menu into Resume / Settings / Exit.
  Settings is its own screen — the gateway for AA method, AO strategy,
  render distance, and any future tunables currently exposed only as CLI
  flags. Exit shows a confirm prompt. Needs a multi-screen menu state
  machine rather than the current single-pane pause overlay.
- [ ] **First-spawn flow in non-flatland worlds.** Today we spawn into rock
  until first input nudges the player free. Fix the order: (a) generate at
  least the first chunk while showing the existing purple loading screen +
  "WORLD LOADING!!!" text, (b) then spawn the player. The first-ever spawn
  resets to the overworld Y. Subsequent spawns keep the stored location
  unless it's blocked — if blocked, scan upward for the lowest available
  1×1×2 air column above the stored spawn point.

---

**See [CLAUDE.md](CLAUDE.md) for build instructions, known bugs, and technical details.**
