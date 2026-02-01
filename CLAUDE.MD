# swindowzig - Technical Guide for Claude

> **For users:** See [README.md](README.md)
> **This file:** Build instructions, troubleshooting, testing strategy for AI assistants

---

## Quick Start

### Prerequisites
- **Zig 0.15.2+** (standard release)
- **SDL2** (for native builds)
- **Node.js 20+** & **Yarn 4** (for web builds)

### Install Dependencies

**macOS:**
```bash
brew install sdl2
```

**Linux:**
```bash
sudo apt install libsdl2-dev
```

**From monorepo root:**
```bash
corepack enable
yarn
```

---

## Build Commands

### Native (Desktop)
```bash
zig build native  # Compile only
zig build run     # Compile and run
```

**Current state:** ✅ Working! Triangle renders at ~600 FPS with debug overlay.

### Web (WASM)
```bash
zig build web                            # Build WASM binary
bun build backends/wasm/boot.ts --outdir=dist  # Bundle JS
bun backends/wasm/dev-server.ts          # Run dev server
```

**Current state:** ✅ Working with full WebGPU support.

---

## Native WebGPU Fixes (Feb 2026)

### Critical Issues Fixed

#### 1. Struct Layout Mismatches

**Problem:** Zig struct definitions didn't match C WebGPU API headers exactly, causing memory corruption and segfaults.

**Fixes:**
- **Added missing `depth_slice` field** to `WGPURenderPassColorAttachment`
  - Location: `libs/sw_gpu/src/native_webgpu.zig:764`
  - Between `view` and `resolve_target` fields
  - Type: `u32` with default `0xFFFFFFFF` (WGPU_DEPTH_SLICE_UNDEFINED)

- **Fixed `bool` → `u32` for WebGPU booleans**
  - Location: `libs/sw_gpu/src/native_webgpu.zig:270`
  - `mapped_at_creation: u32` (was `bool`)
  - WebGPU uses `WGPUBool` which is `uint32_t` (4 bytes), not 1-byte `bool`

**Lesson:** Always verify `extern struct` definitions match C headers EXACTLY, including:
- Field order
- Field types
- Field alignment
- All fields (even optional ones)

#### 2. Incomplete Descriptor Initialization

**Problem:** Not all fields in `extern struct` descriptors were being initialized, leaving undefined memory.

**Fixes:**
- Initialized ALL fields in `WGPURenderPassDescriptor`:
  - `next_in_chain = null`
  - `occlusion_query_set = null`
  - `timestamp_write_count = 0`
  - `timestamp_writes = null`

- Zero-initialized arrays before populating:
  ```zig
  var color_attachments: [8]native.WGPURenderPassColorAttachment =
      std.mem.zeroes([8]native.WGPURenderPassColorAttachment);
  ```

**Lesson:** For `extern struct`, ALL fields must be explicitly initialized, even optional ones with defaults.

#### 3. Resource Lifecycle Management

**Problem:** WebGPU resources weren't being released, causing "CommandBuffer still in use" errors.

**Fixes added:**
- `wgpuRenderPassEncoderRelease()` - called after `end()`
- `wgpuCommandEncoderRelease()` - called after `finish()`
- `wgpuCommandBufferRelease()` - called after `submit()` + `poll()`
- `wgpuTextureViewRelease()` - called after rendering
- `wgpuDevicePoll()` - ensures GPU work completes before releasing

**Implementation pattern:**
```zig
// After ending render pass
pass.end();  // Calls wgpuRenderPassEncoderEnd() + wgpuRenderPassEncoderRelease()

// After finishing encoder
const cmd = try encoder.finish();  // Calls wgpuCommandEncoderFinish() + wgpuCommandEncoderRelease()

// After submitting
gpu.submit(&[_]CommandBuffer{cmd});
// Inside submit: wgpuQueueSubmit() → wgpuDevicePoll() → wgpuCommandBufferRelease()

// After rendering
view.release();  // Calls wgpuTextureViewRelease()
```

**Lesson:** wgpu-native uses reference counting. Every create/acquire needs a corresponding release.

---

## Testing Strategy

### Isolatable Issues

The problems we encountered ARE testable:

