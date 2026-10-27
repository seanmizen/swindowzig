---
paths:
  - "libs/**"
  - "backends/**"
---

# swindowzig libraries

Read with `CLAUDE.md`.

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

### TextureViewDimension enum mismatch (fixed in gpu.zig — createBindGroupLayout)
`types.TextureViewDimension` starts at 0 (`@"1d"=0, @"2d"=1`), but native
`WGPUTextureViewDimension` has `undefined=0, 1d=1, 2d=2`. Raw `@intFromEnum`
would map `.@"2d"→1` which is `WGPUTextureViewDimension.1d` — wrong, crashes
with "Texture binding N expects dimension = D1, but given a view with dimension = D2".
`createBindGroupLayout` now uses explicit switch maps for both `.texture.view_dimension`
and `.storage_texture.view_dimension`. Do not use raw `@intFromEnum` for these.

### CompareFunction enum mismatch (fixed in gpu.zig — createRenderPipeline)
`types.CompareFunction` starts at 0 (`never=0, less=1, …, always=7`), but native
`WGPUCompareFunction` has `undefined=0, never=1, less=2, …, always=8`. Additionally,
the order of `equal`, `not_equal`, and `greater_equal` differs between the two enums.
Raw `@intFromEnum` would map `.less→1 = never` — silently making the depth test always
reject every fragment (blank sky-only output). `createRenderPipeline` now uses
`toNativeCompareFunction()`, an explicit named switch, for all three CompareFunction
fields (depth_compare, stencil_front.compare, stencil_back.compare).
Do not use raw `@intFromEnum` for CompareFunction conversions.

### Sampler and view enum mismatches (fixed in gpu.zig)
`types.AddressMode` starts with `clamp_to_edge=0`, but `WGPUAddressMode` starts
with `repeat=0`. `types.TextureViewDimension` starts with `1d=0`, but the
native enum and webgpu.ts use `undefined=0, 1d=1, 2d=2`. `createSampler` and
`Texture.createView` use named maps (`toNativeAddressMode`,
`viewDimensionCode`). A sampler with `max_anisotropy > 1` needs linear
filters: `SamplerDescriptor.validate` gives an error before the GPU sees it.

### Hardware depth testing (macOS/Metal)
Hardware depth testing is **enabled** in the voxel pipeline (`depth24plus`,
`depth_write_enabled = true`, `depth_compare = .less`). The Metal crash
(`wgpuDeviceCreateRenderPipeline` bus error at 0x29) was a wgpu-native v0.19.4.1
bug and is fixed in the current pinned version (v22.1.0.5).

The depth texture `sample_count` must match the MSAA sample count of the colour
attachment — otherwise wgpu-native raises a validation error on render-pass begin.

The depth test is always on. The voxel demo has no software quad sort. It
draws the chunks front to back (view-space depth of the chunk centre), so the
depth test rejects hidden fragments before they shade.

### WebGPU C ABI details

- A C `size_t` field maps to `usize` in Zig, never `u32`: `entry_count`,
  `bind_group_layout_count`, `constant_count`, `required_features_count`,
  `dynamic_offset_count`, `command_count`.
- Set `WGPURenderPassColorAttachment.depth_slice` to `0xFFFFFFFF`
  (`WGPU_DEPTH_SLICE_UNDEFINED`).
- Timestamps: `WGPURenderPassTimestampWrites` and
  `WGPUComputePassTimestampWrites` take `beginning_of_pass_write_index` and
  `end_of_pass_write_index`.

### Context and events

- Get the event bus with `ctx.bus()`. There is no `ctx.eventBus()`.
- Use `const` for an ArrayList result that does not change.
- Make an event with `Event.init(tick_id, t_ns, seq, payload)`. Payload shapes:

