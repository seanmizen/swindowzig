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
