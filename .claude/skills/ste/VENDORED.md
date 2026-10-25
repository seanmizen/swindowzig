# Vendored from `danyuchn/asd-ste100-skill`

Source: https://github.com/danyuchn/asd-ste100-skill
Licence: MIT — see `LICENSE`, retained unchanged.
Vendored at: 2026-09-08, upstream commit on `master` as of that date.

## Why we vendored it instead of adding a dependency

ASD-STE100 is copyrighted. `seanorepo` is public. The specification forbids
reproduction "in whole or in part" without written authority from ASD, so we
cannot commit the ~900-word approved dictionary or anything derived from it.

The upstream project solved the same problem the same way: it paraphrases the
rule *categories*, reproduces neither the standard's text nor its dictionary,
and lints only the rules that need no dictionary. We adopt the rules, which are
ideas and not protected, and we skip the word list.

Request the official specification, free, from https://www.asd-ste100.org/ —
reading it is unrestricted. Only copying it is not.

## What we changed

Upstream is kept byte-for-byte except `scripts/ste-lint.py`. Both changes are
marked in that file with a `seanorepo modification` comment.

1. **Lint comments, not code.** Upstream treats every file as prose. On a
   `.tsx` file that reported every semicolon in the TypeScript itself — 22 of
   24 hard findings on `inside-fe/src/components/failure-notice.tsx` came from
   code punctuation, not from anything a person wrote. `extract_prose` blanks
   every character outside a comment while keeping the original positions, so a
   finding still names the right line and column. Markdown is untouched.

2. **`--changed`.** Lints only files that differ from the merge base with
   `main`, so a run costs the same as the branch is large, not as the repo is.
   The merge base and not the branch tip: a stale branch diffed against the tip
   reports files somebody else changed.

`--changed` also skips anything under `.claude/skills/`, because vendored files
stay diffable against upstream and are not ours to rewrite.

## Upstream deviations worth knowing

The skill is STE-*inspired*, not STE-compliant, and one deviation is
deliberate: it never flags `may`, `might` or `could`, on the stated grounds
that confidence is content. ASD-STE100 does not approve those modals.

We keep that deviation. A linter that pressures hedges out of an agent's
writing trades wordiness for overconfidence, and overconfidence is the worse
failure.

## If we change the linter again

Keep the changes marked, keep this file current, and consider sending the
change upstream. `--changed` in particular is not specific to this repo.
