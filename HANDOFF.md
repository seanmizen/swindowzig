# Handoff: SWZ-79 showcase demos (work in progress)

Sean paused this work. This file tells the next agent what is done, what
is not done, and what to do next. Remove this file in the last commit of
the ticket, before the merge.

Branch: `SWZ-79/showcase-demos`. Issue: #79.

## Tools that the work needs

- Zig 0.17, SDL2 and wgpu-native in `~/.local` (see `README.md`).
- A GPU for each `--check` and for the frame hashes: Metal on the Mac,
  lavapipe on the Linux CI runner.
- ffmpeg with libx264 for the MP4 files. For the WebP files: ffmpeg with
  libwebp, or `img2webp` (Homebrew `webp`, Debian `webp`). The Mac has
  ffmpeg with no libwebp, and `img2webp`.
- Bun and Playwright for the web checks.

## What is done

- `build.zig`: `-Ddemo=<name>` builds `demos/<name>/main.zig`. A name with
  no example also falls back to `demos/` (so `-Dexample=cow` works). Each
  example and demo gets the `sw_audio` and `demo_common` imports.
  `zig build test` runs the demo unit tests.
- `demos/common/` (module `demo_common`):
  - `run.zig`: the flags `--tas`, `--preset low|medium|high`,
    `--capture <dir>`, `--capture-every <n>`, `--hashes <file>`,
    `--check`. The TAS player. The frame capture (PPM) and the checkpoint
    hashes (every 60 ticks). A seeded RNG. An offline run draws only the
    frames that it captures or hashes.
  - `mesh.zig`: a triangle mesh renderer on the frame graph. It has the
    shadows, the point lights, the fog, a line (wireframe) pipeline, a
    first-person pass and an MSAA sample count.
  - `cow.zig`: the original voxel cow, a naive mesher and a greedy mesher
    with per-corner AO. It has unit tests.
  - `cow_scene.zig`: the turning cow on a stand in a field. It applies
    each setting at once. A change to or from MSAA makes the graph again.
  - `overlay.zig`, `fonts.zig`, `bitmap_font.zig`, `sound.zig`, and
    `assets/NotoSansHebrew-Regular.ttf` with its OFL licence.
- `demos/cow`: the demo and `cow.tas` (about 55 s). The script changes
  each setting of the issue, with a caption. `--check` passes on Metal.
- `demos/menu`: the demo and `menu.tas`. It has a screen stack, keyboard,
  mouse and gamepad focus, graphics, audio, controls (rebinding with a
  conflict warning, sensitivity, invert Y), gamepad dead zone, a text
  field, a scroll list, tooltips, the on-screen keyboard, Hebrew, and a
  bitmap font. `--check` passes on Metal.
- `demos/shooter`: the demo and `shooter.tas`. It has a snowy arena, 4
  bots that take cover and fire back, snow with a height map, clouds,
  fog, sky, shadows, particles, muzzle point lights, 3D sound, box-model
  bots, collision, the sw_math camera, input actions and a gamepad. No
  network code. `--check` passes on Metal.
  - Harvested from seanorepo `apps/action/game/src`: `assets/guns.bin`
    (Quaternius, CC0, `assets/guns-LICENSE.md`), the model reader of
    `weapon.zig` (now `guns.zig`), and `audio/dsp.zig`, `space.zig` and
    `impact.zig` (unchanged copies).
  - Written again on the engine APIs: the bots, the player, the HUD and
    the impact effects. The issue lists `npc.zig`, `range.zig`,
    `player.zig`, `body.zig`, `ragdoll.zig`, `impact_fx.zig` and
    `shooter_hud.zig`. These files depend on `map.zig`, `mesh.zig` and
    the console of the game, so they are not copied.
- `libs/sw_render`: `FrameGraph.targetSampleCount`, and the sky pipeline
  takes the sample count of its target (REQ-GPU-040). This is an
  addition. No public API changed.
- `demos/scripts/check_hashes.sh`: each demo, each preset, two runs. The
  hashes must be equal. On Linux with lavapipe they must also equal
  `demos/<demo>/hashes/lavapipe-<preset>.txt` (`--update` writes them).
- `demos/scripts/record.sh`: each demo and preset to an MP4 file and a
  WebP loop in `zig-out/demo-media/`. `--readme` copies the medium WebP
  files to `docs/media/`. One run (cow, medium) gave a 1.0 MB MP4 file and
  a 296 KB WebP file.
- `backends/wasm/dev-server.ts` also watches `demos/`.

## Gates now