#### 1. Struct Layout Tests
```zig
test "WGPURenderPassColorAttachment matches C layout" {
    const zig_size = @sizeOf(WGPURenderPassColorAttachment);
    const zig_align = @alignOf(WGPURenderPassColorAttachment);

    // Expected from C header inspection
    const expected_size = 48; // platform-dependent
    const expected_align = 8;

    try std.testing.expectEqual(expected_size, zig_size);
    try std.testing.expectEqual(expected_align, zig_align);
}

test "bool vs WGPUBool size mismatch" {
    try std.testing.expect(@sizeOf(bool) != @sizeOf(u32));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(u32)); // WGPUBool
}

test "check struct field offsets" {
    const offset_view = @offsetOf(WGPURenderPassColorAttachment, "view");
    const offset_depth_slice = @offsetOf(WGPURenderPassColorAttachment, "depth_slice");
    const offset_resolve = @offsetOf(WGPURenderPassColorAttachment, "resolve_target");

    // Verify field order
    try std.testing.expect(offset_view < offset_depth_slice);
    try std.testing.expect(offset_depth_slice < offset_resolve);
}
```

#### 2. Resource Lifecycle Tests
```zig
test "command buffer is released after submit" {
    var gpu = try initTestGPU();
    defer gpu.deinit();

    const encoder = try gpu.createCommandEncoder();
    const command = try encoder.finish();

    gpu.submit(&[_]CommandBuffer{command});

    // After submit+poll, command buffer should be released
    // (would need mock tracking to verify)
}

test "texture view is released" {
    var gpu = try initTestGPU();
    defer gpu.deinit();

    var view = try gpu.getCurrentTextureView();
    view.release();

    // Verify release was called (needs mock)
}
```

#### 3. Descriptor Field Coverage Tests
```zig
test "all WGPURenderPassDescriptor fields initialized" {
    const desc = WGPURenderPassDescriptor{
        .next_in_chain = null,
        .label = null,
        .color_attachment_count = 0,
        .color_attachments = undefined,
        .depth_stencil_attachment = null,
        .occlusion_query_set = null,
        .timestamp_write_count = 0,
        .timestamp_writes = null,
    };

    // If we forgot a field, this won't compile
    _ = desc;
}
```

### Integration Tests Needed

Create `tests/native_gpu_smoke.zig`:
```zig
// Test basic GPU initialization
test "create and destroy GPU instance" {
    var gpu = try GPU.init(...);
    defer gpu.deinit();
}

// Test buffer creation and write
test "create buffer, write data, read back" {
    var gpu = try GPU.init(...);
    defer gpu.deinit();

    const buffer = try gpu.createBuffer(.{
        .size = 1024,
        .usage = .{ .copy_dst = true, .copy_src = true },
    });

    gpu.writeBuffer(buffer, 0, data);
    // Read back and verify
}

// Test pipeline creation
test "create simple render pipeline" {
    var gpu = try GPU.init(...);
    defer gpu.deinit();

    const shader = try gpu.createShaderModule(.{
        .code = triangle_shader,
    });

    const pipeline = try gpu.createRenderPipeline(.{
        .vertex = .{ .module = &shader, ... },
        .fragment = .{ .module = &shader, ... },
    });

    // Verify pipeline created successfully
}

// Test full frame render
test "render triangle to offscreen texture" {
    var gpu = try GPU.init(...);
    defer gpu.deinit();

    // Create offscreen texture
    // Create render pipeline
    // Record commands
    // Submit
    // Read back pixels
    // Verify triangle was rendered
}
```

### Validation Tools

#### 1. Struct Padding Checker
```zig
// Add to build.zig tests
fn checkStructPadding(comptime T: type, expected_offsets: []const usize) !void {
    inline for (@typeInfo(T).Struct.fields, 0..) |field, i| {
        const offset = @offsetOf(T, field.name);
        if (offset != expected_offsets[i]) {
            std.debug.print("Field {s} at offset {}, expected {}\n",
                .{field.name, offset, expected_offsets[i]});
            return error.StructLayoutMismatch;
        }
    }
}

test "verify WebGPU struct layouts" {
    try checkStructPadding(WGPURenderPassColorAttachment, &[_]usize{
        0,  // next_in_chain
        8,  // view
        16, // depth_slice
        20, // resolve_target
        28, // load_op
        32, // store_op
        36, // clear_value
    });
}
```

#### 2. WebGPU Error Callback
```zig
// Enable validation layers in debug builds
const device_desc = WGPUDeviceDescriptor{
    .uncaptured_error_callback = errorCallback,
    .uncaptured_error_userdata = null,
};

fn errorCallback(type: WGPUErrorType, message: [*c]const u8, _: ?*anyopaque) void {
    std.debug.print("WebGPU Error: {s}\n", .{message});
}
```

