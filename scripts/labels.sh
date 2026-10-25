#!/usr/bin/env bash
# Makes the GitHub labels that the workflow skill and the issue forms use.
# GitHub does not copy labels from a template repo, so run this once in each
# new repo. It is safe to run again: --force updates a label that exists.
# Names, colors and descriptions are the same as in seanmizen/seanorepo.
set -euo pipefail

label() {
  gh label create "$1" --color "$2" --description "$3" --force
}

# Priority
label P0 B60205 'Critical — do first'
label P1 D93F0B 'High priority'
label P2 E4E669 'Medium priority'
label P3 D4C5F9 'Low / nice-to-have'

# State
label idea F9D0C4 'Raw brain dump'
label backlog C2E0C6 'Scoped but not ready'
label ready 0E8A16 'Fully specced — agent can start'
label in-progress FBCA04 'Agent actively working'
label in-review 0E8A16 'PR submitted, awaiting review'

# Type
label bug d73a4a "Something isn't working"
label enhancement 84B6EB 'New feature or improvement'
label chore E4E669 'Maintenance / housekeeping'
label infra C5DEF5 'Monorepo-wide tooling / CI'
label docs 0075CA 'Documentation'
label ci ededed ''
label regression B60205 'Introduced a regression'
