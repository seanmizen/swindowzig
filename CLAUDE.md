# CLAUDE.md

Sean's polyglot monorepo, made from `template-seanorepo`. Yarn 4 workspaces sit
under `apps/*`, `utils/*` and `projects/*`. The Yarn and Claude Code setup is
the same as in `seanmizen/seanorepo`. Replace this paragraph with what the repo
is for.

More instructions load only when they are relevant:

- `.claude/rules/` - rules scoped to paths. They load when you touch matching
  files: Docker and ports.
- `.claude/skills/workflow/` - the ticket, branch, PR and merge procedure. Use
  it whenever you create an issue or open a PR.
- A `CLAUDE.md` inside an app or util loads when you work in that directory.

## Setup

```bash
yarn
```

The repository carries its Yarn 4 release in `.yarn/releases`, and
`.yarnrc.yml` names it in `yarnPath`. Any system `yarn` runs that release,
Yarn 1 included. Do not use corepack.

Root `package.json` scripts are the entry points. Read them rather than
guessing.

## Hard rules

- **Yarn 4 only.** Never `npm install` or `bun install`. Bun is a runtime only
  (`bun index.ts`). Bundling belongs to the build tool, never `bun build`.
- **Before you finish:** run `yarn fix` from the root (Biome: lint and format).
  Run `tsc --noEmit` in every TypeScript backend you touched. Fix every error.
- **Never `--no-verify`.** The hooks run commitlint.
- **Every published port names its host address:**
  `"${PUBLISH_ADDR:-127.0.0.1}:4000:4000"`. Never a bare `"4000:4000"`. See
  `.claude/rules/ports.md`.
- **All backend API routes use the `/api` prefix.**
- **Write in STE.** Load the `ste` skill (`.claude/skills/ste/`) before you
  write prose. Use Strict mode for error messages, tool descriptions and agent
  instructions. Use STE-flavored mode for docs, comments, commit messages, PR
  bodies and replies to Sean. Run `.claude/skills/ste/scripts/ste-lint.py` on
  new prose. In code comments and docs, cite the requirement
  (`REQ-<AREA>-<NNN>`) and never the issue or PR number. See
  `requirements/README.md`.

## Conventions

- Branch: `TEMPLATE-{issue}/{short-description}`. Lowercase, hyphenated, at
  most 5 words.
- Commit and PR title: `[TEMPLATE-{issue}] {type}: {description}`. Types:
  `feat fix chore docs refactor test style perf ci`.
- One ticket = one branch = one PR, squash-merged. Out-of-scope work gets a new
  issue, not a commit on this branch.
- Work in a worktree, never on the `main` checkout.

Full procedure, with `gh` commands: `.claude/skills/workflow/SKILL.md`.

## Layout

- `apps/` - one directory per site or service. Frontend and backend share a
  `docker-compose.yml`, and backends sit beside their frontends.
- `projects/` - client and video projects. Each one is a workspace.
- `utils/` - tooling.
- `scripts/` - repo-level scripts. `yarn labels` runs `scripts/labels.sh`,
  which makes the GitHub labels that the workflow uses.
- `requirements/` - the requirements index and its checker
  (`yarn requirements:check`).
