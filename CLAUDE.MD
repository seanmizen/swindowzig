# swindowzig — WASM-First Game Framework Build Manual (v0.1)

This document is the instruction manual for building **swindowzig**, a WASM-first, single-surface window/input/tick/record/replay framework designed to make game and app development dead simple, while staying fast, open, and future-proof.

---

## 1. Overview & Architectural Decisions

### Core Architectural Decisions (Non-Negotiable)

**AD1 (WASM canvas is the tightest constraint)**
The design must work inside a single HTML `<canvas>` with a browser-owned event loop. Desktop backends must conform to that model.

**AD2 (Everything is serializable + published)**
All user actions (mouse, keyboard, resize, focus, etc.) are events on a bus. Sessions can be recorded/replayed (optionally disabled for speed/space).

### Primary Graphics Target

**WebGPU** as the contract:
- **Native**: Uses wgpu-native via wgpu_native_zig
- **Web**: Uses browser WebGPU (navigator.gpu) via a thin JS bridge

---

## 2. Prerequisites & Setup

### 2.1 Required Tools

- **Zig 0.15+** (tested with 0.15.2)
- **Node.js 20+** (for web tooling)
- **Yarn 4** (via corepack)

### 2.2 System Dependencies

**macOS:**
```bash
brew install sdl2
```

**Ubuntu/Debian:**
```bash
sudo apt install libsdl2-dev
```

**Windows:**
```bash
# Via vcpkg or manual SDL2 install
vcpkg install sdl2:x64-windows
```

### 2.3 Yarn Workspace Setup

From monorepo root:
```bash
yarn              # installs all workspace deps
yarn swindowzig   # runs swindowzig (after implementation)
```

---

## 3. Repository Structure

```text
swindowzig/
├── build.zig                   # Root build file
├── build.zig.zon              # Zig dependencies
├── package.json               # Yarn workspace integration
├── CLAUDE.md                  # This file
│
├── libs/                      # Framework modules
│   ├── sw_core/              # Pure logic (no platform/GPU)
│   │   ├── build.zig
│   │   └── src/
│   │       ├── timeline.zig   # Tick timing
│   │       ├── bus.zig        # Event bus
│   │       ├── event.zig      # Event types
│   │       ├── input.zig      # Input snapshots
│   │       ├── record.zig     # Recording
│   │       ├── replay.zig     # Playback
│   │       └── serialize.zig  # Binary format
│   │
│   ├── sw_platform/          # Window/canvas abstraction
│   │   ├── build.zig
│   │   └── src/
│   │       ├── platform.zig   # Platform interface
│   │       ├── backend.zig    # Backend trait
│   │       ├── wasm_canvas.zig # WASM backend
│   │       └── native_sdl.zig  # SDL2 backend
│   │
│   ├── sw_gpu/               # WebGPU API subset
│   │   ├── build.zig
│   │   └── src/
│   │       ├── gpu.zig        # GPU interface
│   │       ├── types.zig      # Common types
│   │       ├── native_wgpu.zig # wgpu-native
│   │       └── web_bridge.zig  # JS imports
│   │
│   └── sw_app/               # User-facing facade
│       ├── build.zig
│       └── src/
│           ├── app.zig        # App entry
│           ├── context.zig    # User context
│           └── run.zig        # Orchestration
│
├── backends/                  # Platform-specific boot code
│   ├── wasm/
│   │   ├── index.html
│   │   ├── boot.ts           # WASM loader
│   │   ├── webgpu.ts         # WebGPU bridge
│   │   ├── events.ts         # DOM event forwarding
│   │   └── dev-server.ts     # Local dev server
│   │
│   └── native/               # Optional packaging scripts
│
└── examples/                  # Example applications
    └── woke_asteroids/
        ├── build.zig
        ├── src/
        │   ├── game.zig       # Pure game logic
        │   ├── renderer.zig   # GPU rendering
        │   └── main.zig       # Entry point
        └── assets/
```

**Design rule**: Examples contain zero platform-specific code. They depend only on `sw_app`, `sw_gpu`, and `sw_core`.

---

## 4. Module Architecture

### 4.1 sw_core (Pure Logic)

**Responsibility**: Owns AD2 — timeline, ticks, bus, serialization, recording/replay, input snapshot.

**Files:**

- `event.zig`
  - Defines Event union and payloads
  - Ensures every event is serializable

- `timeline.zig`
  - Converts monotonic time into ticks
  - Default: FixedStepTimeline with catch-up

- `bus.zig`
  - Buffered event bus (single producer, multi-consumer)
  - Deterministic ordering per tick

- `input.zig`
  - Builds InputSnapshot each tick from events

