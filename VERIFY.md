# Release batch: verification log

This file is the checklist for the batch that the cloud agent built on one branch for v0.3.0: the code parts of #112, #79 and the backlog (#5, #6, #7, #8, #9, #10, #11, #14, #17, #21, #22), with a triage of #13. The seanorepo part (#724, #926, #928, and the seanorepo side of #10) is on the same branch name in seanorepo, in its own draft PR. The log of the batch before this one is in the git history of this file.

## Summary

- Done: each ticket in the batch. Code only, with checks on a real machine still to do: #9 (Windows) and #14 (a screen reader). Already done before the batch: #6. Triage only: #13.
- CI: green on the draft PR (all jobs, with the new parallel jobs of #22 and the demo hash job).
- The 4 min target of #22 is not met: a run takes about 6 min (see #22).
- Setup: ziglang.org gave 403, so Zig 0.17.0 came from the `ziglang` wheel on PyPI. Lavapipe, ffmpeg, Docker, Playwright with Chromium 1243 (the repo pins 1248, so the browser runs here used a local config that is not committed) and xvfb worked. Docker Hub gave 429, so no Docker build ran. The container restarted one time and the disk filled one time. No work was lost.
- Version: `.version` is `0.3.0` in `build.zig.zon` and `package.json`. You tag `v0.3.0`.

## Mac verification (2026-10-30, Apple M1, Metal)

The Mac session ran each CI step on Metal, in a real Chromium, with a
gate script: 73 steps, all pass. The steps are the static checks, the unit
tests (also as 2 shards), the web build and each Bun test, `--check` for
mipmaps, atlas, justabox, sky and models, the voxel gate, each voxel TAS,
each voxel test script, the native and web builds of each demo,
`yarn test:browser`, and the flat2d tests 10 times with no retry.

Found and fixed:
- `chunk_border.sh` failed on `main` too. Its frames with `--debug=on`
  had a cyan tint on the whole view. The player hitbox and the spawn disc
  used one range of one GPU buffer, and each `writeBuffer` runs before the
  pass. So the hitbox draw used the disc vertices and was not visible.
  When the entity cull (REQ-VOXEL-026) hid the disc, the real cylinder
  drew around the camera. Now the hitbox draws only in the third-person
  views, and the disc has its own buffer range. With the depth test of the
  border lines removed, the script fails (1757 pixels), so it still finds
  the bug. CI runs it now.

Checked here:
- The window checks: the voxel demo in a real window with `--vsync=on`
  (the default) and `--vsync=off`, 5 s each, with no error.
- The three web demos in Chromium on Metal: each draws at 60 frames each
  second with no console error. The shooter web picture is correct: the
  arena, the snow, the bots, the gun and the HUD.
- Water and glass (`--place-block=water`, `--place-block=glass`): the
  ground shows through both, and the water is blue.
- The URL seed and the saved edits in Chromium: `?seed=12345` gives seed
  12345. 4 edits stay after a reload. `?seed=not-a-seed` gives one warning
  and seed 0.
- #13: the browser baseline (`examples/voxel/tests/browser_baseline.sh`,
  REQ-VOXEL-037). The chunk time on main during a sprint has a p99 of
  1.3 ms (the budget is 4 ms). 24 of 26 edits show after 2 frames. 2 edits
  on a chunk border show after 3 frames. The values are in
  `examples/voxel/docs/chunk-pipeline.md`.

Not checked here (they need a person):
- The F and T keys of `models`, and the H, J and O keys of `sky`.
  macOS stopped the keystrokes of the session for a permission prompt.