| Gate | State |
|---|---|
| `zig build test` | pass |
| `zig build web -Ddemo=cow`, `menu`, `shooter` | pass |
| `zig build native -Ddemo=...` | pass |
| `cow --check`, `menu --check`, `shooter --check` (Metal) | pass |
| `demos/scripts/check_hashes.sh` (Metal, 9 pairs) | pass |
| The three demos in headless Chromium (manual scratch check) | run, no Zig error |
| `zig fmt`, `yarn fix` | pass |
| `zig build web` (default example) | not run after the last change |
| `yarn test:browser` | not run |
| `yarn requirements:check` | not run. REQ-GPU-040, REQ-DEMO-001 and REQ-DEMO-002 are cited but not written |
| STE lint of the new prose | not run |
| CI | not run |

## Acceptance items of #79

| Item | State |
|---|---|
| The three demos build and run on native and web | done (`-Ddemo`) |
| The cow is original, and its TAS shows each change with a caption | done |
| The shooter: offline, snowy, bots fire back, the engine features, no network code | done |
| The menu: each widget and setting, applied at once | done |
| Each demo has a TAS. Two runs give the same hashes | done on Metal. Not run on lavapipe |
| `yarn demos:record` makes MP4 and WebP files | script done. The `package.json` entry is not added. The videos are not made |
| CI replays each TAS and checks the hashes | not done |
| `README.md` follows the plan. The old text is in `docs/overview.md` | not done |
| `THIRD_PARTY_NOTICES.md` lists the gun models and the other assets | not done |
| No game names or game file formats in the public API | done (demo code only) |
| No break of a public API | done (one addition in sw_render) |
| `zig build test` and `zig build web` pass | `test` pass, `web` for the demos pass |

## Next steps

1. Add to `package.json`: `"demos:record": "bash demos/scripts/record.sh"`
   and `"dev:demo": "bun backends/wasm/dev-server.ts --example"`.
2. Write the requirements: REQ-GPU-040 in `requirements/gpu.md` (a
   multisampled target gets a multisampled sky). Make
   `requirements/demo.md` with REQ-DEMO-001 (one TAS and one preset give
   the same frame hashes) and REQ-DEMO-002 (the capture follows the
   fixed timestep, not the wall clock). Add the `DEMO` row to the prefix
   registry in `requirements/README.md`. Run `yarn requirements:check`.
3. CI, in `.github/workflows/swindowzig-check.yml`:
   - Next to the other `--check` steps: `zig build web -Ddemo=X`,
     `zig build native -Ddemo=X`, `./zig-out/bin/X --check` for cow,
     shooter and menu.
   - A new job in the same file: `demos/scripts/check_hashes.sh` on
     lavapipe. At first there are no goldens: the job fails. Upload the
     hash files as an artifact on failure (or run `--update` and upload
     `demos/*/hashes/`), then download them with `gh run download` and
     commit them.
4. Add a manual workflow (`workflow_dispatch`, input: the release tag)
   that installs ffmpeg and webp, runs `demos/scripts/record.sh` on
   lavapipe, and attaches the MP4 files to the release with
   `gh release upload`.
5. Run `demos/scripts/record.sh --readme`. Commit `docs/media/cow.webp`,
   `shooter.webp` and `menu.webp` (each must be at most 4 MB).
6. Move the current `README.md` text to `docs/overview.md`. Write the
   short README of the issue plan, with the progress block, the WebP
   table, "Try it", "Use it", the library table and "Make the videos".
7. `THIRD_PARTY_NOTICES.md`: add the Quaternius gun pack (CC0), Noto Sans
   Hebrew (OFL), and the reuse of Lato for the demos.
8. Add the demos to `CLAUDE.md` (project structure, a short breadcrumb).
9. Run the gates of `CLAUDE.md`: `yarn fix`, `zig build test`,
   `zig build web`, each demo `--check`, `yarn test:browser`, the STE lint
   on new prose. Then open the PR, wait for CI, merge.

## Open decisions

- The shooter `--check` passes with few player hits (3 hits, 1 kill in
  the last run). The player has an aim assist of 3 degrees so that a TAS
  sweep can hit a bot. A better TAS can give a better video.
- The bot shots can kill the player in the TAS run (1 death). The player
  then starts again at the spawn. Lower bot damage if the video must show
  no death.
- The CI hash job runs 18 offline runs on lavapipe. Each run draws about
  55 frames, so it may be fast. Its time on CI is not measured.
- The menu TAS types "123" with the on-screen keyboard. Letters can look
  better in the video.
- Audio is off in offline runs (no device needed). The web shows the
  AudioContext gesture warning until the first click.