- `record.zig` / `replay.zig`
  - Record event stream to sink
  - Replay feeds bus with same tick ordering

- `serialize.zig`
  - Binary format, versioned, delta-coded

### 4.2 sw_platform (Single-Surface Window/Canvas + Input)

**Responsibility**: Owns AD1 loop constraints. Backend pumps events into sw_core; sw_platform abstracts window/canvas and event pump.

**Files:**

- `backend.zig`
  - Backend interface:
    - Initialize surface
    - Poll events into queue
    - Provide monotonic time
    - Provide surface size + DPI scale

- `wasm_canvas.zig`
  - No direct DOM access: JS forwards events to exported Zig functions

- `native_sdl.zig`
  - Creates one OS window using SDL2
  - Polls OS events and converts to sw_core Events

### 4.3 sw_gpu (WebGPU-Shaped API)

**Responsibility**: App-facing GPU API is a deliberate subset of WebGPU needed to ship v0.1 games.

**Files:**

- `native_wgpu.zig`
  - Uses wgpu_native_zig to call native WebGPU

- `web_bridge.zig`
  - Imports JS functions for WebGPU object creation and command submission
  - Keeps JS dumb: JS owns actual browser WebGPU objects; Zig owns API shape/state

### 4.4 sw_app (Dead-Simple Facade)

**Responsibility**: The only thing most users import.

**run() sets up:**
- Platform backend
- Timeline
- Bus
- Recorder/replayer
- GPU surface + device (async on web)

**Calls user callbacks:**
- `init(ctx)`
- `tick(ctx)`
- `render(ctx)`
- `shutdown(ctx)`

---

## 5. Public API (v0.1)

### 5.1 App Entry

User code should look like:

```zig
const sw = @import("sw_app");

pub fn main() !void {
    try sw.run(.{
        .title = "Woke Asteroids",
        .size = .{ .w = 1280, .h = 720 },
        .tick_hz = 120,
        .recording = .{ .enabled = false },
    }, struct {
        pub fn init(ctx: *sw.Context) !void {}
        pub fn tick(ctx: *sw.Context) !void {}
        pub fn render(ctx: *sw.Context) !void {}
        pub fn shutdown(ctx: *sw.Context) void {}
    });
}
```

### 5.2 Context

Context provides:

- `ctx.tick_id()` → `u64`
- `ctx.dt_ns()` → `u64`
- `ctx.time_ns()` → `u64` (monotonic)
- `ctx.bus()` → `*sw_core.Bus`
- `ctx.input()` → `*const sw_core.InputSnapshot`
- `ctx.window()` → `sw_platform.WindowInfo` (size, dpi scale)
- `ctx.gpu()` → `*sw_gpu.Gpu` (ready only when device is ready)

### 5.3 Event Model

All events are serializable and contain:

- `tick_id`: `u64`
- `t_ns`: `u64` (monotonic timestamp)
- `seq`: `u32` (ordering within tick)
- `payload`: `EventPayload`

**Payloads (v0.1):**

- `PointerMove { x, y, dx, dy, device_id, mods }`
- `PointerButton { button, down, mods }`
- `Wheel { dx, dy, mode, mods }`
- `Key { keycode, scancode, down, repeat, mods }`
- `Text { utf8: [..] }` (minimal)
- `Resize { width, height, dpi_scale }`
- `Focus { focused }`
- `Lifecycle { Init | Suspend | Resume | Shutdown }`
- Optional: `Tick { dt_ns }` for recording convenience

### 5.4 InputSnapshot

Computed each tick:

- `mouse.pos`, `mouse.delta`
- `mouse.buttons_down`
- `keys.down`, `keys.pressed`, `keys.released`
- `wheel.delta`
- `mods`
- Optional `text_buffer` for that tick

**Rule**: Raw events are always available from the bus; snapshots are ergonomic sugar.

---

## 6. Build System & Yarn Integration

### 6.1 package.json

```json
{
  "name": "swindowzig",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "start": "zig build run",
    "build": "zig build",
    "build:native": "zig build native",
    "build:web": "zig build web && bun build backends/wasm/boot.ts --outdir=dist",
    "test": "zig build test",
    "dev:web": "bun --watch backends/wasm/dev-server.ts"
  }
}
```

### 6.2 build.zig.zon (Zig Dependencies)

```zig
.{
    .name = "swindowzig",
    .version = "0.1.0",
    .dependencies = .{
        .wgpu_native_zig = .{
            .url = "https://github.com/hexops/mach-gpu/archive/main.tar.gz",
            .hash = "1220...", // Replace with actual hash
        },
        .sdl2 = .{
            .url = "https://github.com/MasterQ32/SDL.zig/archive/main.tar.gz",
            .hash = "1220...", // Replace with actual hash
        },
    },
}
```

