---
name: workflow
description: The ticket workflow - creating a GitHub issue, starting work on one, opening and merging a PR, resolving a merge conflict. Use whenever you create an issue, branch for a ticket, commit, open a PR, or merge in this repo.
---

# Ticket workflow

Every change has an issue. One issue = one branch = one PR, squash-merged.
The `gh` commands below find the repo from the `origin` remote of the current
checkout.

```
backlog -> ready -> in-progress -> in-review -> merged (the issue auto-closes)
```

The labels track the state. Keep at most 3-5 issues `in-progress` at once, so
parallel agents do not conflict. A new repo has none of these labels. Run
`yarn labels` once to make them.

## 1. Create an issue

Match the form in `.github/ISSUE_TEMPLATE/`: `feature.yml`, `bug.yml` or
`chore.yml`. From the CLI, give the body the same fields:

- **Context** (feature, chore), or **Steps to Reproduce + Expected + Actual** (bug)
- **Acceptance Criteria** - a checklist of done conditions
- **Files Likely Touched**
- **Priority** - `P0` to `P3`

```bash
gh issue create --title "{type}: {summary}" --body-file body.md --label backlog
```

Ready to work now: `--add-label ready --remove-label backlog`.

## 2. Start work

```bash
gh issue edit {n} --add-label in-progress --remove-label ready
git fetch origin
git worktree add -b TEMPLATE-{n}/{short-description} ../{repo}-{n} origin/main
```

`{repo}` is the name of the checkout directory.

- Branch: lowercase, hyphenated, at most 5 words, e.g. `TEMPLATE-42/fix-hover-flicker`.
- Work in the worktree. Never edit the `main` checkout.
- A worktree has no `node_modules`, and the commit hook needs it. Run
  `yarn install` in the worktree. The global Yarn cache makes it fast. Never
  symlink `node_modules` from the main checkout: a tool that deletes through
  the link (for example `next dev` when it cleans `.next`) then deletes files
  in the main checkout.
- Read the acceptance criteria before writing code. For out-of-scope work you
  find, create a new issue. Do not do it on this branch.

## 3. Commit and open the PR

1. `yarn fix` from the root, and `tsc --noEmit` in every TypeScript backend you
   touched. Fix everything.
2. Commit: `[TEMPLATE-{n}] {type}: {description}`. Types: `feat fix chore docs
   refactor test style perf ci`. Never `--no-verify`.
3. Push and open the PR:

```bash
git push -u origin TEMPLATE-{n}/{short-description}
gh pr create --title "[TEMPLATE-{n}] {type}: {description}" \
  --body "Closes #{n}

## Summary
- ...

## Test plan
- [ ] ..."
gh issue edit {n} --add-label in-review --remove-label in-progress
```

## 4. Merge

This is a personal repo, with no human review gate. Check the diff against the
acceptance criteria, then squash-merge your own PR:

```bash
gh pr merge {pr} --squash --delete-branch \
  --subject "[TEMPLATE-{n}] {type}: {description} (#{pr})"
```

Then remove the worktree (`git worktree remove --force ../{repo}-{n}`) and its
local branch.

## Merge conflicts

1. `git status` names the conflicting files.
2. Keep **both** sides' intent. Never discard the other branch's change.
3. `git add` the files, then `git rebase --continue` (or `git merge --continue`).
4. If you cannot tell what the other branch meant, comment on the PR and stop.
   Never force-push over someone else's work.

## Labels

`scripts/labels.sh` makes these labels:

- Priority: `P0` `P1` `P2` `P3`.
- State: `idea` `backlog` `ready` `in-progress` `in-review`.
- Type: `bug` `enhancement` `chore` `infra` `docs` `ci` `regression`.

Give each app a project label too, and add it to `.github/labeler.yml`, so the
labeler marks the PRs that touch the app.

To hand an issue to a background worker agent, use the `dispatch` skill.
