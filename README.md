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
- **wgpu-native** v0.19.4.1

### Install Dependencies

**Linux / WSL:**
```bash
sudo apt install libsdl2-dev

mkdir -p ~/.local/lib ~/.local/include && cd /tmp
wget https://github.com/gfx-rs/wgpu-native/releases/download/v0.19.4.1/wgpu-linux-x86_64-release.zip
unzip wgpu-linux-x86_64-release.zip
cp libwgpu_native.so ~/.local/lib/
cp webgpu.h wgpu.h ~/.local/include/
```

**macOS:**
```bash
brew install sdl2

mkdir -p ~/.local/lib ~/.local/include && cd /tmp
wget https://github.com/gfx-rs/wgpu-native/releases/download/v0.19.4.1/wgpu-macos-x86_64-release.zip
unzip wgpu-macos-x86_64-release.zip
cp libwgpu_native.dylib ~/.local/lib/
cp webgpu.h wgpu.h ~/.local/include/
```

### Run

```bash
zig build run                      # justabox (default) — spinning colored box
zig build run -Dexample=voxel     # voxel chunk demo
zig build run -Dexample=windows   # triangle with mouse drag
```

---

## Status (Feb 2026)

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
| `voxel` | `zig build run -Dexample=voxel` | 16×16×16 voxel chunk, WASD camera. |

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
