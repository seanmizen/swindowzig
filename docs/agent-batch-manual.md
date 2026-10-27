# Engine batch: manual for the Claude Code cloud agent

You are a Claude Code cloud session. You build the remaining engine tickets of
swindowzig on one branch, one commit for each ticket. You do not wait for CI.
You do not open a PR for each ticket. Sean checks the full branch on a Mac
later, in issue #103.

This manual is the procedure for issue #102. Follow it in order. `CLAUDE.md`
and the rules in `.claude/rules/` also apply. Where they disagree with this
manual, this manual wins for this batch only.

## 1. Rules

- Work on the branch `SWZ-102/engine-batch`. Never push to `main`. Never
  force-push.
- Do not change `.github/workflows/`. Write each CI change that a ticket needs
  in `VERIFY.md`.
- Do not open a PR, except the one draft PR at the end (step 6).
- Do not close issues. Do not change labels. Sean does this in #103.
- Make one commit for each ticket. The commit message is
  `[SWZ-<ticket>] <type>: <description>`. The types are `feat fix chore docs
  refactor test style perf ci`. Never use `--no-verify`.
- Push the branch after each commit. A cloud session can stop at any time.
  A pushed commit is not lost.
- The public API has no game names and no game file formats. Do not break an
  existing public API: `apps/action` and `apps/minecraft.seanmizen.com` use it.
- Write prose in STE. Load the `ste` skill before you write docs, comments or
  commit messages. In code comments, cite the requirement (`REQ-<AREA>-<NNN>`),
  never the issue number.
- Use Yarn 4 only. Bun is a runtime only. Never run `npm install` or
  `bun install`.

## 2. Setup

Do these steps one time at the start of the session.

1. Run the setup script:

   ```bash
   bash scripts/cloud-setup.sh
   export PATH="$HOME/.local/bin:$HOME/.local/zig:$HOME/.bun/bin:$PATH"
   ```

   If a download fails because of the network, record it in `VERIFY.md` and
   continue with the tools you have. `zig` is necessary. If you cannot install
   `zig`, stop and report.
2. Make the branch from `main`, or continue it if it exists:

   ```bash
   git fetch origin
   git checkout SWZ-102/engine-batch 2>/dev/null \
     || git checkout -b SWZ-102/engine-batch origin/main
   ```

3. Check the base. Run `zig build test` and `zig build web`. If either fails
   before you change anything, stop and report. Do not fix the base.
4. If `VERIFY.md` exists, read it and `git log --oneline origin/main..HEAD`.
   Continue with the first ticket that has no entry.

## 3. Read an issue

The repository is public. Read an issue with `gh` if it is installed:

```bash
gh issue view <n> -R seanmizen/swindowzig
```

If `gh` is not available, use the GitHub API:

```bash
curl -fsSL https://api.github.com/repos/seanmizen/swindowzig/issues/<n> \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["title"]); print(d["body"])'
```

Some issues name horizon reference files. Read one with:

```bash
curl -fsSL "https://raw.githubusercontent.com/ludovic111/horizon/88b3b3e879adde9dc7b5fed8c0ade1f281af347d/<path>"
```

Horizon is MIT. Use it for the technique only. If you copy horizon code, add
the horizon MIT notice to `THIRD_PARTY_NOTICES.md`.

## 4. Ticket order

Do the tickets in this order. Earlier tickets build the code that later
tickets use.

| # | Ticket | Area |
|---|---|---|
| 1 | #66 the sw_voxel frustum uses the sw_math Plane and Aabb | sw_voxel |
| 2 | #93 `chunk_corner_ao.tas` does not parse | voxel TAS |
| 3 | #76 `voxel --place-block` has no effect | voxel demo |
| 4 | #34 fluid surface mesher | sw_voxel |
| 5 | #35 translucent pass with back-to-front sort | sw_render, sw_voxel |
| 6 | #42 particle system with billboards | sw_render |
| 7 | #44 graphics settings, frame pacing, performance overlay | sw_render, sw_gpu |
| 8 | #81 fog as a post effect that reads the depth target | sw_render |
| 9 | #101 light shafts, cloud shadows and soft clouds | sw_render |
| 10 | #26 sw_jobs worker pool for threads and Web Workers | sw_jobs, sw_voxel |
| 11 | #39 far terrain level of detail | sw_voxel |
| 12 | #40 occlusion and cave culling | sw_voxel, sw_render |
| 13 | #55 chunk streaming around the camera | sw_voxel |
| 14 | #61 web texture view leak: close-out check | sw_gpu web |
| 15 | #92 flat2d browser tests draw no frames in CI | browser tests |

Before you start #101, check that issue #37 is closed. If #37 is open, skip
#101 and record it as `skipped: #37 is not merged`.