### 6.3 Zig Build Targets

Provide build steps:

```bash
zig build native -Dtarget=x86_64-windows-gnu
zig build native -Dtarget=x86_64-linux-musl
zig build native -Dtarget=aarch64-macos
zig build web  # Outputs dist/ with WASM + boot JS/TS
```

### 6.4 Web Toolchain

Use Bun to bundle TypeScript boot files:

```bash
bun build backends/wasm/boot.ts --outdir=dist
```

The WASM binary is produced by `zig build web`.

### 6.5 Root Monorepo Integration

Add to `/Users/seanmizen/projects/seanorepo/package.json`:

```json
{
  "scripts": {
    "swindowzig": "yarn workspace swindowzig start"
  }
}
```

Then from anywhere in the monorepo:

```bash
yarn swindowzig  # Runs zig build run
```

---

## 7. Backends (Native SDL2 + Web)

### 7.1 Native (SDL2)

**sw_platform/native_sdl.zig responsibilities:**

- Create single window
- Collect OS events
- Produce sw_core Events
- Provide monotonic time (`std.time` or platform timer)
- Report resize + DPI scale

**sw_gpu/native_wgpu.zig responsibilities:**

- Create instance/device/queue
- Create surface from native window handle
- Configure surface
- Present

### 7.2 Web (WASM)

**JS is the host:**

- Creates canvas
- Attaches DOM event listeners
- Acquires WebGPU device/queue/context
- Calls into WASM exports

**Zig exports:**

- `swindowzig_init()`
- `swindowzig_event_*()` for event injection
- `swindowzig_frame(ts_ms: f64)`

**JS calls:**

```typescript
requestAnimationFrame((ts) => {
  wasm.swindowzig_frame(ts);
});
```

---

## 8. Timing, Events & Record/Replay

### 8.1 Canonical Timeline

swindowzig owns canonical time. Apps should not invent their own tick base if they want replay/simulation to be meaningful.

**Default: FixedStepTimeline (hz=120)**

- Backend provides `now_ns`
- Timeline accumulates `accum_ns`
- Each frame:
  - Run 0..k ticks to catch up
  - Clamp catch-up to prevent spiral-of-death
  - Render once

**Alternative: VariableStepTimeline**

- One tick per frame, dt derived from frame dt
- Less deterministic, but simplest for apps

### 8.2 Browser Frame Loop

Web backend uses requestAnimationFrame:

- JS calls `swindowzig_frame(ts_ms)`
- Zig converts timestamp to `now_ns`
- Zig advances timeline, drains queued events, runs ticks, renders

### 8.3 Recorder

Recorder is a bus subscriber:

- Writes a versioned binary stream
- Delta-encodes tick and time
- Optionally includes Tick events

**Toggles:**

- `recording.enabled` default `false`
- Can be enabled at runtime

### 8.4 Replayer

Replayer reads stream and feeds bus:

- Preserves tick ordering + seq
- Allows:
  - Play/pause
  - Step tick
  - Seek (optional v0.2)

**Note:**

- Determinism of simulation is app responsibility (pure logic, no entropy)
- swindowzig ensures deterministic input event stream

---

## 9. GPU (WebGPU Contract)

### 9.1 Goals

- Same rendering code in Zig for native and web
- Minimal subset to ship Woke Asteroids

### 9.2 Device Initialization

WebGPU device acquisition is async on web.

**Design:**

`ctx.gpu().state` is:
- `Pending` (init requested)
- `Ready`
- `Failed`

**Apps should:**
- In `render()` return early if not ready

### 9.3 v0.1 GPU API Subset

**Surface:**
- `configure(width, height, format)`
- Acquire texture view
- Present

**Device/Queue:**
- `createBuffer` / `writeBuffer`
- `createShaderModule` (WGSL)
- `createBindGroupLayout` / `BindGroup`
- `createPipelineLayout`
- `createRenderPipeline`

**Commands:**
- `createCommandEncoder`
- `beginRenderPass`
- `setPipeline`, `setBindGroup`, `setVertexBuffer`, `setIndexBuffer`
- `draw` / `drawIndexed`
- Finish encoder, submit queue

### 9.4 Shaders

**WGSL** for v0.1.

---

## 10. Implementation Milestones

### Milestone A — sw_core

**Files to create:**

