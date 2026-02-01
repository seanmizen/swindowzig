# swindowzig

**A thin WebGPU wrapper for game development.**
Write once, run anywhere: web browsers (WASM) and native desktops (Windows/macOS/Linux).

---

## What It Is

**Imperative infrastructure for 3D games, not a framework.**

You get:
- Window management (SDL2 on native, canvas on web)
- Input handling (keyboard, mouse, gamepad)
- Fixed timestep game loop (deterministic)
- Full WebGPU API access
- Event recording/replay

You decide:
- Game architecture (ECS, OOP, data-oriented, etc.)
- Rendering approach
- Asset pipeline

---

## Quick Example

```zig
const sw = @import("sw_app");

pub fn main() !void {
    try sw.run(.{
        .title = "My RTS",
        .size = .{ .w = 1920, .h = 1080 },
        .tick_hz = 120,
    }, GameCallbacks);
}

const GameCallbacks = struct {
    pub fn init(ctx: *sw.Context) !void {
        // Load 3D assets
        terrain = try ctx.gpu().loadMesh("terrain.obj");
    }

    pub fn tick(ctx: *sw.Context) !void {
        // Game logic (deterministic, 120 Hz)
        const input = ctx.input();
        if (input.keyDown(.W)) camera.moveForward(0.5);
    }

    pub fn render(ctx: *sw.Context) !void {
        const gpu = ctx.gpu();

        // 3D rendering
        gpu.setCamera(camera);
        gpu.drawMesh(terrain);

        // 2D UI overlay
        gpu.begin2DPass();
        gpu.drawText("Resources: 1500", .{10, 10});
        gpu.end2DPass();

        gpu.present();
    }
};
```

---

## Status (Feb 2026)

### ✅ Working
- Window management (SDL2)
- Event system with record/replay
- Fixed timestep game loop
- **Native WebGPU rendering** (~600 FPS triangle)
- Input handling (keyboard, mouse)
- FPS tracking and debug overlay

### 🚧 In Progress
- Text rendering
- Geometric primitives (lines, rects, circles)
- Texture loading
- 3D camera helpers

### 📋 Planned
- Mesh loading (.obj, .gltf)
- Lighting system
- Shadow mapping
- More examples

**Current demo:** Triangle renders at ~600 FPS with live FPS counter and mouse tracking.

---

## Quick Start

### Prerequisites