---

## Common Issues & Solutions

### Segfault in `wgpuCommandEncoderBeginRenderPass`

**Symptom:** Crash at address like `0x100000009` (undefined memory pattern)

**Root cause:** Struct field mismatch or uninitialized field

**Solution:**
1. Compare struct definition against `~/.local/include/webgpu/webgpu.h`
2. Check field order matches exactly
3. Verify all fields are initialized
4. Check for missing fields (like `depth_slice`)

### "Buffer still mapped" error

**Symptom:** Validation error on `wgpuQueueSubmit`

**Root cause:** Wrong type for `mapped_at_creation` (using `bool` instead of `u32`)

**Solution:**
```zig
// Before (wrong):
.mapped_at_creation = false,  // bool (1 byte)

// After (correct):
.mapped_at_creation = 0,  // u32 (4 bytes)
```

### "CommandBuffer cannot be destroyed because still in use"

**Symptom:** Panic on command buffer destruction

**Root cause:** Missing resource release calls or missing device poll

**Solution:**
1. Call `wgpuDevicePoll()` after submit
2. Release all resources properly (see lifecycle management above)

---

## Development Workflow

### Adding New WebGPU Features

1. **Check the spec:** https://www.w3.org/TR/webgpu/
2. **Check wgpu-native headers:** `~/.local/include/webgpu/webgpu.h`
3. **Add C function binding** to `native_webgpu.zig`
4. **Add wrapper** in `gpu.zig`
5. **Test on both web and native**
6. **Add release call** if resource is created

### Debugging Native Rendering

**Enable verbose logging:**
```zig
// Add to gpu.zig functions
std.log.debug("Creating buffer: size={}, usage={}", .{desc.size, desc.usage});
```

**Run with validation:**
```bash
WGPU_LOG_LEVEL=debug zig build run
```

**Check struct sizes:**
```zig
std.log.info("Size of WGPURenderPassDescriptor: {}", .{@sizeOf(native.WGPURenderPassDescriptor)});
std.log.info("Size of WGPURenderPassColorAttachment: {}", .{@sizeOf(native.WGPURenderPassColorAttachment)});
```

---

## Project Structure

```
swindowzig/
├── libs/
│   ├── sw_core/           ✅ Complete (no changes needed)
│   ├── sw_platform/       ✅ Complete (no changes needed)
│   ├── sw_app/            ✅ Complete (no changes needed)
│   └── sw_gpu/            ✅ Working (active development)
│       └── src/
│           ├── gpu.zig              # Main API wrapper
│           ├── native_webgpu.zig    # C bindings (CHECK STRUCTS HERE)
│           ├── types.zig            # Zig-friendly types
│           └── web_bridge.zig       # WASM bindings
│
├── examples/
│   ├── windows/           ✅ Working triangle demo
│   └── simple_demo/       🚧 Needs update
│
└── backends/
    └── wasm/              ✅ Web platform code
```

---

## Recommendations

### For Development

1. **Add CI Tests**
   - Struct layout validation
   - Basic GPU operations (if headless rendering available)
   - Memory leak detection (valgrind/asan)

2. **Documentation**
   - Add struct layout diagrams
   - Document resource lifecycle rules
   - Add examples of correct usage patterns

3. **Linting Rules**
   - Flag `extern struct` without explicit field initialization
   - Flag missing `release()` calls after create operations
   - Warn on `bool` in `extern struct` (should use `u32` for C FFI)

### For Testing

- Run with address sanitizer: `zig build -Drelease-safe`
- Test on multiple platforms (macOS, Linux, Windows)
- Use validation layers in debug builds
- Profile with Tracy or similar

---

## Current Capabilities

✅ Window management (SDL2)
✅ Event system with record/replay
✅ Fixed timestep game loop
✅ WebGPU rendering (native + web)
✅ Triangle rendering at ~600 FPS
✅ Input handling (keyboard, mouse)
✅ FPS tracking
✅ Resource lifecycle management
✅ Debug overlay (console output)

---

## Known Limitations

- No text rendering yet (high priority)
- No texture loading
- No 3D camera system
- No mesh loading
- No lighting
- Debug overlay is console-only (not in-window)

---

## Performance Targets

**Current:** ~600 FPS (single triangle)
**Target:** 60 FPS stable (complex scenes)
**GPU Backend:** Metal on macOS via wgpu-native

---

**For user-facing documentation, see [README.md](README.md)**