1. `libs/sw_core/build.zig` — Module build config
2. `libs/sw_core/src/event.zig` — Event union + payloads
3. `libs/sw_core/src/bus.zig` — Buffered event bus
4. `libs/sw_core/src/timeline.zig` — FixedStepTimeline
5. `libs/sw_core/src/input.zig` — InputSnapshot builder
6. `libs/sw_core/src/serialize.zig` — Binary format
7. `libs/sw_core/src/record.zig` — Recorder
8. `libs/sw_core/src/replay.zig` — Replayer

**Test criteria:**

- `zig build test` passes for sw_core
- Can record events to buffer and replay them
- Timeline produces correct tick counts

**Yarn verification:**

```bash
yarn test  # Runs zig build test
```

---

### Milestone B — sw_platform (native SDL2)

**Files to create:**

1. `libs/sw_platform/build.zig` — Module build config
2. `libs/sw_platform/src/backend.zig` — Backend interface
3. `libs/sw_platform/src/platform.zig` — Platform types
4. `libs/sw_platform/src/native_sdl.zig` — SDL2 implementation

**Test criteria:**

- Can create window
- Events flow into bus
- Monotonic time works
- Resize and DPI scale events fire correctly

**Yarn verification:**

```bash
zig build test
```

---

### Milestone C — sw_platform (web)

**Files to create:**

1. `libs/sw_platform/src/wasm_canvas.zig` — WASM backend
2. `backends/wasm/index.html` — Canvas HTML
3. `backends/wasm/boot.ts` — WASM loader
4. `backends/wasm/events.ts` — DOM → Zig event forwarding
5. `backends/wasm/dev-server.ts` — Local HTTP server

**Test criteria:**

- Canvas renders
- Mouse/keyboard events reach Zig
- requestAnimationFrame calls `swindowzig_frame()`

**Yarn verification:**

```bash
yarn build:web
yarn dev:web
# Open http://localhost:3000
```

---

### Milestone D — sw_gpu (native wgpu)

**Files to create:**

1. `libs/sw_gpu/build.zig` — Module build config
2. `libs/sw_gpu/src/gpu.zig` — GPU interface
3. `libs/sw_gpu/src/types.zig` — Common types
4. `libs/sw_gpu/src/native_wgpu.zig` — wgpu-native implementation

**Test criteria:**

- Device/queue/surface created
- Clear screen to solid color
- Simple triangle renders

**Yarn verification:**

```bash
zig build run  # Should show colored window or triangle
```

---

### Milestone E — sw_gpu (web)

**Files to create:**

1. `libs/sw_gpu/src/web_bridge.zig` — JS imports
2. `backends/wasm/webgpu.ts` — WebGPU initialization bridge

**Test criteria:**

- WebGPU device acquired in browser
- Clear screen to solid color
- Simple triangle renders

**Yarn verification:**

```bash
yarn build:web
yarn dev:web
# Open http://localhost:3000 — should see triangle
```

---

### Milestone F — sw_app + Woke Asteroids

**Files to create:**

1. `libs/sw_app/build.zig` — Module build config
2. `libs/sw_app/src/app.zig` — App interface
3. `libs/sw_app/src/context.zig` — User context
4. `libs/sw_app/src/run.zig` — Orchestration
5. `examples/woke_asteroids/build.zig`
6. `examples/woke_asteroids/src/game.zig` — Game logic
7. `examples/woke_asteroids/src/renderer.zig` — GPU rendering
8. `examples/woke_asteroids/src/main.zig` — Entry point

**Test criteria:**

- Woke Asteroids runs on native
- Woke Asteroids runs in browser
- Input events can be recorded and replayed

**Yarn verification:**

```bash
# Native
cd examples/woke_asteroids
zig build run

# Web
zig build web
yarn dev:web
# Open http://localhost:3000
```

---

## 11. Example: Woke Asteroids

### 11.1 Game Design Goals

- Moves asteroids, player ship, bullets
- Uses deterministic fixed-step update (derived from `ctx.dt` / `tick_id`)
- Input from `ctx.input()`
- Rendering via sw_gpu API subset

### 11.2 Separation of Concerns

**game.zig: pure logic**
- State structs
- `update(tick, input)`
- No GPU calls

**renderer.zig: draw logic**
- Creates pipelines/buffers
- Draws from game state

**main.zig: glue**
- `sw_app.run`
- Calls `game.update` + `renderer.draw`

### 11.3 game.zig Skeleton

```zig
pub const Game = struct {
    // positions, velocities, RNG seed if needed (seeded deterministically)

    pub fn init(alloc: std.mem.Allocator) !Game {
        _ = alloc;
        return .{};
    }

    pub fn update(self: *Game, input: *const Input, dt: f32) void {
        _ = self;
        _ = input;
        _ = dt;
    }
};

pub const Input = struct {
    thrust: bool,
    turn_left: bool,
    turn_right: bool,
    fire: bool,
    mouse_x: f32,
    mouse_y: f32,
};
```

