# template-seanorepo

An empty monorepo with the Yarn and Claude Code setup from `seanorepo`. Start a
new repo from it, then add apps.

## What it carries

- **Yarn 4.18.0** in `.yarn/releases`. `.yarnrc.yml` names it in `yarnPath`, so
  any `yarn` on the PATH runs it, even Yarn 1. No corepack.
- **Workspaces:** `apps/*`, `utils/*` and `projects/*`.
- **Biome** (`yarn check`, `yarn fix`), with the seanorepo rules.
- **commitlint and husky.** A commit message must match
  `[TEMPLATE-{n}] {type}: {description}`. `pre-push` warns about a branch name
  that is not `TEMPLATE-{n}/{short-description}`.
- **Claude Code:** `CLAUDE.md`, and `.claude/` with the shared settings, the
  lineage hook, the `ste`, `workflow` and `dispatch` skills, and the Docker
  and ports rules.
- **Requirements:** the `requirements/` checker, with no requirements yet.
- **GitHub:** the issue forms, the Biome and requirements checks, the PR
  labeler and the stale bot.

## Start a new repo

From GitHub, with the template pushed as `seanmizen/template-seanorepo`:

```bash
gh repo create seanmizen/my-repo --template seanmizen/template-seanorepo --private --clone
```

From this checkout, with no GitHub:

```bash
mkdir ../my-repo
git archive HEAD | tar -x -C ../my-repo
git -C ../my-repo init -b main
```

Then, in the new repo:

1. Set `name` and `description` in `package.json`.
2. Change the ticket prefix `TEMPLATE` to your own. This command lists the
   files: `grep -rl TEMPLATE- . --exclude-dir=node_modules`.
3. Run `yarn`. It installs the dependencies and the git hooks.
4. Replace the first paragraph of `CLAUDE.md`.
5. Run `yarn labels` when the GitHub repo exists.

## Yarn

Everything runs from Yarn 4. Put each repeatable task in the `scripts` of the
app's `package.json`. A Go or Zig app gets a `package.json` too, only to run
scripts. Then the root can run every app with `yarn workspaces foreach`.

### Standard Yarn commands

- `yarn start` - the dev server.
- `yarn prod` - a production configuration.
- `yarn start:docker` - hot reload, in a Docker container.
- `yarn prod:docker` - a production configuration, in Docker. A deployment
  server runs this command.

The root `start:docker`, `prod:docker` and `down` scripts run the script of
the same name in every workspace that has one.

### Workspace and Docker hygiene

Name your volumes.