```zig
.key = .{ .keycode = key, .scancode = 0, .down = true, .repeat = false, .mods = mods }
.pointer_move = .{ .x = 0, .y = 0, .dx = dx, .dy = dy, .device_id = 0, .mods = mods }
.pointer_button = .{ .button = btn, .down = true, .mods = mods }
.wheel = .{ .dx = 0, .dy = 1, .mode = .line, .mods = mods } // dy > 0 scrolls up
```

- `KeyCode` is append-only: a recording stores its values (REQ-INPUT-001).
  The punctuation and navigation keys follow the physical key on the web
  (`KeyboardEvent.code`) and on SDL (the scancode) (REQ-INPUT-002).

### Text input (IME)

- `ctx.startTextInput()` and `ctx.stopTextInput()` turn the platform input
  method on and off. Off is the default. While it is off, `Bus.push` drops
  `text_input` and `text_composition`.
- `text_input` is committed UTF-8 (32 bytes at most per event, cut on a code
  point). `text_composition` is the uncommitted text and its caret. Empty text
  ends the composition. `input().text` and `input().composition` hold both.
- `text_composition` is the last member of `EventPayload` (serialize tag 10).
  New members go after it.
- Web: `backends/wasm/events.ts` owns a hidden `<input>`.
- Web: `backends/wasm/loader.ts` builds the full wasm import table for the dev
  page and for minecraft.seanmizen.com. Put a new import there only. The two
  `boot.ts` files only give options to the loader.
- Web: the loader starts the chunk worker pool (`backends/wasm/worker-pool.ts`)
  first, and gives it to the "chunks" imports. `chunk-worker.ts` runs in each
  Web Worker. It has no imports, so the dev server sends it as one file.
- Headless: `backends/wasm/headless-app.ts` runs `app.wasm` in Bun with stub
  WebGPU imports and the real worker pool. `headless.ts` (CI) and
  `worker-pool.test.ts` use it. The stub records the GPU buffers and the
  writes to them, and checks the rules of `writeBuffer` (`StubGpu`).
- Web: `gpu.writeBufferHeld` writes bytes that JS holds
  (`backends/wasm/held-bytes.ts`, by handle) to a GPU buffer. The bytes do
  not go through the wasm memory. The WebGPU bridge owns the store, and the
  "chunks" imports fill it. A native build has no held bytes.

### UI tree (sw_ui)

- Each frame: `u.begin(input, w, h)`, build nodes with non-zero `u32` IDs,
  `u.finish()`, then read `u.frameEvents()` (`activate`, `cancel`, `changed`,
  `submit`). Draw with `sw_ui.draw.draw`. Read `u.semanticTree()` for assistive
  technology.
- Focus: Tab and Shift+Tab in tree order. A list is one tab stop, and Up and
  Down move inside it. Enter and Space activate. Escape sends `cancel`.
- Text field: when `u.wantsTextInput()` changes, call `ctx.startTextInput()` or
  `ctx.stopTextInput()`. The app owns the text (`sw_ui.TextValue`).
- A string that the app gives to a node must stay valid until the next
  `begin`. `u.print` makes one in a per-frame buffer.
- Web: `finish` sends the semantic tree to `backends/wasm/a11y.ts` when it
  changes (`web_mirror.zig`). That file keeps a hidden DOM tree for screen
  readers, and gives DOM focus to the focused node (REQ-A11Y-001).
  `yarn test:a11y` (Playwright, Chromium) tests it with flat2d.
- Web entry: the browser does not call `main`. An app that uses `sw.run`
  calls `sw.exportWeb(config, Callbacks)` in a `comptime` block, and sets
  `std_options.logFn` to `sw.webLogFn`. See `examples/flat2d/main.zig`.

### Known issue

The replay buffer cleanup leaks memory. It is not critical. (Recorded in an
earlier session and not checked again since.)

---

## Adding New WebGPU Features

1. Check wgpu-native headers: `~/.local/include/webgpu/webgpu.h`
2. Add C binding to `native_webgpu.zig`
3. Add Zig wrapper in `gpu.zig`
4. Add corresponding web path in `web_bridge.zig`
5. Release anything you create (wgpu uses reference counting)