- **Zig 0.15.2+** - [Download](https://ziglang.org/download/)
- **SDL2** - `brew install sdl2` (macOS) or `sudo apt install libsdl2-dev` (Linux)
- **Node/Bun** - For web builds

### Run Native Example

```bash
zig build run
# Opens window with triangle demo
```

### Run Web Example

```bash
zig build web
bun backends/wasm/dev-server.ts
# Open http://localhost:3000
```

---

## Philosophy

### Imperative, Not Declarative

**Bad (declarative):**
```zig
scene.add(Entity{
    .components = &[_]Component{
        Transform{...},
        Mesh{...},
    },
});
```

**Good (imperative):**
```zig
gpu.drawMesh(mesh, transform);
```

Call functions, things happen. No magic ECS system.

### Full WebGPU Access

Never hide the GPU API. Helpers are optional.

```zig
// Full control:
const buffer = try gpu.createBuffer(.{
    .size = data.len,
    .usage = .{ .vertex = true },
});

// Or use helpers:
const mesh = try gpu.loadMesh("model.obj");
```

### Deterministic by Default

- Fixed timestep (configurable)
- Serializable events
- Built-in record/replay
- Perfect for RTS games and simulations

---

## Architecture

```
┌─────────────────────────────────────┐
│ Your Game Code                      │
│ ├─ init(ctx)                        │
│ ├─ tick(ctx)  ← Game logic         │
│ └─ render(ctx) ← GPU calls          │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│ swindowzig                          │
│ ├─ sw_core (timeline, events)      │
│ ├─ sw_platform (window, input)     │
│ ├─ sw_gpu (WebGPU wrapper)         │
│ └─ sw_app (entry point)            │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│ WebGPU (same on web + native)      │
│ ├─ Web: navigator.gpu              │
│ └─ Native: wgpu-native/Dawn        │
└─────────────────────────────────────┘
```

### Modules

**sw_core** (✅ Complete)
- `timeline.zig` - Fixed timestep timing
- `bus.zig` - Event queue with ordering
- `event.zig` - Serializable event types
- `input.zig` - Input snapshot per tick
- `record.zig` / `replay.zig` - Session recording

**sw_platform** (✅ Complete)
- `native_sdl.zig` - SDL2 implementation
- `wasm_canvas.zig` - HTML canvas implementation

**sw_app** (✅ Complete)
- `app.zig` - Entry point (`run()` function)
- `context.zig` - User context (tick, input, gpu)

**sw_gpu** (✅ Working)
- Full WebGPU API wrapper
- Resource lifecycle management
- Cross-platform (web + native)

---

## Use Cases

### Perfect For
- **RTS games** - 3D units, terrain, 2D UI
- **FPS games** - 3D world, custom shaders
- **3D platformers**
- **Data visualization** - 3D graphs, scientific viz
- **Game prototypes** - Minimal boilerplate
- **Game jams**
- **Learning WebGPU**

### Not Ideal For
- Production MMOs (need networking, servers, etc.)
- Non-programmers (no visual editor)
- Pure 2D pixel art (simpler tools exist)

---

## TODO / Roadmap

### High Priority

**1. Text Rendering** (4-6 hours)
- SDF font rendering
- Bitmap font fallback
- In-window debug overlay

**2. Geometric Primitives** (2-3 hours)
- Lines, rectangles, circles, ellipses
- Filled and outline modes
- Batched rendering

**3. Test Suite** (4-6 hours)
- Struct layout validation
- Resource lifecycle tests
- Integration tests

### Medium Priority

**4. Texture Loading** (3-4 hours)
- stb_image integration
- PNG/JPG support
- Texture samplers

**5. 3D Camera System** (2-3 hours)
- Perspective projection
- View matrices
- Orbit/FPS camera controls

**6. Mesh Loading** (4-6 hours)
- .obj parser
- Vertex/index buffers
- Normal calculation

### Future

- Lighting system (Phong/Blinn-Phong)
- Shadow mapping
- Particle systems
- More examples
- Full documentation
- CI/CD pipeline

**See [CLAUDE.md](CLAUDE.md) for technical implementation details and testing strategy.**

---

## Examples

### Triangle Demo (Current)
```bash
zig build run
```
- Renders colored triangle
- Shows FPS counter (~600 FPS)
- Tracks mouse position
- Tests WebGPU pipeline

### Coming Soon
- Rotating cube (3D camera)
- Textured quad (texture loading)
- Particle system
- RTS prototype
- 3D model viewer

---

## Performance

**Current:** ~600 FPS (single triangle)
**Target:** 60 FPS stable (complex scenes with thousands of objects)
**Backend:** Metal on macOS, Vulkan on Linux, D3D12 on Windows (via wgpu-native)

---

## Comparison to Other Tools

**vs Raw WebGPU:**
- ✅ Boilerplate handled (window, input, timing)
- ✅ Same code for web and native
- ✅ Built-in record/replay

**vs Mach Engine:**
- Different philosophy (imperative vs declarative)
- No enforced ECS
- Thinner wrapper

**vs Game Engines (Unity, Godot):**
- Code-only (no visual editor)
- Full control over everything
- Learning curve (but you learn WebGPU properly)

---

## Contributing

Not accepting contributions yet - API still in flux.

Once the helper layer stabilizes, contributions welcome!

---

## License

MIT

---

**For technical details, build instructions, and troubleshooting, see [CLAUDE.md](CLAUDE.md)**
