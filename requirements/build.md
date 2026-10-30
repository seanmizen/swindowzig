# Build requirements — `REQ-BUILD-*`

The Zig build of swindowzig (`build.zig`): the steps and functions that a
dependent package uses, and the targets that the build supports.

## REQ-BUILD-001 — A dependent package builds an example to wasm with no nested build

- **Status:** active
- **Source:** agent:SWZ-21
- **Origin:** #21
- **Type:** functional
- **Priority:** P2
- **Statement:** The `build.zig` of swindowzig shall give a public function
  `addWebExample` that makes the wasm artifacts of one example (`app.wasm`,
  and `chunks.wasm` for the voxel example) in the build graph of a dependent
  package, from the sources of the dependency.
- **Rationale:** A dependent package gets only the modules of a dependency.
  Before this function, it had to start a second `zig build` on the
  `build.zig` of swindowzig. That build had its own cache, and it could not
  see the files of a `--fork` checkout, so it ran on each build. In one build
  graph, the Zig cache sees each source file, and `--fork` replaces the
  sources.
- **Verification:**
  - Demonstration — `.github/workflows/swindowzig-release.yml` builds a
    consumer project against the release archive. The consumer calls
    `addWebExample` and installs `app.wasm`.
  - Inspection — `build.zig` › `addWebExample` uses the same `webExample`
    function as the `web` step.
- **Relations:** none

## REQ-BUILD-002 — The native examples cross-compile to Windows

- **Status:** active
- **Source:** agent:SWZ-9
- **Origin:** #9
- **Type:** functional
- **Priority:** P3
- **Statement:** When the target is `x86_64-windows-gnu`, `zig build native`
  shall link the Windows releases of SDL2 and wgpu-native from the
  `windows-deps` folder and install `SDL2.dll` and `wgpu_native.dll` next to
  the executable.
- **Rationale:** WSL2 has no Vulkan driver for the GPU, so a Linux build in
  WSL draws on the CPU (lavapipe). A Windows executable uses D3D12 or Vulkan
  on the GPU. Zig cross-compiles it from Linux, so no Windows toolchain is
  necessary.
- **Verification:**
  - Demonstration — `scripts/voxel-windows.sh` (`yarn voxel:windows`)
    builds `zig-out/bin/voxel.exe` with the two DLLs.
- **Relations:** none

## REQ-BUILD-003 — On Windows, the native surface is the Win32 window

- **Status:** active
- **Source:** agent:SWZ-9
- **Origin:** #9
- **Type:** functional
- **Priority:** P3
- **Statement:** When `sw_gpu` runs on Windows, it shall make its wgpu
  surface from the HWND and the HINSTANCE of the SDL2 window.
- **Rationale:** wgpu-native picks D3D12 or Vulkan for a Win32 surface.
  Before this, the Windows path stopped with `NotImplementedYet`.
- **Verification:**
  - Demonstration — on Windows, `voxel.exe` logs
    `sw_gpu: adapter "<GPU name>" backend=d3d12` (or `vulkan`) and draws
    the world.
- **Relations:** none

## REQ-BUILD-004 — The Windows build opens no console window

- **Status:** active
- **Source:** sean
- **Origin:** #9
- **Type:** functional
- **Priority:** P3
- **Statement:** When the target is Windows, the native build shall make a
  GUI program, unless the build has the option `-Dwindows-console=true`.
- **Rationale:** A game opens its window only. A redirect of stdout and
  stderr still gets the log, and the option gives the console back for
  debug.
- **Verification:** Inspection — `voxel.exe` starts with no console window,
  and `voxel.exe > log.txt 2>&1` writes the log.
- **Relations:** refines REQ-BUILD-002