---

## File Map

Key files and what they do — read this before opening anything.

### Core libraries (`libs/`)

| File | Purpose |
|------|---------|
| `libs/sw_app/src/app.zig` | `sw.run()` entry point, owns the main loop |
| `libs/sw_app/src/context.zig` | `Context` passed to every callback, holds allocator, bus, tick info |
| `libs/sw_core/src/event.zig` | `Event` union — all input/system event variants |
| `libs/sw_core/src/bus.zig` | Event bus: push/subscribe per tick |
| `libs/sw_core/src/input.zig` | Keyboard/mouse snapshot, edge detection |
| `libs/sw_core/src/record.zig` | Record events to a TAS file |
| `libs/sw_core/src/replay.zig` | Replay events from a TAS file |
| `libs/sw_core/src/tas.zig` | TAS file format (parse/write) |
| `libs/sw_gpu/src/gpu.zig` | Main GPU API — `GPU` struct, all `create*` / `begin*` / `submit` methods |
| `libs/sw_gpu/src/native_webgpu.zig` | Raw C bindings for wgpu-native (`WGPUFoo` types) |
| `libs/sw_gpu/src/types.zig` | Shared descriptor types used by both native and WASM paths |
| `libs/sw_gpu/src/web_bridge.zig` | WASM/JS extern bindings |
| `libs/sw_gpu/src/mip_chain.zig` | Mip level counts and sizes, the atlas tile limit, and the CPU reference box filter (no GPU code, unit tested) |
| `libs/sw_gpu/src/mipmap.zig` | `MipmapGenerator`: makes mip levels with render passes, native and web (REQ-GPU-001, REQ-GPU-002) |
| `libs/sw_platform/src/native_sdl.zig` | SDL2 window + event pump (native path). `initStorage` opens the per-user save directory |
| `libs/sw_platform/src/storage.zig` | Local key-value saves: `storageGet`/`storageSet`/`storageDelete`. Keys `[a-z0-9_-]`, 64 max. Native: files. Web: localStorage via `backends/wasm/storage.ts` |
| `libs/sw_math/src/mat4.zig` | 4×4 matrix: `perspective()`, `lookAt()`, multiply |
| `libs/sw_math/src/vec3.zig` | Vec3 ops. `vec2.zig` and `vec4.zig` have the same ops. `Mat4.mulVec4` multiplies a Vec4 |
| `libs/sw_math/src/quat.zig` | `Quat`: `fromAxisAngle`, `mul`, `rotate`, `slerp`, `toMat4` (same rotation direction as `Mat4.rotationX/Y/Z`) |
| `libs/sw_math/src/aabb.zig`, `ray.zig`, `plane.zig` | `Aabb` (closed box: union, intersect, contains, expand, expandTowards), `Ray` (against an `Aabb` or a `Plane`), `Plane` (signed distance, `classifyAabb` for culling) |
| `libs/sw_gfx2d/src/batch.zig` | 2D shapes to vertices, indices and draw calls (no GPU code, unit tested) |
| `libs/sw_gfx2d/src/projection.zig` | Pixel projection, origin top left, and `dpi_scale` maths |
| `libs/sw_gfx2d/src/renderer.zig` | `Renderer`: pipeline, buffers, textures, `updateTexture`, `flush` into a render pass |
| `libs/sw_text/src/text.zig` | `TextRenderer`: glyph atlas pages filled on first use, `draw`, `drawWrapped`, `measure` |
| `libs/sw_text/src/font.zig` | TTF reader over stb_truetype (`stb_impl.c`). stb allocates through function pointers that this file sets, so it builds for WASM |
| `libs/sw_text/src/layout.zig` | Measuring and wrapping for any metrics type (no font, no GPU, unit tested) |
| `libs/sw_text/src/utf8.zig`, `atlas.zig` | UTF-8 decoder (bad bytes give U+FFFD) and the shelf packer for the atlas |
| `libs/sw_ui/src/ui.zig` | `Ui`: immediate-mode tree (row, column, text, button, list, list item, text field, image), small layout (fixed, fit, fill, padding, gap, alignment), keyboard focus, events, and the semantic tree. No GPU or font code, unit tested |
| `libs/sw_ui/src/semantic.zig` | `SemanticTree`: plain data (role, name, value, focused, disabled, selected, live, changed, bounds, children) for a backend such as the web screen-reader mirror |
| `libs/sw_ui/src/web_mirror.zig` | Encodes the semantic tree for the web screen-reader mirror (`backends/wasm/a11y.ts`), and sends it only when it changes |
| `libs/sw_app/src/web_entry.zig` | `exportWeb`: the `swindowzig_init` and `swindowzig_frame` exports for an app that uses `sw.run`. `webLogFn` for `std.log` on wasm |
| `libs/sw_ui/src/draw.zig` | Draws the tree with sw_gfx2d and sw_text, with a focus ring. `measurer(&text_renderer)` gives the UI its text size |
| `libs/sw_voxel/src/sw_voxel.zig` | Voxel chunks: storage, light, greedy mesher, World, frustum, chunk pipeline. The game gives the module `sw_voxel_content` (`content.zig` has the contract). `.claude/rules/voxel.md` has the file map |
| `libs/sw_assets/src/assets.zig` | `loadBytes(allocator, path_or_url)` returns a `Request`. `request.poll()` gives `.pending`, `.bytes` or `.failed`, and never waits. Native: a thread reads a file in the base directory (`useDirectory`/`useDirectoryPath`), and an `http(s)://` URL fails with `UnsupportedUrl`. Web: `fetch` through `backends/wasm/assets.ts` |
| `libs/sw_assets/src/png.zig` | `decodePng(allocator, bytes)` gives RGBA8 `Image`. It calls stb_image (`libs/sw_assets/c/`, licence in `THIRD_PARTY_NOTICES.md`) |
| `libs/sw_gfx2d` `Renderer.createTextureFromPng` | Decode PNG bytes and upload them as a texture |
| `libs/sw_audio/src/audio.zig` | `Audio`: the waveform API (REQ-AUDIO-001), and `playSample`, `playStream`, voice and group volumes, `setListener`. `decode` reads WAV or Ogg Vorbis. One output for each program |
| `libs/sw_audio/src/mixer.zig` | `Mixer`: 64 voices, 8 volume groups, pan and distance loss from the listener, a limiter. No platform code, unit tested |
| `libs/sw_audio/src/vorbis.zig`, `wav.zig` | Ogg Vorbis (stb_vorbis in `c/`, one memory buffer, no libc) and WAV decoding. `Stream` decodes a 4096-frame window at a time (REQ-AUDIO-002) |
| `libs/sw_audio/src/native_sdl.zig`, `web.zig` | Backends. Native: the SDL audio thread calls `Mixer.mix`. The main thread changes the mixer between `SDL_LockAudioDevice` and unlock. Web: `backends/wasm/audio.ts` calls the `sw_audio_mix` export from a timer, and plays each block on the audio clock |
| `libs/sw_render/src/layout.zig` | Atlas packing on a grid of power-of-two cells (the `sw_text` shelf packer), UV rectangles, and `compose` (no GPU code, unit tested) |
| `libs/sw_render/src/animation.zig` | Frame timing of animated sprites: `imageAt`, `Player.advance` (no GPU code, unit tested) |
| `libs/sw_render/src/atlas.zig` | `AtlasBuilder` and `Atlas`: textures, mip levels with `MipmapGenerator`, and `update`, which copies changed frames with `copyTextureToTexture` (REQ-GPU-003, REQ-GPU-004) |