- The occlusion cull when you turn on the spot in a cave.
- VoiceOver (the menu demo and AccessKit, #14), a gamepad, the sound, and
  the feel of the shooter.
- #17: a look for the wall triangle in a voxel play test.
- #9 on Windows.

Decisions of Sean:
- `keyPressCount` stays.
- Water is on by default, and the hotbar has water (slot 6) and glass
  (slot 7). The goldens change.
- CI is shorter: the unit tests run in 2 shards (the scheduler and exec
  tests go to different shards), each example has its own job, the cull
  frames have a ReleaseSafe job, and the flat2d tests run 10 times only
  on a push to main.

## Decisions for you

Each entry has its open questions. The main ones:
- `keyPressCount` (new API) and no change to the wheel notch scale (#112 Engine).
- The streaming upload limit stays a count of 24 (#112).
- `--water=on` as the default, and water in the hotbar (changes the goldens) (#112 Water).
- #22: make cave_cull shorter, or run it only on push to main, to reach 4 min.
- TypeScript 7.0.2 here, and ^5.9 in seanorepo. `--retries=0` on the 10 flat2d runs (#112 CI).
- New World also resets the world in place (#11).
- Close #17, because a mesher test replaces the old script. Close #6. Close #13 or move its last checks to a new ticket.


## #112 Engine: wheel mode check, view dimension map, key press count, wheel notch

- Status: done
- Commit: see `git log --grep "check the wheel mode"`
- Not run here: browser (Playwright) tests. The web change has Bun tests only.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none. `backends/wasm/webgpu.test.ts` (new) runs through the import in `events.test.ts`.
- Requirements: REQ-INPUT-009, REQ-INPUT-010 (new). REQ-INPUT-007, REQ-INPUT-008, REQ-GPU-034 (rationale and tests added).
- Open questions:
  1. Key count: the batch added `InputSnapshot.keyPressCount(key) u8` (256 bytes in the snapshot, cleared each tick, stops at 255, no key repeat). `keyPressed` stays a bool. Confirm that you want this API.
  2. Wheel notch: no change. A browser notch depends on the browser and the OS scroll setting, and a trackpad has no notch. The rule stays "lines": pixels / 40, pages x 10, SDL 1 line per notch. A game that wants one step for each notch reads the sign, or adds lines and steps at each full line. The REQ-INPUT-008 rationale says this. Confirm, or ask for a factor for each backend (that changes the scale for apps/action).
- Risks:
  - `serialize.zig` `readWheel` looks at the wheel bytes before it reads them (a reader buffer of 12 bytes or more, as `takeStruct` needed). Callers can now get `error.InvalidWheelMode`. `replay.zig` handles only EndOfStream, so this error goes up to its caller.
  - `createBindGroupLayout` on the web sent the raw enum (1d = 0) before. Now both sides use the code (1d = 1), so `webgpu.ts` and `app.wasm` must come from the same build. A web layout with a wrong dimension: look first at `VIEW_DIMENSIONS` in `backends/wasm/webgpu.ts`.


## #112 CI items: each TAS script, cave_cull in CI, flat2d 10 times, tsc on backends/wasm

- Status: done
- Commit: see `git log --grep "run each TAS script"`
- Not run here: GitHub Actions. Each command of each new step ran here:
  - The 16 `examples/voxel/tests/*.tas` scripts with `--headless --world=flatland` exit 0 (1 to 7 s each). A bad script exits 1.
  - `cave_cull.sh --skip-build`: PASS, all frames "same" (3 min 40 s on a loaded machine).
  - `yarn test:browser --project flat2d --repeat-each=10` with `CI=1`: 70 passed, 0 flaky, 2.8 min. This used a local Playwright config that was not committed, because this sandbox has chromium-1243 and the repo pins 1248.
  - `yarn typecheck:web` (new root script, `tsc --noEmit -p backends/wasm`): clean.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none (they are in the commit). The golden upload steps now run only when `steps.goldens.outcome == 'failure'`.
- Requirements: none
- Open questions:
  - `yarn add -D typescript` installed TypeScript 7.0.2 (the native tsc). seanorepo uses ^5.9.3. Do you want 5.9 here too?
  - `@webgpu/types` (^0.1.74) is a new devDependency. lib.dom has no `GPUTextureUsage`, `GPUBufferUsage`, `GPUMapMode` or `getContext('webgpu')`.
  - `--retries=0` on the 10 flat2d runs makes each flake fail CI, and it adds 2 to 3 min to the browser job. Keep it?
  - `gamepad.test.ts`, `webgpu.test.ts` and `window.test.ts` in `backends/wasm` are not in a CI step. Add them?
- Risks: one type fix changes behaviour. `webgpu.ts` gave the raw storage texture format number to WebGPU. It now goes through `TEXTURE_FORMAT_MAP`. This is a bug fix for storage textures on the web. The other fixes change only types (`window.ts` FullscreenOptions, three `websocket.ts` returns).

## #22 run the swindowzig checks in parallel jobs, and cache apt and Chromium

- Status: done
- Commit: see `git log --grep SWZ-22`
- Not run here: GitHub Actions. All times are unmeasured: the 4 min target, and whether the caches save time. A ReleaseFast voxel binary gave no gain for the goldens (1m07 Debug, 1m09 ReleaseFast. Lavapipe sets the wall time), so the jobs stay on Debug. The 10 goldens pass with both.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none (in the commit). `swindowzig-release.yml` did not change. `examples/voxel/docs/headless-regressions.md` names the new jobs.
- Requirements: none
- Open questions: none
- Risks and what to check in the first run:
  1. The apt cache restores, and on the second run `vulkaninfo` still finds llvmpipe. `cache-apt-pkgs-action` does not run postinst scripts, so the jobs run `sudo ldconfig` first.
  2. Chromium starts on a cache miss and on a hit, with no `--with-deps`. If libraries are missing, add `yarn playwright install-deps chromium`.
  3. `zig build test` in the zig job: the unit tests link SDL2 (sw_audio), so this job installs `libsdl2-dev` too.
  4. The job times, mainly `headless` (TAS scripts, then cave_cull) and `browser` (10 flat2d runs). If `headless` is slow, move cave_cull to its own job.
  5. Each of the six jobs saves its own Zig cache key (`setup-zig-cache-v2-<job>-...`).
  6. The three lavapipe jobs share one apt cache key. Their saves race, and the loser gives a harmless "cache exists" warning.

| Step before | Job now |
|---|---|
| Checkout | each job |
| Install lavapipe and SDL2 (apt) | examples, headless, goldens (apt cache). Zig gets libsdl2-dev only |
| Install Zig | each job, each with its own Zig cache |
| Format | zig |
| Install wgpu-native | examples, headless, goldens |
| Unit tests | zig |
| Terrain hash, native and wasm | zig |
| Web build (voxel ReleaseFast) | web |
| Set up Bun | web, browser |
| Headless run of the voxel web build in Bun | web |
| Bun tests (worker pool, input, audio pump, player files, WebSocket) | web |
| Native build (voxel) | headless, goldens |
| Each voxel TAS script headless (new) | headless |
| Web and native build of flat2d | examples |
| mipmaps, atlas, justabox, sky, models `--check` | examples |
| Install the Node packages (new) | browser |
| Type check of backends/wasm (new) | browser |
| Browser tests (canvas once, flat2d 10 times) | browser (Chromium from a cache keyed on the Playwright version) |
| Compare with the goldens | goldens |
| Cave cull (new) | headless |
| New goldens, uploads, accept command (on a golden failure) | goldens |

CI result on PR #113, head 8e8dc47 (the second run, so some caches were warm): all jobs green. Job times: browser 2m36, goldens 2m58, web 3m00, zig 3m58, examples 4m13, headless 5m57. So the run takes about 6 min from start to end, and the 4 min target is not met yet. The headless job is the slowest: native build 57 s, TAS scripts 47 s, cave_cull 3 min 43 s. More jobs cannot reach 4 min, because two single steps are long: cave_cull (3 min 43 s. This step is new in #112) and the unit tests (3 min 12 s). To reach 4 min: make cave_cull shorter, or run it only on push to main. Decide which.


## #112 Water: fluid block, fluid stream in the mesh result, WGSL pass

- Status: done
- Commit: see `git log --grep "water block"`
- Not run here: none
- Expected changes:
  - quad hash: no change (`8c11e81d4ec42623`)
  - goldens: one new golden, `water_pool` (`examples/voxel/tests/water_pool.tas`, flatland, `--place-block=water`). The 10 old goldens do not change.
- CI changes needed: none. The new golden is a new row in `run_headless_regressions.sh`.
- Requirements: REQ-VOXEL-027, REQ-VOXEL-028
- Where water is: the new generator flag `--water=on` fills hilly columns below sea level (63) with water. It is off by default. The flag uses spare bit 0 of byte 1 of the GenConfig in the Hello, so the Hello length does not change. Water is not in the default hotbar, because the hotbar shows in each golden. Place it with `--place-block=water`.
- Open questions: water has opacity 0, so the light stage keeps its fast queue (real water would dim the light). The fluid shader has no animation, because the pass has no time uniform. Do you want water in the hotbar, and `--water=on` as the default (this changes the goldens)?
- Risks: chunk protocol version 7. The fluid quad count is in the old reserved u32 at body byte 40, and the fluid vertices (96 bytes per quad) follow the PackedQuads. A mesh with no fluid has the same payload bytes as v6. The held upload is now `quad_count * 16` bytes, not the whole payload. The player and the ray cast go through water. Look first at `uploadFluid` and the fluid loop in `voxelRender` (`examples/voxel/main.zig`), and at `checkMeshUploads` in `backends/wasm/headless-app.ts`.

## #112 Translucent blocks: translucent quad stream, back-to-front sort

- Status: done
- Commit: see `git log --grep "translucent blocks"`
- Not run here: none
- Expected changes:
  - quad hash: no change
  - goldens: one new golden, `glass_blocks` (`examples/voxel/tests/glass_blocks.tas`, `--place-block=glass`). The old goldens do not change.
- CI changes needed: none
- Requirements: REQ-VOXEL-029, REQ-VOXEL-030, REQ-VOXEL-031, REQ-GPU-040
- Open questions: the demo does not use `sw_render.Translucent`, because that type needs a frame graph and the demo has its own scene pass. sw_render has the new `TranslucentPipeline`, `TranslucentBatch` (one for each chunk) and `FrameBinding`. `Translucent` keeps its API and gets `Options.sample_count`. Glass has no distance fog (the sw_render shader has none). Its light is the flat light of the cell in front of each face. Glass is never generated.
- Risks: chunk protocol version 8. The translucent quad count is at body byte 44, then 112 bytes of vertices for each quad (world space), then a 12-byte centre for each quad. Main reads only the centres (on the web, from the held bytes). `held-bytes.ts` counts them in the new `centerBytes` stat. The content contract has the new `translucent(block) ?[4]u8`. Such a block is not a full cube and does not darken AO (the AO check is now one lookup table). The `bench-mesher` times were noisy (another build ran), so a slowdown is not ruled out. Look first at `uploadTranslucent` in `main.zig` and at `libs/sw_voxel/src/translucent.zig`.

## #112 Particles and translucent quads sort in one list

- Status: done
- Commit: see `git log --grep "one far-to-near order"`
- Not run here: none
- Expected changes:
  - quad hash: no change
  - goldens: none. `models --check` now times one pass, `sw_blend`, not `sw_translucent` and `sw_particles`.
- CI changes needed: none
- Requirements: REQ-GPU-041 (the REQ-GPU-024 verification text changed)
- Open questions: the voxel demo has no particles, so it does not use `SortedBlend`.
- Risks: `SortedBlend.addPass` turns off the own passes of the two objects. Particles now draw with one draw call for each run, not one in total. The quad distances come from the current camera, in the quad order of the last sort (up to 1 block old). With the two old passes, the new models check fails, as it must. Look first at `libs/sw_render/src/blend.zig`.


## #112 Voxel demo: the graphics settings struct (REQ-GPU-026)

- Status: done
- Commit: see `git log --grep "keeps AA, vsync and lighting"`
- What changed: the demo keeps `state.graphics: sw_render.GraphicsSettings` in place of `msaa_config` and `lighting_mode`. The flags and the settings menu write to it. The GPU setup reads it through `antiAliasingConfig()`. The defaults do not change (FXAA medium, vsync on, skylight). `sw_render.AntiAliasing` gets `msaa2`, and `GraphicsSettings` gets `lighting: gpu.LightingMode = .skylight` (seanorepo does not use these types). The new flag is `--vsync=on|off`. `--msaa=1` now gives `.none` (only the HUD label changes). The demo has no texture atlas, so `mip_levels` is not used.
- Not run here: none
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none
- Requirements: REQ-GPU-026 (statement and rationale updated, and the test covers msaa2)
- Open questions: should `lighting` be a field of the library struct (no preset changes it)? Should the `low` preset turn skylight off?
- Risks: the AA cycle of the settings menu now goes through the enum. Look first at `cycleSettingsValue`.

## #112 Voxel demo: a depth test for the hitbox and the spawn disc

- Status: done
- Commit: see `git log --grep "depth-test the hitbox"`
- What changed: the cylinder pipeline uses `depth_compare = .less_equal` with no depth write, as the chunk border pipeline did. The chunk border uses the same pipeline now, so `border_pipeline` is gone.
- Not run here: a visual check of the hitbox in third person.
- Expected changes:
  - quad hash: no change
  - goldens: none (they use `--debug=off`)
- CI changes needed: none
- Requirements: none
- Open questions: none
- Risks: the spawn disc is 0.01 above the ground, so look for z-fighting far away. Two bugs that were there before: (1) `examples/voxel/tests/chunk_border.sh` fails on lavapipe, because the first-person hitbox (radius 0.3, more than the near plane of 0.1) puts its tint on the whole screen. The script is not in CI. (2) The hitbox and the spawn disc write to the same GPU buffers at offset 0 in one frame, so the hitbox draw reads the disc vertices when both draw. The batch did not fix these. A suggested task for them is in the Claude app.

## #112 Voxel demo: a TAS turns on only the 2D HUD

- Status: done
- Commit: see `git log --grep "depth-test the hitbox"` (the same commit)
- What changed: the new flag `state.hud_2d` shows the debug panel and the keyboard HUD. A TAS sets it in place of `debug_mode`. `--debug=off` and Cmd+D clear it. A TAS run with no `--debug` flag gives ground rows 400 to 629 byte-identical to `--debug=off`.
- Not run here: none
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none
- Requirements: none
- Open questions: "2D HUD" is read as the debug panel and the keyboard HUD. For the keyboard HUD only, change the panel condition near `main.zig:3810`.
- Risks: low

## #112 Voxel demo: a TAS parse error exits with no memory leak

- Status: done
- Commit: see `git log --grep "TAS parse error"`
- What changed: before, a bad TAS gave 2 `leaked` reports (the in-flight and worker arrays of exec_threads), and the worker threads still ran when the allocator checked. `voxelInit` now has an errdefer for the overlay, the copies of the path flags, the world, the profile file, the scheduler and the executor. `freeArgCopies` runs at shutdown too.
- Proof: `examples/voxel/tests/tas_parse_fail.sh` runs a bad TAS with and without `--dump-frame`, `--compare-golden` and `--profile-csv`. Each run exits 1 with no leak report.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none more. The headless job runs the script after the TAS loop.
- Requirements: REQ-VOXEL-033
- Open questions: none
- Risks: the errdefer order must match the init order. Look first at `voxelInit`, where the scheduler and the executor start.

## #112 Voxel demo: is the streaming upload limit a time or a count (REQ-VOXEL-017)

- Status: done (a decision, no code change)
- Commit: see `git log --grep "upload limit a count"`
- Decision: keep the count of 24 uploads for each frame. The REQ-VOXEL-017 rationale gives the reasons: `writeBuffer` only puts the copy in the queue, so a CPU time measures only the copy to staging memory (or the call into JS on the web), not the GPU transfer. A time limit makes a TAS run depend on the clock. GPU timestamps for each upload are not simple.
- Expected changes: none
- Requirements: REQ-VOXEL-017 (rationale only)
- Open questions: confirm the decision. If the count is not sufficient, the next step can be a byte limit (the sum of the quad bytes in a frame). It is deterministic too, and it follows the transfer size.
- Risks: none


## #5 restart a chunk worker that stops with no event

- Status: done
- Commit: see `git log --grep SWZ-5`
- Not run here: a real browser out-of-memory stop. The Bun test makes a worker ignore all its messages, which has the same result for the pool.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none. CI already runs `worker-pool.test.ts`.
- Requirements: REQ-JOBS-003
- Open questions: none
- Risks: a job that takes more than 5 s (for example on a very slow phone) restarts its worker. The result is still correct, because the pool sends the job again and drops the reply of the old worker. Look at `STALL_TIMEOUT_MS` in `backends/wasm/worker-pool.ts` first.

## #6 the voxel wasm loader does not catch a rejected requestPointerLock

- Status: done before this batch (no new commit)
- Not run here: a real browser. `lockPointer` and `requestPointerLockSafe` (`backends/wasm/events.ts`, `window.ts`) catch a throw and a rejection, and log one warning for each refusal. The 18 tests in `backends/wasm/window.test.ts` pass.
- Expected changes: none
- CI changes needed: none
- Requirements: REQ-PLATFORM-001 (exists)
- Open questions: you can close #6.
- Risks: none


## #7 voxel noise lerp calls the software fmaf in wasm

- Status: done
- Commit: see `git log --grep SWZ-7`
- What changed: `lerp` in `examples/voxel/world_gen.zig` uses `@mulAdd` when the target has a hardware FMA (x86 with `.fma`, and aarch64). Each other target, wasm included, uses `lerpF64`: `@floatCast(@as(f64, b - a) * t + a)`, the expression that compiler_rt `fmaf` returns. So wasm calls no `fmaf`, and each target gives the same bits as before. A new test checks that `lerpF64` and `@mulAdd` agree bit for bit on 100 000 noise inputs.
- Times (µs for each chunk, 3 runs. The 4 cores had a load of 3 to 14 from other builds, so the numbers are noisy):

| target | before | after |
|---|---|---|
| native terrain (ReleaseFast) | 1321 / 1294 / 1227 | 1287 / 1219 / 1210 |
| Node 22 wasm terrain | 1783 / 1750 / 1751 | 1605 / 1604 / 1608 |
| Bun wasm terrain | 1294 / 1502 / 1183 | 1694 / 1713 / 1748 |

  Node is about 9% faster. Native does not change. The Bun result is not clear under this load: measure again on an idle machine.
- Not run here: clean times on an idle machine.
- Expected changes:
  - quad hash: no change (`8c11e81d4ec42623`). Block `db5d8508a4c6cd54` and sky `d35232a111956058` do not change. `terrain_hash` for seeds 0, 1 and 12345 is the same on native and wasm.
  - goldens: none
- CI changes needed: none
- Requirements: none
- Open questions: none
- Risks: native and wasm can still differ in rare double-rounding cases, as before. The terrain-hash CI step and the new test watch for this.


## #8 voxel web seed from the URL query

- Status: done
- Commit: see `git log --grep SWZ-8`
- What changed: `backends/wasm/seed.ts` is the one parser, used by the loader and by `headless-app.ts`. A valid value is decimal digits only (no sign, no space, no 0x), up to the u64 maximum. Any other value (also an empty `?seed=`) gives seed 0 and one warning. The loader calls the optional app export `swindowzig_set_seed(u64)` before init. A wasm with no such export ignores the seed. `LoaderOptions.seed` lets a page give the seed itself. The seed reaches the workers through the Hello. New: native `--print-world-hash`, and `headless.ts --query` / `--world-hash`.
- Proof: `examples/voxel/tests/seed_web_native.sh` compares the world hash (blocks, light and the worker mesh hashes) of native `--seed=12345` with the wasm build in Bun with `?seed=12345`: `07a06bf5509eedac` on both, with and without the worker pool. `seed.test.ts` tests the parser.
- Not run here: a real browser. Check: open the dev page with `?seed=12345`, and compare with `zig build run -Dexample=voxel -- --seed=12345`. The terrain must be the same. With no query, the terrain is the old one. `?seed=abc` gives seed 0 and one console warning.
- Expected changes:
  - quad hash: no change
  - goldens: none (no query gives seed 0)
- CI changes needed: none more. The web job runs `seed.test.ts`. The headless job builds the voxel web build and runs `seed_web_native.sh` (2 to 3 min more).
- Requirements: REQ-VOXEL-034
- Open questions: is `swindowzig_set_seed` a good name for the export?
- Risks: look first at `voxelInit` (`state.world_seed = web_seed` on wasm) and at `passSeed` in `loader.ts`. The Bun pool tests ran once, not the 10 runs that `.claude/rules/voxel.md` asks for after a pool change.

## #11 save voxel world edits to local storage

- Status: done
- Commit: see `git log --grep SWZ-11`
- What changed: `examples/voxel/edit_save.zig` is a small format: "SWZE", a version byte, the preset, the seed, a count, a CRC-32, then 13-byte records. It keeps the last edit of each cell, in edit order. The limit is 1 MiB (about 80 000 edits). Past the limit, it keeps the newest edits and warns one time. The key is the seed and the preset (web: `swindowzig:voxel-edits-hilly-0`, native: a file under `SDL_GetPrefPath("seanmizen", "voxel")`, or `--save-dir=<path>`). The save runs at most one time each second when there are edits, and at native exit. The game loads the log before the loading screen. Esc > Settings > Game > "New World (delete saved edits)" deletes the log, and restarts the world, the scheduler, the executor and the GPU chunk buffers. Region files are not used: they store whole chunks through OPFS.
- Flag: `--save=on|off`. The default is on, but off with `--tas`, `--headless`, `--dump-frame` or `--compare-golden`, so the goldens and the TAS runs do not read old edits. Note: an interactive native run and the GPU smoke test now read and write the save folder.
- Proof: `examples/voxel/tests/save_reload.sh` (native: an edit, then a second run reads the block back). `backends/wasm/save.test.ts` (Bun with a fake localStorage: reload, compaction, a corrupt or a short save gives an empty log and a warning, the size limit, no storage, New World).
- Not run here: a real browser and a native window. Check on the web: place and dig some blocks, wait 1 s, reload. The edits must stay. localStorage has the key above. Then New World: the loading screen shows, the terrain is back to the seed, the key is gone, and a reload stays clean. `?seed=5` gets its own key. In a private window (no storage), the game runs, with one "[SAVE] ... The game continues" warning. Natively: the same after a restart.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none more. The web job runs `save.test.ts` (about 25 s). The headless job runs `save_reload.sh` (about 30 s).
- Requirements: REQ-VOXEL-035, REQ-VOXEL-036
- Open questions: (1) The issue asked only to delete the saved log. New World also resets the world in place. Is that too much? (2) The web has no save at exit, so a reload can lose up to 1 s of edits.
- Risks: (1) `newWorld()` on the web: the new Web executor keeps `next_id` and the byte counters of the old one, so late replies of old jobs show as "unknown job id" errors in the console and are dropped. (2) `restoreEdits()` puts the saved edits in `world.edits` and `scheduler.outbox` before `startExecutor`, with versions 1 to n for each chunk. (3) The wasm log shows warnings only, so the "[SAVE]" info lines show on native only. New debug exports: `voxel_debug_block`, `voxel_debug_new_world`.


## #21 let a dependent package build the web examples

- Status: done
- Commit: see `git log --grep SWZ-21`
- What it is: the new public `addWebExample(b, dep, .{ .example, .optimize })` in `build.zig` returns `{ app, chunks: ?Compile }`. The `web` step uses the same internal `webExample()`. The README shows the use from a dependent package.
- Not run here: the release workflow (it needs a tag). The same steps ran by hand: a tarball, `zig fetch --save`, then a build. A path-dependency build and a `--fork` build also passed (an export added for a test in `examples/windows/main.zig` was in `app.wasm` with `--fork`).
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none. `swindowzig-release.yml` changed: its consumer build now calls `addWebExample(.example = "windows")` and checks `zig-out/bin/app.wasm`.
- Requirements: REQ-BUILD-001 (new area file `requirements/build.md`)
- Open questions: after the v0.3.0 tag, `apps/voxel.seanmizen.com/build.zig` in seanorepo can use `addWebExample` and drop the nested `zig build`. The batch did not change it, because the new file needs v0.3.0. The new file is at the end of this VERIFY.md.
- Risks: `addWebExample` makes its steps on `dep.builder`. If the Zig cache misbehaves in a consumer, look there first.

## #9 native Windows build of the voxel example (code only)

- Status: done (code only)
- Commit: see `git log --grep SWZ-9`
- What it is: `scripts/windows-deps.sh` downloads SDL2 2.32.10 (MinGW) and wgpu-native v22.1.0.5 (x86_64-gnu) to `~/.local/windows` (`-Dwindows-deps=<dir>` changes the path). `yarn voxel:windows` (`scripts/voxel-windows.sh`) builds `zig-out/bin/voxel.exe` with `SDL2.dll` and `wgpu_native.dll` next to it. In WSL it copies the three files to `%TEMP%\swindowzig-voxel` and starts the exe. The Win32 surface in sw_gpu was a stub that returned `NotImplementedYet`. It now uses the HWND of the SDL2 window. Native runs print `sw_gpu: adapter "<name>" backend=<b> type=<t>`.
- Ran here: the cross-compile of voxel, justabox, models and flat2d to `x86_64-windows-gnu`. The Linux voxel gate. The WSL path of the script with stub `cmd.exe` and `wslpath`.
- Check on Windows:
  1. In WSL, `yarn windows:deps` once, then `yarn voxel:windows`. A window opens and the world draws.
  2. The console shows `sw_gpu: adapter "<your GPU>" backend=d3d12` (or vulkan), with `type=discrete_gpu` or `integrated_gpu`. Not llvmpipe, not `type=cpu`.
  3. A resize, the mouse look and the keyboard work. The chunk workers fill the world. No crash in the first minute.
  4. If Windows says that SDL2.dll or wgpu_native.dll is missing, the copy to `%TEMP%\swindowzig-voxel` failed.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: optional. A Linux job can run `./scripts/windows-deps.sh && zig build native -Dexample=voxel -Dtarget=x86_64-windows-gnu` to keep the cross-compile green.
- Requirements: REQ-BUILD-002, REQ-BUILD-003
- Open questions: the exe is a console app, so a console window with the log opens too. Do you want the Windows (GUI) subsystem for a release build?
- Risks: look first at the `SDL_SysWMinfo` `win` layout (window, hdc, hinstance) in `libs/sw_gpu/src/native_webgpu.zig`, then at the adapter request (high performance, DX12 or Vulkan, before the surface exists). Not tested on Windows: threads, `std.Io`, files, and `-Daccesskit`.


## #10 bundle the voxel web loaders with the repo build tool, not bun build

- Status: done (swindowzig and seanorepo)
- Commit: swindowzig `git log --grep SWZ-10`. seanorepo: `[SEAN-926] chore: bundle the swindowzig web loaders with RSBuild, not bun build` on its batch branch.
- What changed: RSBuild (`@rsbuild/core`) in both repos. `rsbuild.config.ts` gives fixed `[name].js` names, one file for each entry, real ES module output (`tools.rspack` `outputModule`), no HTML, no public dir, no source maps. swindowzig `build:js` is `rsbuild build` (the same `zig-out/bin/boot.js` and `chunk-worker.js`). The dev server keeps `Bun.Transpiler` (one file at a time, no bundle). seanorepo: voxel `bundle.sh` runs two RSBuild environments and keeps the SHA-256 file names through `source.define`. action `build.sh` runs `yarn rsbuild build`. Both dockerfiles have a `node:lts-slim` js-build stage with `yarn workspaces focus`.
- Not run here: the two Docker builds (Docker Hub rate limit). Each js-build stage ran by hand in a scratch copy and gave the same files as the local build.
- Ran here: the swindowzig gate, `yarn build:js`, `yarn build:voxel`, the bundled page and the dev page in Chromium (3 chunk workers each), `yarn test:browser` (8 passed), `worker-pool.test.ts` (15 pass). seanorepo: both app builds with `SWINDOWZIG_FORK`, both production pages in Chromium (voxel: 3 chunk workers. Action: WebGPU and the game start), `yarn fix`, `tsc --noEmit` in apps/action.
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none more. The browser job has a new step "Bundle boot.js and chunk-worker.js (RSBuild)".
- Requirements: none
- Open questions:
  1. RSBuild uses its default browserslist, so the output is down-levelled a little (boot.js is 54 kB). A WebGPU-only target gives smaller files, but a very old browser then cannot show the "needs WebGPU" panel. The default stays.
  2. swindowzig has @rsbuild/core 1.7.6, seanorepo 1.6.13. Pin one version?
  3. The issue names `yarn voxel:web`, which does not exist. The voxel scripts are `dev:voxel` and `build:voxel`, and both work.
- Risks: if a Docker image fails, look first at `yarn workspaces focus` in the js-build stage (the image has only the package.json files that it copies). The chunk-worker content hash changed once, because RSBuild makes other bytes. The name is still the SHA-256 of the file.


## #13 the voxel chunk pipeline and Web Workers: can it close?

- Status: triage only (no code)
- Findings: the code items of section 12 are done. `libs/sw_voxel/src/pipeline/` has the stages, the protocol, the scheduler and the Inline, ThreadPool and Web executors, and the chunk code has no `is_wasm` branch (only `examples/voxel/main.zig` picks the executor). The goldens run on this pipeline (12 of 12 pass). The install-order, edit-race and executor-equivalence tests are in `examples/voxel/stages_test.zig`, `exec_test.zig` and `backends/wasm/worker-pool.test.ts`. The install budget (C7) is in `exec_threads.zig` and `exec_web.zig`.
- Still open (they need a real browser on the Mac):
  - Section 13: a browser Performance trace of the load and of a 10 s sprint, as the baseline.
  - Section 12: during a sprint, chunk work on the main thread stays within the install budget (p99). This needs the baseline first.
  - Section 12: a block edit shows on screen within 2 frames.
- Open questions: close #13 after these three checks, or move them to a new small ticket and close #13 now.


## #14 native accessibility through AccessKit (code only)

- Status: done (code. Not checked with a real screen reader)
- Commit: see `git log --grep SWZ-14`
- What it is: `docs/accesskit.md` (the research: accesskit-c 0.23.1 is MIT OR Apache-2.0, with some parts under the Chromium BSD licence. The Meson build files are LGPL 2.1, and we do not use Meson). `libs/sw_ui/src/accesskit_map.zig` (the semantic tree to AccessKit nodes, and a diff of two trees, with unit tests). `libs/sw_ui/src/accesskit.zig` (accesskit-c through `extern fn`: Windows, macOS and Linux adapters). The build option `-Daccesskit=true` links `libaccesskit.a` from `~/.local/lib`. It is off by default, and a default build links no accesskit symbol. `ctx.nativeWindow()` is new in sw_app. flat2d uses the backend when the option is on.
- Not run here: a real screen reader (VoiceOver, Narrator, Orca). The macOS and Windows code only compiles (`build-obj` for aarch64-macos and x86_64-windows-gnu). Ran here: `scripts/accesskit/atspi-check.sh`, flat2d under xvfb with a private D-Bus and a fake AT-SPI registry. The registry got the full tree, a GrabFocus gave the focus event, and a DoAction on "Orange" gave the polite announcement "Accent: Orange".
- Check on the Mac with VoiceOver:
  1. Download `https://github.com/AccessKit/accesskit-c/releases/download/0.23.1/accesskit-c-0.23.1.zip`. Copy `lib/macos/arm64/static/libaccesskit.a` to `~/.local/lib/`.
  2. `zig build run -Dexample=flat2d -Daccesskit=true`. It links AppKit, CoreFoundation and objc.
  3. Cmd+F5 starts VoiceOver. Click the flat2d window. VoiceOver says the window "flat2d" and the focused accent item ("Green", selected).
  4. Tab: VoiceOver says each focus: "Close menu, button", "Settings, button", "Name, edit text", "Keyboard, button".
  5. Shift+Tab back to the accent list, then Down: VoiceOver says "Accent: Orange", and the focus does not move (the live region).
  6. VO+U (the rotor) lists the buttons and the list items by name.
  7. VO+Right to "Pink", then VO+Space: the accent changes to Pink, and VoiceOver says "Accent: Pink".
  8. Open Settings. Move the VoiceOver cursor to the Volume slider. VO+Up Arrow: the value goes up.
  9. The VoiceOver outline is on each widget (bounds and the Retina scale).
- Expected changes:
  - quad hash: no change
  - goldens: none
- CI changes needed: none. Optional: a job that downloads the accesskit-c zip and runs `scripts/accesskit/atspi-check.sh` (it needs dbus, xvfb, lavapipe, python3-dbus and python3-gi).
- Requirements: REQ-A11Y-007, REQ-A11Y-008
- Open questions:
  - The semantic tree has no "assertive" politeness, so live text is always polite (the web mirror does the same). Add an option?
  - A package that uses swindowzig with `-Daccesskit=true` must link accesskit-c itself.
  - Text fields send only their value (no caret, no selection). The scroll offset is not sent.
- Risks: bounds are logical units times the DPI scale. If the VoiceOver outline is 2 times too large or too small on Retina, look at `Options.scale` in `accesskit_map.zig`. The macOS focus forward needs the SDL2 NSWindow class name `SDLWindow`. Window focus and bounds go to AccessKit on each tick (`syncWindow`). A screen-reader click is focus, then Enter on a later frame. The AccessKit callbacks use a spin lock.


## #17 greedy_vs_naive.sh fails on main: one wall triangle differs

- Status: done (the script is replaced by a mesher test)
- Commit: see `git log --grep SWZ-17`
- Findings: `examples/voxel/tests/greedy_vs_naive.sh` is not in this repo, and the demo has no 1x1 mode any more (decision D2). So the script was stale. For one temporary build, the batch set `max_merge = 1` and ran the 12 lavapipe scenes against the greedy goldens. The frames differ in at most 0.016% of the pixels: single pixels on quad edges, RMS at most 0.69/255. No triangle differs. The reason: the GPU splits each quad the same way (corners 0,1,2 and 0,2,3), the shader has no diagonal flip, and the merge rule merges only faces with 4 equal corners for AO, sky light and block light. So a merged quad has the shade of its 1x1 quads. The triangle in the issue probably came from the old 1x1 path, which updated only the faces of the dug block: a neighbour face could keep one stale corner, and one stale corner changes one triangle. This is a deduction, not a reproduction.
- What is new: the test "merged quads give each block face the shade of 1x1 quads (REQ-VOXEL-032)" in `libs/sw_voxel/src/mesher.zig`. It meshes a hill chunk and a cave chunk with a dug wall two times (merged, and `max_merge = 1`), for each AO mode, with smooth and flat light. At 9 points on each block face, the block, the tint and the interpolated shade must be the same. Each 1x1 face must be in exactly one merged quad. The test has no HUD.
- Not run here: Apple M1 with Metal (lavapipe only).
- Expected changes:
  - quad hash: no change (`8c11e81d4ec42623`)
  - goldens: none
- CI changes needed: none (the test runs in `zig build test`)
- Requirements: REQ-VOXEL-032
- Open questions: close #17 as "the script is retired, and a mesher test replaces it"? Or add a debug flag that sends `max_merge` to the workers (a protocol change), for a frame test of greedy against 1x1?
- Risks: the test fails when the merge rule accepts two faces with different sky light. It does not catch the same mistake for AO, because its chunks have no adjacent faces with different uniform AO. The old greedy test catches that. On Metal, look first for T-junction cracks on quad edges.


## #79 part 1: the demo framework and the cow demo

- Status: done
- Commit: see `git log --grep SWZ-79`
- What it is: `demos/common/` (the CLI flags `--tas`, `--preset low|medium|high`, `--capture <dir>`, `--check [--update]`, the script format, frame hashes at checkpoints, the overlay, and the reusable `CowScene`). `demos/cow` (a procedural voxel cow with black-and-white patches on a turning stand. The script changes AA, meshing with a wireframe, tonemap, exposure, palette, time of day, shadows, AO, fog and sky, one at a time, with a caption). `yarn demos:record` (MP4 and WebP for each demo and preset, in `zig-out/demos`). `yarn demos:check`. `yarn dev:demo <name>`. `-Ddemo=<name>` for `zig build run|native|web`. No change to `libs/`: the tonemap curves, exposure, FXAA, MSAA, Sky, Lighting and the frame chart existed.
- Ran here: `scripts/demos-check.sh --twice` passes for the three presets (the same hashes two times). `yarn demos:record`: MP4 files of 3.2, 5.5 and 7.7 MB, WebP files of about 520 KB. `docs/media/cow.webp` (medium) is committed. The MP4 files are not committed. `zig build web -Ddemo=cow`: the page draws in headless Chromium (canvas pixels read back). Native window runs under xvfb in Debug, ReleaseSafe and ReleaseFast.
- CI: `demos-check.yml` (job "demo scripts on lavapipe") passed on PR #113. The CI lavapipe gives the same hashes as this sandbox.
- Not run here: `demos-videos.yml` (manual, input tag, attaches the MP4 files to the Release). `yarn test:browser` has no demo test. A long run in a real window on a real GPU.
- Expected changes:
  - quad hash: no change
  - goldens: none. New demo hashes in `demos/cow/hashes/lavapipe-{low,medium,high}.txt` (Mesa 25.2.8 lavapipe).
- CI changes needed: none more (the two workflows are in the commit).
- Requirements: REQ-DEMO-001 to REQ-DEMO-007 (new area `requirements/demo.md`)
- Open questions: the demo hashes are exact, with no tolerance (the voxel goldens have a tolerance). A new Mesa on the runner can change them: the job then uploads the hashes and prints the accept command. The web build plays its own script only (no `--tas` from the URL). The camera, light and fog values are a matter of taste: look at them on the Mac.
- Risks: in capture and check runs, the overlay shows the fixed step time, not a measured frame time (REQ-DEMO-004). A check run draws only the checkpoint frames. One early ReleaseFast run stopped with "Illegal instruction", probably because a check script rebuilt the binary while it ran. Later runs had no crash. Look first at `checkHashes` in `demos/common/demo.zig` and at `scripts/demos-check.sh`.


## #79 part 2: the menu demo

- Status: done
- Commit: see `git log --grep "menu demo"`
- What it is: `demos/menu` is a game menu over the turning cow.
  - Main: Resume, Player, Settings.
  - Settings: Graphics, Audio, Controls, Gamepad, Interface.
  - Graphics: preset, AA, coat, exposure, time and spin sliders, and the shadows, AO, fog, sky and wireframe toggles.
  - Audio: one volume for each sound group, each with a short generated sound.
  - Controls: key rebinding with a conflict warning, mouse sensitivity, invert Y.
  - Gamepad: the dead zone, with a live stick readout.
  - Interface: English or Hebrew (RTL, the panel moves to the left), and a TrueType font or a bitmap font.
  - Player: a text field, the on-screen keyboard (Hebrew keys in Hebrew mode) and a scroll list.

  Each setting changes the cow in the same tick. The camera turns round the cow with keys, the right stick or a mouse drag. `demos/common` gets script input commands (`key`, `text`, `pad`, `axis`, `mouse`, `wheel`) and `interactive = true`: a demo plays its script in a window until the viewer presses a key, then gives control to the viewer. The font is Noto Sans Hebrew Regular (OFL, 48 KB), with its notice.
- Ran here: `scripts/demos-check.sh --twice` for cow and menu at each preset (24 checkpoints for menu). The cow hashes do not change. `yarn test:browser` 9 of 9, with the new `menu.pw.ts`: it checks that the Chromium accessibility tree has the menu widgets. A native window under xvfb for 20 s, with no crash. `docs/media/menu.webp` (medium, 745 KB).
- Not run here: VoiceOver or NVDA, a real gamepad, sound output (no audio device), `-Daccesskit=true`.
- Check by hand:
  - `yarn dev:demo menu`, then VoiceOver in Safari and Chrome. Press a key to take control. The dialog names, the slider values ("17:17", "60%") and the Hebrew names are read. The live "Player:" line and the conflict warning are announced.
  - Gamepad: the D-pad and the left stick move the focus, south activates, east goes back, the shoulders tab, the right stick turns the camera. A stick inside the dead zone does nothing.
  - The look: the panel at the low preset (640x360), the Hebrew layout, the bitmap font, the WebP (480 px wide, so the text is small).
  - Sound: each volume slider is audible, and the music loop plays.
- Expected changes:
  - quad hash: no change
  - goldens: none. New `demos/menu/hashes/lavapipe-{low,medium,high}.txt`.
- CI changes needed: none. The Playwright config has a third web server and project ("menu", port 3022).
- Requirements: REQ-DEMO-008, REQ-DEMO-009, REQ-DEMO-010
- Open questions: the on-screen keyboard labels (Shift, Symbols, Space, Backspace, Done) are fixed English strings in sw_ui `osk.zig`. Let the app give them? The bitmap font is Lato at 10 px, made at init: do you want a hand-drawn pixel font? In Hebrew mode, sw_ui still draws button text from the left edge.
- Risks: rebinding to the keys that the menu uses (arrows, Enter, Esc) is not blocked. The script is long (3709 ticks), so a change to the sw_ui focus rules or layout moves many checkpoints. Look first at the key sequence in `menu.tas` and at `uiInput()` in `demos/menu/main.zig`.


## #79 part 3: the shooter demo

- Status: done
- Commit: see `git log --grep "shooter"`
- What it is: `demos/shooter` is an offline first-person shootout in a snowy arena. Three bots move, take cover, peek, aim and fire back, in waves. It uses falling snow and a cloud layer, fog, the sky, shadows, particles (muzzle flash, impacts by material, snow puffs), 3D gun sound (procedural), box models for the bots and the gun, collision, the camera, input actions and the gamepad. The bots use a seeded RNG on the fixed timestep. No network code.
- Harvested from seanorepo `apps/action/game/src`:
  - In full: `guns.zig`, `guns.bin` (Quaternius, CC0, 356 KB, embedded in the binary), `weapon.zig`, `npc.zig` (with a new aim pose), `ragdoll.zig`, `player.zig`, `audio/{dsp,space,impact,near_miss}.zig`, and the `guns_test` tests that need no `server/guns.json`.
  - In part: `impact_fx.zig` (the recipes, now on sw_render particles), `range.zig` and `shooter_hud.zig` (damage numbers, health bars, shadowed HUD text).
  - Not taken: `shooter.zig` (the range panel NPC), `body.zig` (it needs `grenade.zig` and the console), `audio/choir.zig`, and the tests that use the London map. No audio files: each sound is a procedural model.
- Ran here: the gate. `scripts/demos-check.sh --twice` for all demos at each preset (cow 22, menu 24, shooter 11 checkpoints). `docs/media/shooter.webp` (medium, 485 KB). The web build runs in headless Chromium (SwiftShader, about 2 fps) with no WebGPU error, and the frames advance. `zig build test` runs the shooter tests (`demos/shooter/tests.zig`: arena, body model, gun model, fight determinism, particles).
- Not run here: a picture of the web build (the screenshot was white), sound (no audio device. Capture and check runs make no sound by design).
- Check by hand:
  - The feel: `zig build run -Ddemo=shooter`. The script plays in a loop. A key, a click or a gamepad button takes control and locks the pointer. Check the mouse look (0.0022 rad for each pixel), the movement, the recoil, hip fire and the sights (right button. The gun covers much of the view at the sights), the lean (Q/E), and the bot difficulty (`bot_damage`, `bot_error`).
  - Gamepad: left stick moves, right stick looks, right trigger fires, left trigger aims, south jumps, west reloads, the shoulders lean.
  - Sound, native and web (the web needs a click first): the muzzle report with a distance delay and pan, the near-miss crack, the impact by material, the reload clicks.
  - The web picture in a real browser: `yarn dev:demo shooter`.
- Expected changes:
  - quad hash: no change
  - goldens: none. New `demos/shooter/hashes/lavapipe-{low,medium,high}.txt`. The cow and menu hashes do not change.
- CI changes needed: none (the demo workflows loop over `demos/*/main.zig`).
- Requirements: REQ-DEMO-020 to REQ-DEMO-024
- Open questions: none
- Risks: the script was made by a generator and tuned to the seeded fight. The bots must be at the given places when the player fires. A change to `game.zig`, `arena.zig`, `player.zig` or the bot hit boxes moves the bots, and then the kills in the script miss. To tune it again, add `set trace on` to a `--check` run: it logs the places and the aim angles every 15 ticks. A bot can still catch on a box corner. Bot rounds fly from the eye line, not from the muzzle.


## #79 part 4: README

- Status: done
- Commit: see `git log --grep "short README"`
- What changed: `README.md` follows the plan of #79 and fits on one screen: the progress block, the three WebP loops, "Try it", "Use it", one table of the libraries, "Make the videos". The old text is in `docs/overview.md`, with its links fixed.
- Not run here: a look at the page on GitHub.
- Open questions: each WebP is 480 px wide, so the menu text is small in the page. Each WebP links to nothing yet: the MP4 files go to the Release when you run `demos-videos.yml` after the tag.

## seanorepo (its own draft PR)

- #724: the voxel overlays, `build.sh` and the README name only files that exist.
- #926: PR #933 merged in and applied to the renamed `apps/voxel.seanmizen.com`. The pin stays v0.2.0 until the tag. Until then, build with `SWINDOWZIG_FORK=<checkout>`.
- #928: `bind grave toggleconsole`, the new key names, `mwheelup` and `mwheeldown`. The action build needs a swindowzig with `KeyCode.Grave`, so it needs the fork or v0.3.0.
- #10 (seanorepo side): RSBuild in `bundle.sh`, the action `build.sh` and both dockerfiles.
- Not run: both Docker builds (Docker Hub 429). A browser check that the grave key opens the console.
- Open questions: with the console open, only the typed "`" or Esc closes it, so a rebound `toggleconsole` key opens it but does not close it. "/" (the chat) stays typed text.
- After the tag: `zig fetch --save https://github.com/seanmizen/swindowzig/releases/download/v0.3.0/swindowzig.tar.gz` in `apps/action/game` and in `apps/voxel.seanmizen.com`, build both apps with no fork, commit the two `build.zig.zon` files, and use the new `apps/voxel.seanmizen.com/build.zig` below.

### The new `apps/voxel.seanmizen.com/build.zig` (after the v0.3.0 tag)

```zig
// Where: apps/voxel.seanmizen.com/build.zig
// When: `zig build` from this directory (build.sh and the dockerfile run it).
// Why: builds the voxel example of the swindowzig release that build.zig.zon
// pins, and installs it to zig-out/bin:
//   app.wasm      the voxel engine
//   chunks.wasm   the chunk worker (voxel only)
// It also installs the web backend of that release (backends/wasm,
// TypeScript) to zig-out/swindowzig/backends/wasm. src/boot.ts and bundle.sh
// take the loader and the chunk worker from there. So the wasm and the
// loader come from the same swindowzig. `zig build --fork=<swindowzig
// checkout>` replaces both.
//
// addWebExample (in the build.zig of swindowzig) puts the example build in
// this build graph. There is no nested `zig build`, and the Zig cache sees
// each source file of the dependency.
//
// -Dexample=<name>: the swindowzig example. The default is voxel.
const std = @import("std");
const swindowzig = @import("swindowzig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const example = b.option([]const u8, "example", "The swindowzig example to build. Default: voxel") orelse "voxel";

    const sw = b.dependency("swindowzig", .{});
    const web = swindowzig.addWebExample(b, sw, .{ .example = example, .optimize = optimize });
    b.installArtifact(web.app);
    if (web.chunks) |chunks| b.installArtifact(chunks);

    b.installDirectory(.{
        .source_dir = sw.path("backends/wasm"),
        .install_dir = .prefix,
        .install_subdir = "swindowzig/backends/wasm",
        .include_extensions = &.{".ts"},
        .exclude_extensions = &.{".test.ts"},
    });
}
```
