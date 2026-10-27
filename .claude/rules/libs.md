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

### TextureFormat enum mismatch (fixed in gpu.zig — toNativeTextureFormat)
`types.TextureFormat` keeps the numbers that the web bridge uses
(`TEXTURE_FORMAT_MAP` in `backends/wasm/webgpu.ts`). From `rgb10a2unorm` on,
they are not the `webgpu.h` numbers: `.rgba16float` is 0x1F, and 0x1F in
`webgpu.h` is `RG32Sint`. Every native call uses `toNativeTextureFormat()`
(the table is `types.nativeTextureFormat`). Do not use raw `@intFromEnum`
for a texture format.

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

### Gamepads

- Events `gamepad_connection`, `gamepad_button`, `gamepad_axis` (tags 12 to
  14). `input().gamepad(slot)` (4 slots) has the buttons and the raw axes.
  `stick(.left, settings)` and `trigger` apply the dead zones
  (`GamepadSettings`). `Binding.gamepadButton(.south)` and
  `Binding.gamepadAxis(.left_x, positive)` bind them to actions. The
  `ActionMap.gamepad` field has the dead zones (REQ-INPUT-005).
- A recording is version 2. The reader also reads version 1 (REQ-INPUT-006).
  A new event type increases `serialize.VERSION`.
- Native: SDL game controllers in `native_sdl.zig`. Web:
  `backends/wasm/gamepad.ts` reads the Gamepad API once per frame, before
  `swindowzig_frame`, and calls the exports of `web_gamepad.zig`.
- TAS: `gamepad_down south`, `gamepad_up south`, `gamepad_axis left_x -0.5`,
  each with an optional slot at the end.

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
- Web: the bridge (`backends/wasm/webgpu.ts`) drops the handle of a view,
  an encoder, a pass and a command buffer where native releases the object.
  So a frame adds no handle (REQ-GPU-012). The canvas is always
  `bgra8unorm`, the screen format of the Zig side (REQ-GPU-013). `yarn test:browser` runs the
  Playwright tests: `canvas.pw.ts` checks the pixels of justabox on the
  canvas, and `a11y.pw.ts` checks flat2d. `yarn test:a11y` runs the same.
- Web: `gpu.writeBufferHeld` writes bytes that JS holds
  (`backends/wasm/held-bytes.ts`, by handle) to a GPU buffer. The bytes do
  not go through the wasm memory. The WebGPU bridge owns the store, and the
  "chunks" imports fill it. A native build has no held bytes.

### Network (sw_net)

- `Socket.open(allocator, ctx.io, url, options)`, then `poll()` in a loop
  each tick until it gives null. Events: `open`, `message` (the bytes stay
  valid until the next `poll`), `closed` (code, cause, retry delay). No
  callback calls game code (REQ-NET-001).
- Send only in the `open` state. `close` accepts code 1000 or 3000 to 4999,
  because the browser accepts only these codes from a page.
- `Options.reconnect` (a `Backoff`) connects again after a drop. The delay
  doubles to `max_ms`, and an open connection sets the count to zero
  (REQ-NET-003).
- Native: one network thread for each connection does all the reads and
  writes, so the TLS state has one owner. The thread waits for data with a
  2 ms timeout, then writes the queued frames. `wss:` uses `std.crypto.tls`
  with the system CA bundle. Each client frame has a random mask
  (REQ-NET-002).
- Web: `backends/wasm/websocket.ts` (import module "sw_net"). The old module
  "net" (`net.ts`) stays for apps that use it. A URL that starts with "/"
  goes to the host of the page. The browser does not tell a refused upgrade
  from a failed connect, so both give `connect_failed`.

### Window, cursor and clipboard

- `ctx.setWindowMode(.fullscreen | .windowed)`, `ctx.windowMode()`. Native:
  a borderless window at the desktop resolution. Web: browser full screen
  (needs a user gesture). The new size arrives as `resize`.
- `ctx.setCursorMode(.normal | .hidden | .locked)`, `ctx.isCursorLocked()`.
  `setMouseCapture` does not change. A refused web pointer lock does not
  stop the game (REQ-PLATFORM-001).
