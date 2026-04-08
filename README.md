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

**See [CLAUDE.md](CLAUDE.md) for build instructions, known bugs, and technical details.**