### 11.4 main.zig Skeleton

```zig
const sw = @import("sw_app");
const game_mod = @import("game.zig");
const renderer_mod = @import("renderer.zig");

pub fn main() !void {
    var game: game_mod.Game = undefined;
    var renderer: renderer_mod.Renderer = undefined;

    try sw.run(.{
        .title = "Woke Asteroids",
        .size = .{ .w = 1280, .h = 720 },
        .tick_hz = 120,
        .recording = .{ .enabled = false },
    }, struct {
        pub fn init(ctx: *sw.Context) !void {
            game = try game_mod.Game.init(ctx.allocator());
            renderer = try renderer_mod.Renderer.init(ctx);
        }

        pub fn tick(ctx: *sw.Context) !void {
            const in = ctx.input();
            const input = game_mod.Input{
                .thrust = in.keyDown(.W) or in.keyDown(.Up),
                .turn_left = in.keyDown(.A) or in.keyDown(.Left),
                .turn_right = in.keyDown(.D) or in.keyDown(.Right),
                .fire = in.keyPressed(.Space),
                .mouse_x = in.mouse.x,
                .mouse_y = in.mouse.y,
            };

            const dt = @as(f32, @floatFromInt(ctx.dt_ns())) / 1_000_000_000.0;
            game.update(&input, dt);
        }

        pub fn render(ctx: *sw.Context) !void {
            if (!ctx.gpu().isReady()) return;
            try renderer.draw(ctx, &game);
        }

        pub fn shutdown(ctx: *sw.Context) void {
            _ = ctx;
        }
    });
}
```

---

## 12. Coding Standards

- **Single-threaded** assumptions by default (browser compatibility)
- **No platform-specific code** in game logic
- **All inputs become events**; snapshots are derived
- **Web is the strictest target**; never add native-only assumptions
- **Prefer small, stable APIs**; grow by adding modules, not breaking core types

### Code Quality Requirements

**CRITICAL: Zero-error commits**
- All code must compile without errors before committing
- Run `zig build` to verify compilation
- Check for diagnostic errors in IDE before considering code complete
- Never ship stub functions with unused parameters that cause "pointless discard" errors
- Use proper Zig unused parameter syntax: `_: Type` not `name: Type` followed by `_ = name`

**Example - WRONG:**
```zig
fn stub(ctx: *Context, data: Data) void {
    _ = ctx;  // Error: pointless discard
    _ = data; // Error: pointless discard
}
```

**Example - RIGHT:**
```zig
fn stub(_: *Context, _: Data) void {
    // Clean, compiles without warnings
}
```

**Pre-commit checklist:**
1. `zig build` succeeds with zero errors
2. No diagnostic errors in IDE
3. All tests pass (`zig build test`)
4. Code follows Zig naming conventions (camelCase for functions, PascalCase for types)
5. No TODO comments in critical paths that would cause runtime failures

---

## 13. Development Workflow

### 13.1 Quick Iteration (Native)

```bash
yarn start                  # zig build run - builds and runs
zig build run -freload      # with hot reload (if supported)
```

### 13.2 Web Development

```bash
yarn build:web              # build WASM + bundle TS
yarn dev:web                # watch mode with live reload
# Open http://localhost:3000
```

### 13.3 Testing

```bash
yarn test                   # all tests
zig build test -Dfilter="bus"  # filter specific tests
```

### 13.4 Debugging WASM

- Use browser DevTools
- `console.log` via JS bridge
- Zig panic handler logs stack trace to console

### 13.5 Error Handling

**WASM Panic Handler:**

```zig
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;
    // Log to JS console
    jsLogError(msg.ptr, msg.len);
    @trap();
}
```

**Error Propagation:**

- Errors across WASM boundary must be converted to result codes or logged
- Use `!void` return types liberally; handle errors at boundary

---

## 14. Notes on Mach

Mach is optional. swindowzig core should not require it.

If later desired:
- Add a `sw_platform/native_mach.zig` backend
- Do not couple `sw_gpu` to Mach sysgpu unless explicitly choosing a "WebGPU-like façade" instead of strict WebGPU

---

## What "Done" Means for v0.1

- `zig build native` runs Woke Asteroids on Windows/Linux/macOS
- `zig build web` runs Woke Asteroids in browser canvas via WebGPU
- Input events can be recorded and replayed deterministically through the bus
- The user-facing API is `sw.run(config, callbacks)` and stays stable

---

**End of manual.**