- Clipboard: `ctx.setClipboardText`, `ctx.requestClipboardText`,
  `ctx.clipboardText()`. Each result is a `clipboard` event (tag 11,
  `input().clipboard`), on native too (REQ-PLATFORM-002). A web paste
  (Ctrl+V while text input is on) is a `paste` event.
  `ctx.setPasteAsText(false)` stops the paste from also typing.
- DPI: the web loader and SDL send `resize` when the device pixel ratio
  changes (REQ-PLATFORM-003). `Config.surface_follows_window = true` makes
  the native surface follow the pixel size (default off: the voxel targets
  have a fixed size). The dev page uses `canvasSize: 'device'`.
- Web: `backends/wasm/window.ts` and `clipboard.ts`. Native:
  `native_sdl.zig`. Zig web side: `libs/sw_platform/src/web_window.zig`.

### UI tree (sw_ui)

- Each frame: `u.begin(input, w, h)`, build nodes with non-zero `u32` IDs,
  `u.finish()`, then read `u.frameEvents()` (`activate`, `cancel`, `changed`,
  `submit`). Draw with `sw_ui.draw.draw`. Read `u.semanticTree()` for assistive
  technology.
- Focus: Tab and Shift+Tab in tree order. A list is one tab stop, and Up and
  Down move inside it. A container with `Opts.arrows` is one tab stop, and
  the arrow keys move by position in it (the on-screen keyboard). Enter and
  Space activate. Escape sends `cancel`.
- Text field: when `u.wantsTextInput()` changes, call `ctx.startTextInput()` or
  `ctx.stopTextInput()`. The app owns the text (`sw_ui.TextValue`), with its
  caret and selection. The app maps Ctrl or Cmd with A, C, X, V to
  `Keys.select_all`, `copy`, `cut`, `paste`. `Ui.clipboard` is null by
  default: then the fields of one `Ui` share a clipboard inside it.
  `u.clipboard = sw_ui.Clipboard.platform(ctx)` uses the system clipboard
  (flat2d does).