## 5. The loop for each ticket

Do these steps for each ticket.

1. Read the issue: the context and each acceptance criterion.
2. Read the code that the issue names. Read the merged code that it builds
   on. Do not guess an API: read the source. For the Zig standard library,
   read the source under `$(zig env | grep lib_dir)`. `.claude/rules/zig.md`
   does not exist in this repository. `CLAUDE.md` has the Zig 0.17 notes.
3. Write the code and the tests. Each acceptance criterion needs a test or a
   check. For a GPU check (a native `--check` mode), write the check even if
   you cannot run it here.
4. Run the gate (below). Fix each failure.
5. Add the requirements to `requirements/<area>.md` with the next free
   number in that file. Run `yarn requirements:build`, then
   `yarn requirements:check`.
6. Write the `VERIFY.md` entry for the ticket (below).
7. Run `yarn fix`. Commit all the files of the ticket and `VERIFY.md`. Push.

### The gate

Each ticket must pass these commands before you commit it:

```bash
zig fmt --check .
zig build test
zig build web
yarn fix
yarn requirements:check
```

For a ticket that changes `libs/sw_voxel` or `examples/voxel`, also run:

```bash
zig build web -Dexample=voxel
zig build bench-mesher -Doptimize=ReleaseFast
zig build bench-stages
zig build native -Dexample=voxel
./zig-out/bin/voxel --headless --tas examples/voxel/framespike.tas
```

- `bench-stages` must print `stage_match=yes`.
- If the quad hash of `bench-mesher` changes, the change must be on purpose.
  Write the old and the new hash in `VERIFY.md`, and the reason.

For a ticket that changes `backends/wasm`, also run the Bun test files that
it touches, for example `bun test backends/wasm/events.test.ts`.

If `vulkaninfo` lists the lavapipe device, also run each native `--check`
example that the ticket touches:

```bash
zig build native -Dexample=<name> && ./zig-out/bin/<name> --check
```

The `--check` examples are `justabox`, `atlas`, `mipmaps`, `sky` and
`models`, and each new one that a ticket adds. If lavapipe is not available,
write `not run: no GPU` in `VERIFY.md`.

### When a ticket does not pass the gate

- Try to fix it. Give the ticket at most about 90 minutes of work in total.
- If it still fails, do not commit broken code. Run `git stash` or
  `git checkout -- .` to remove the changes.
- Write a `VERIFY.md` entry with the status `skipped`, the failure and what
  you learned. Commit only `VERIFY.md` with the message
  `[SWZ-<ticket>] docs: skip in the engine batch`. Push.
- Continue with the next ticket. If a later ticket needs the skipped ticket,
  skip the later ticket too and give the reason.

## 6. VERIFY.md

`VERIFY.md` is at the root of the branch. Sean uses it as the checklist in
#103. Add one entry for each ticket, in the order of the batch. Use this form:

```markdown
## #34 fluid surface mesher

- Status: done | skipped
- Commit: <short hash>
- Not run here: <the checks you could not run, and why>
- Expected changes:
  - quad hash: <old> -> <new>, because <reason>
  - goldens: <which golden images change, and why>
- CI changes needed: <steps to add to .github/workflows/, or "none">
- Requirements: REQ-<AREA>-<NNN>, ...
- Open questions: <decisions Sean must make, or "none">
- Risks: <what can be wrong, and where to look first>
```

At the top of the file, keep a short summary: the number of tickets done, the
number skipped, and the tools that the setup could not install.

## 7. The end of the batch

When each ticket in the order is done or skipped:

1. Run the full gate one more time on the last commit, with the voxel
   commands.
2. Merge `main` into the branch if `main` moved: `git fetch origin && git
   merge origin/main`. Keep both sides of each conflict. Regenerate
   `requirements/index.md` with `yarn requirements:build`. Run the gate again.
   Push.
3. Open one draft PR from `SWZ-102/engine-batch` to `main`:
   - Title: `[SWZ-102] feat: engine batch from the cloud agent`
   - Body: the `VERIFY.md` summary, then `Closes #<n>` for each done ticket,
     and `Refs #103`.
   - If `gh` is not available, push the branch and write the PR text in your
     final message. Sean opens the PR.
4. Stop. Give a final report: the tickets done, the tickets skipped and why,
   the tools that were not available, and the link to the draft PR.

## 8. Stop rules

Stop and report at once when one of these occurs:

- The setup cannot install `zig`.
- `zig build test` fails on `main` before your first change.
- A change needs `.github/workflows/`, a push to `main`, or a force-push to
  continue. Record it in `VERIFY.md` and continue with the next ticket. Stop
  only if no ticket can continue.
- The same failure stops 3 tickets in a row.
