# Engine batch: verification log

This file is the checklist for #103. The cloud agent wrote one entry for each
ticket of #102, in the order of the batch.

## Summary

- Done: 2. Skipped: 0. Not started: 13.
- Setup:
  - ziglang.org and bun.sh are blocked in the cloud sandbox. Zig 0.17.0 came
    from the official `ziglang` wheel on PyPI, and Bun from the npm package
    `@oven/bun-linux-x64`. The other setup steps ran.
  - lavapipe works. So the native `--check` examples, the voxel GPU smoke
    test (under `xvfb-run`) and the lavapipe golden comparison
    (`run_headless_regressions.sh`) ran here. Their results are in each
    entry.
  - The browser tests (`yarn test:browser`) did not run.
  - `apps/action` and `apps/voxel.seanmizen.com` in seanorepo use the copy
    of swindowzig in `utils/swindowzig`. The batch did not build them.

## #66 the sw_voxel frustum uses the sw_math Plane and Aabb

- Status: done
- Commit: see `git log --grep SWZ-66`
- Not run here: the consumer builds in seanorepo (they use their own copy
  of swindowzig).
- Expected changes:
  - quad hash: no change (`8c11e81d4ec42623`)
  - goldens: none. The lavapipe goldens passed here (10 of 10).
- CI changes needed: none
- Requirements: none (a refactor with the same results)
- Open questions: none
- Risks: `setPlanes` now normalizes each plane (`Plane.fromCoefficients`).
  A positive scale does not change the side of a box, so the cull is the
  same. `build.zig` already gave sw_math to sw_voxel, so it did not change.

## #93 `chunk_corner_ao.tas` does not parse

- Status: done
- Commit: see `git log --grep SWZ-93`
- Not run here: nothing. All 16 scripts in `examples/voxel/tests/` now
  exit 0 headless on the flatland world.
- Expected changes:
  - quad hash: no change
  - goldens: none. `chunk_corner_ao` has no golden.
- CI changes needed: optional. A CI step that runs each
  `examples/voxel/tests/*.tas` headless would stop a script that does not
  parse.
- Requirements: none
- Open questions: none
- Risks: the cause was not the two spaces. The tokenizer already accepted
  them. The script used `key_down a`, but the commands are `keydown` and
  `keyup`, and the key names are upper case (`A`). The script now uses the
  correct names. The parser now also accepts a tab between fields, and a
  test covers more than one space and a tab. Separate bug, not fixed: when
  the TAS parse fails, the voxel demo logs a memory leak on exit.