- Widgets: `addSlider`, `beginScrollList` (wheel in `Input.wheel_y` lines,
  drag with `Input.pointer_down`), `Opts.tooltip`, `beginScreen` (a modal
  layer over its parent) with `ScreenStack` (it keeps the focus of each
  screen), and `osk.Keyboard`. `flat2d` shows each one.
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
| `libs/sw_core/src/action.zig` | `ActionMap(Action)`: game actions with default bindings (keys, mouse buttons, gamepad buttons and axes, modifiers), rebinding, `BindingCapture` for a rebind menu, `MouseSettings` (sensitivity, invert). `update(ctx.input())` once per tick (REQ-INPUT-003). A new input kind is a new `Source` member |
| `libs/sw_core/src/record.zig` | Record events to a TAS file |
| `libs/sw_platform/src/gamepad.zig` | Gamepad slots by platform ID, and the SDL axis scaling (no platform code, unit tested) |
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
| `libs/sw_platform/src/clipboard.zig` | `ClipboardState`: the clipboard text that a backend knows, and the results that wait for the next poll as `clipboard` events (REQ-PLATFORM-002). Unit tested |
| `libs/sw_platform/src/platform.zig` | `WindowInfo`, `WindowMode`, `CursorMode`, `dpiScale`, `windowInfoChanged` |
| `libs/sw_platform/src/input_settings.zig` | `save`/`load` an `ActionMap` (bindings and mouse settings) through storage. Text that it cannot read keeps the defaults (REQ-INPUT-004) |
| `libs/sw_math/src/mat4.zig` | 4×4 matrix: `perspective()`, `lookAt()`, multiply |
| `libs/sw_math/src/vec3.zig` | Vec3 ops. `vec2.zig` and `vec4.zig` have the same ops. `Mat4.mulVec4` multiplies a Vec4 |
| `libs/sw_math/src/quat.zig` | `Quat`: `fromAxisAngle`, `mul`, `rotate`, `slerp`, `toMat4` (same rotation direction as `Mat4.rotationX/Y/Z`) |
| `libs/sw_math/src/camera.zig` | `camera.Controller`: first-person and third-person modes, look smoothing, a field-of-view boost. Pure: `update(input, dt, ray_test)` gives the view and projection matrices. The game gives a `RayTest` that stops the third-person eye at walls (REQ-CAMERA-001, REQ-CAMERA-002) |
| `libs/sw_math/src/aabb.zig`, `ray.zig`, `plane.zig` | `Aabb` (closed box: union, intersect, contains, expand, expandTowards), `Ray` (against an `Aabb` or a `Plane`), `Plane` (signed distance, `classifyAabb` for culling) |
| `libs/sw_gfx2d/src/batch.zig` | 2D shapes to vertices, indices and draw calls. `clip` cuts each shape and its uv to a rectangle (`Renderer.setClip`). No GPU code, unit tested |
| `libs/sw_gfx2d/src/projection.zig` | Pixel projection, origin top left, and `dpi_scale` maths |
| `libs/sw_gfx2d/src/renderer.zig` | `Renderer`: pipeline, buffers, textures, `updateTexture`, `flush` into a render pass |
| `libs/sw_text/src/text.zig` | `TextRenderer`: glyph atlas pages filled on first use, `draw`, `drawWrapped`, `measure`. A font chain (`addFont`, `addBitmapFont`, `initBitmap`). Each line goes through `bidi` before it is drawn |
| `libs/sw_text/src/font.zig` | TTF reader over stb_truetype (`stb_impl.c`). stb allocates through function pointers that this file sets, so it builds for WASM |
| `libs/sw_text/src/bitmap_font.zig`, `face.zig` | `BitmapFont`: a glyph sheet in equal cells and a width table. `Face` is a TTF or a bitmap font. `ChainMetrics` finds the first face that has a code point |
| `libs/sw_text/src/bidi.zig` | The Unicode bidirectional algorithm (UAX #9): levels, line reordering, mirroring. It passes all of `BidiTest.txt` and `BidiCharacterTest.txt`. Data in `bidi_tables.zig`, made by `libs/sw_text/tools/gen_bidi_tables.py`. `Paragraphs` shapes Arabic before it reorders |
| `libs/sw_text/src/shape.zig` | Arabic contextual shaping: joined presentation forms, the lam-alef ligature, transparent marks (REQ-TEXT-001 to REQ-TEXT-007). `ligature_part` takes the place of the alef of a ligature. Data in `shaping_tables.zig`, made by `libs/sw_text/tools/gen_shaping_tables.py` |
| `libs/sw_text/src/layout.zig` | Measuring and wrapping for any metrics type (no font, no GPU, unit tested) |
| `libs/sw_text/src/caret.zig` | `CaretLayout`: the caret x at a byte offset, the offset at an x, and the box of each code point of one line after bidi reordering. `TextRenderer.caretLayout` makes one (no GPU, unit tested) |
| `libs/sw_text/src/utf8.zig`, `atlas.zig` | UTF-8 decoder (bad bytes give U+FFFD) and the shelf packer for the atlas |
| `libs/sw_ui/src/ui.zig` | `Ui`: immediate-mode tree (row, column, text, button, list, scroll list, list item, text field, slider, image, screen, tooltips), small layout (fixed, fit, fill, padding, gap, alignment), keyboard focus, pointer drags, events, and the semantic tree. `TextValue` has the caret and selection. No GPU or font code, unit tested |
| `libs/sw_ui/src/screen.zig`, `osk.zig` | `ScreenStack`: a stack of screens that gives the focus back on `pop`. `osk.Keyboard`: an on-screen keyboard of buttons that fills a `TextValue`. Unit tested |
| `libs/sw_ui/src/semantic.zig` | `SemanticTree`: plain data (role, name, value, focused, disabled, selected, live, changed, bounds, children) for a backend such as the web screen-reader mirror |
| `libs/sw_ui/src/web_mirror.zig` | Encodes the semantic tree for the web screen-reader mirror (`backends/wasm/a11y.ts`), and sends it only when it changes |
| `libs/sw_app/src/web_entry.zig` | `exportWeb`: the `swindowzig_init` and `swindowzig_frame` exports for an app that uses `sw.run`. `webLogFn` for `std.log` on wasm |
| `libs/sw_ui/src/draw.zig` | Draws the tree with sw_gfx2d and sw_text, with a focus ring and the tooltip. A scroll list cuts its children (`Renderer.setClip`). `measurer(&text_renderer)` gives the UI its text size and bidi caret positions |
| `libs/sw_voxel/src/sw_voxel.zig` | Voxel chunks: storage, light, greedy mesher and model mesher, World, frustum, chunk pipeline. The game gives the module `sw_voxel_content` (`content.zig` has the contract). `.claude/rules/voxel.md` has the file map |
| `libs/sw_assets/src/assets.zig` | `loadBytes(allocator, path_or_url)` returns a `Request`. `request.poll()` gives `.pending`, `.bytes` or `.failed`, and never waits. Native: a thread reads a file in the base directory (`useDirectory`/`useDirectoryPath`), and an `http(s)://` URL fails with `UnsupportedUrl`. Web: `fetch` through `backends/wasm/assets.ts` |
| `libs/sw_assets/src/zip.zig` | `zip.Archive.open(allocator, bytes, .{})` reads the central directory only (REQ-ASSETS-001). `read`/`readName`/`readInto` decompress one stored or deflate entry (`std.compress.flate`). Zip64, data descriptors, bytes before the archive. Fixtures in `libs/sw_assets/testdata` |
| `libs/sw_assets/src/files.zig` | `files.poll(allocator)` gives the next file from the player (`.none`, `.loading`, `.file`, `.failed`). Web: a drop on the page, `files.showPicker(accept)`, or `offerFiles` in `backends/wasm/files.ts`. Native: `files.offerPath(io, path)` |
| `libs/sw_assets/src/cache.zig` | `cache.read`/`write`/`delete` by name, polled like `loadBytes`. Web: OPFS through `backends/wasm/files.ts` (secure context only, else `error.InsecureContext`, REQ-ASSETS-002). Native: a folder from `cache.useDirectory`/`useDirectoryPath` |
| `libs/sw_assets/src/web_blob.zig`, `wasm_check.zig` | The "files" wasm imports, and the chunked copy of a JS blob into wasm memory. `wasm_check.zig` is the wasm program that `files.test.ts` runs |
| `libs/sw_assets/src/png.zig` | `decodePng(allocator, bytes)` gives RGBA8 `Image`. It calls stb_image (`libs/sw_assets/c/`, licence in `THIRD_PARTY_NOTICES.md`) |
| `libs/sw_gfx2d` `Renderer.createTextureFromPng` | Decode PNG bytes and upload them as a texture |
| `libs/sw_audio/src/audio.zig` | `Audio`: the waveform API (REQ-AUDIO-001), and `playSample`, `playStream`, voice and group volumes, `setListener`. `decode` reads WAV or Ogg Vorbis. One output for each program |
| `libs/sw_audio/src/mixer.zig` | `Mixer`: 64 voices, 8 volume groups, pan and distance loss from the listener, a limiter. No platform code, unit tested |
| `libs/sw_audio/src/vorbis.zig`, `wav.zig` | Ogg Vorbis (stb_vorbis in `c/`, one memory buffer, no libc) and WAV decoding. `Stream` decodes a 4096-frame window at a time (REQ-AUDIO-002) |
| `libs/sw_audio/src/native_sdl.zig`, `web.zig` | Backends. Native: the SDL audio thread calls `Mixer.mix`. The main thread changes the mixer between `SDL_LockAudioDevice` and unlock. Web: `backends/wasm/audio.ts` calls the `sw_audio_mix` export from a timer, and plays each block on the audio clock |
| `libs/sw_render/src/layout.zig` | Atlas packing on a grid of power-of-two cells (the `sw_text` shelf packer), UV rectangles, and `compose` (no GPU code, unit tested) |
| `libs/sw_render/src/animation.zig` | Frame timing of animated sprites: `imageAt`, `Player.advance` (no GPU code, unit tested) |
| `libs/sw_render/src/atlas.zig` | `AtlasBuilder` and `Atlas`: textures, mip levels with `MipmapGenerator`, and `update`, which copies changed frames with `copyTextureToTexture` (REQ-GPU-003, REQ-GPU-004) |
| `libs/sw_render/src/frame_graph.zig` | `FrameGraph`: named render targets that follow the window, passes by `order`, frame uniforms at group 0. `execute` submits, then the game calls `gpu.present()` (REQ-GPU-005) |
| `libs/sw_render/src/plan.zig` | Frame graph rules: target sizes, pass order, attachment checks (no GPU code, unit tested) |
| `libs/sw_render/src/ring.zig`, `upload.zig` | `UniformRing` (per-draw uniforms at dynamic offsets, one write per frame) and `Uploads` (staged buffer writes, merged). No new buffer each frame (REQ-GPU-006) |
| `libs/sw_render/src/wgsl.zig` | The shared WGSL prefix (`sw_frame` at group 0), `FrameUniforms` and `SkyUniforms` (`FrameUniforms.sky`), and the sky and fog helpers (`sw_view_ray`, `sw_sky_color`, `sw_fog`) (REQ-GPU-007) |
| `libs/sw_render/src/post.zig` | `PostChain`: the `rgba16float` scene target (`hdr`), then HDR effects, the tonemap, LDR effects and FXAA as frame graph passes. The last enabled link writes the screen (REQ-GPU-008, REQ-GPU-009) |
| `libs/sw_render/src/post_plan.zig` | Post chain rules: the route of the links, the tonemap curves (CPU reference), the effect WGSL (`post.shader`). No GPU code, unit tested |
| `libs/sw_render/src/sky.zig` | `Sky`: the sky pass (gradient, sun, moon, stars, or a `CubeMap`) before the scene on one target. `setTime` (0 midnight, 0.5 noon), then `frame.sky = try sky.update()` each frame. Scene passes on the target use `load_op = .load` (REQ-GPU-010) |
| `libs/sw_render/src/sky_plan.zig` | The time of day, the sky colours (`Palette`), `Fog`, and the CPU reference of the sky shader and of the WGSL helpers `sw_sky_color` and `sw_fog` (no GPU code, unit tested) (REQ-GPU-010, REQ-GPU-011) |
| `libs/sw_render/src/box_models.zig` | `BoxModels`: trees of boxes, one draw call for all instances of one model. Each frame: `clear`, `add(layer, model, .{ .transform, .rotations, .tint })`, then `draw(pass, .world, .{})`. `addFirstPersonPass` draws the `.first_person` layer (view space) with its own depth range (REQ-GPU-014, REQ-GPU-015) |
| `libs/sw_render/src/box_model_plan.zig` | Box models with no GPU code: `validate`, `buildMesh`, `pose` (`parent * T(pivot) * R * T(-pivot)`), the record layouts, the WGSL and the CPU `shade` (unit tested) |
| `libs/sw_gpu/src/fxaa.zig` | The FXAA source and quality presets. `shaderSource` sets the tokens and the bind group. `configureFXAA` and the post chain use it |
| `libs/sw_net/src/socket.zig` | `Socket`: open, `poll`, send, close, and the reconnect. The same code for web and native. `net_root.zig` is the module root |
| `libs/sw_net/src/native.zig` | The native transport: connect, TLS for `wss:`, the HTTP upgrade, the frame loop on one network thread |
| `libs/sw_net/src/web.zig`, `backends/wasm/websocket.ts` | The web transport: the "sw_net" imports and the browser WebSocket. `websocket.test.ts` runs `wasm_check.zig` against a Bun server |
| `libs/sw_net/src/frame.zig`, `handshake.zig`, `url.zig`, `backoff.zig` | Frames and fragments, the upgrade request and its check, `ws:`/`wss:` URLs, the reconnect delay (no sockets, unit tested). `socket_test.zig` runs the native client against a local server |
