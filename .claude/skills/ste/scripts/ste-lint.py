#!/usr/bin/env python3
"""Deterministic linter for the structural STE rules in SKILL.md.

Checks only rules verifiable without ASD's dictionary. Deliberately never
flags hedges or modality (may/might/could): the skill treats confidence as
content, and a linter that pressures hedges out would rewrite claims.

Usage:
    ste-lint.py FILE [FILE ...]
    echo "text" | ste-lint.py [--json]
    ste-lint.py --baseline 5 FILE      # pass unless hard violations exceed 5
    ste-lint.py --disable passive-voice,present-perfect FILE
    ste-lint.py --selftest

Exit 1 when hard ("advisory-free") violations exceed the baseline (default 0).
Advisory findings (passive voice, compound tenses) never fail the run.
"""
import json
import os
import re
import subprocess
import sys

# ponytail: regex heuristics, not a parser. No noun-cluster rule — needs POS
# tagging to avoid constant false positives; add spaCy-backed rule if ever needed.
# No ellipsis rule by owner's choice: technical writing sometimes earns one.
RULES = [
    ("semicolon", "advisory-free",
     re.compile(r";"),
     "STE bans the semicolon (Rule 8.1). Split into separate sentences."),
    ("phrasal-verb", "advisory-free",
     re.compile(r"\b(spin(?:ning|s)? up|spun up|reach(?:ing|es|ed)? out|div(?:e|es|ing|ed) into|dove into|kick(?:ing|s|ed)? off|circl(?:e|es|ing|ed) back|touch(?:ing|es|ed)? base)\b", re.I),
     "Soft phrasal verb. Use the single plain verb (start, contact, read, begin)."),
    ("marketing-adjective", "advisory-free",
     re.compile(r"\b(seamless(?:ly)?|robust(?:ly)?|cutting-edge|effortless(?:ly)?|blazing[- ]fast|world-class|state-of-the-art|game-chang(?:ing|er))\b", re.I),
     "Marketing adjective. Delete, or replace with the measurement that earns the claim."),
    ("nominalization", "advisory-free",
     re.compile(r"\b(perform|performs|performed|conduct|conducts|conducted|carry out|carries out|carried out)\s+(?:a|an|the)\s+\w+(?:tion|sion|ment|ance|ence|ysis)\b", re.I),
     "Action frozen into a noun. Use the verb (analyze, not perform an analysis of)."),
    ("passive-voice", "advisory",
     re.compile(r"\b(is|are|was|were|been|being)\s+(\w+ed|given|taken|made|done|found|seen|known|shown|written|built|sent|set|run|read|kept|held|left|put)\b(?!\s+(?:to|for|by)\s+\w+ing)", re.I),
     "Possible passive voice. Name the actor and use an active verb, unless the actor is unknown or irrelevant."),
    ("present-perfect", "advisory",
     # modal + perfect infinitive ("may have failed") is a protected hedge, not present perfect
     re.compile(r"(?<!\bmay )(?<!\bmight )(?<!\bcould )(?<!\bshould )(?<!\bwould )(?<!\bmust )\b(has|have|had)\s+(?:been\s+)?\w+(?:ed|en)\b", re.I),
     "Compound tense. Use simple past/present unless current relevance is the point (then keep and flag)."),
]

# seanorepo modification: advisory, not blocking.
#
# We read all 25 hits across apps/inside before changing anything. About 21 were
# false positives, because the rule matches any inflection and knows no part of
# speech. It paired "the leading-slash check" (a noun) with "validate" (a verb),
# the route path "/verify" with "check", the SQL words DELETE and CHECK with our
# prose, and "the upload path gets a longer deadline" (receives) with "fetch".
#
# Upstream already set this precedent: the noun-cluster rule is absent with the
# comment "needs POS tagging to avoid constant false positives". This rule has
# the same defect. It still reports, so a real rotation is still visible, but it
# no longer fails a build and no longer pressures anyone into rewriting correct
# prose to quiet a heuristic.
#
# One word, one meaning: groups of verbs commonly rotated for the same action.
# Only pairs where the members are genuinely interchangeable — error/fault/failure
# are distinct concepts and stay out.
SYNONYM_GROUPS = [
    ("check", "verify", "confirm", "validate"),
    ("delete", "remove", "erase"),
    ("start", "launch", "begin", "initiate"),
    ("stop", "halt", "terminate"),
    ("show", "display"),
    ("use", "utilize", "employ"),
    ("fix", "repair", "correct"),
    ("send", "transmit"),
    ("get", "retrieve", "fetch", "obtain"),
    ("change", "modify", "alter"),
]

MAX_WORDS = 25  # descriptions cap; instructions cap is 20 but undetectable without context

CODE_FENCE = re.compile(r"^(```|~~~)")
INLINE_CODE = re.compile(r"`[^`]*`")

# --- seanorepo modification: lint comments, not code -------------------------
#
# Upstream treats every file as prose. On a .tsx file that reports every
# semicolon in the TypeScript itself: 22 of 24 hard findings on
# inside-fe/src/components/failure-notice.tsx came from code punctuation.
#
# We blank everything that is not a comment, keeping the original character
# positions, so line and column in a finding still point at the real source.
# Regex heuristics, not a parser -- the same trade upstream already makes.

BLOCK = ("/*", "*/")
SOURCE_COMMENTS = {
    ".ts": ("//", BLOCK), ".tsx": ("//", BLOCK), ".mts": ("//", BLOCK),
    ".js": ("//", BLOCK), ".jsx": ("//", BLOCK), ".mjs": ("//", BLOCK),
    ".cjs": ("//", BLOCK), ".go": ("//", BLOCK), ".css": (None, BLOCK),
    ".sql": ("--", BLOCK), ".py": ("#", None), ".sh": ("#", None),
    ".yml": ("#", None), ".yaml": ("#", None),
}
PROSE_EXTS = {".md", ".markdown", ".txt", ""}

# Vendored upstream content. We keep it byte-for-byte so it stays diffable
# against the source repo, so it is not ours to rewrite.
VENDORED = (".claude/skills/",)
LINTABLE = set(SOURCE_COMMENTS) | PROSE_EXTS

# A JSDoc line reads "* The retry is a real control." The marker is not a word.
JSDOC_STAR = re.compile(r"^(\s*)\*+(\s|$)")


def _skip_string(line, i):
    """Index just past the string literal that starts at i."""
    quote = line[i]
    i += 1
    while i < len(line):
        if line[i] == "\\":
            i += 2
            continue
        if line[i] == quote:
            return i + 1
        i += 1
    return len(line)


def extract_prose(text, filename):
    """Blank every character that is not inside a comment. Markdown is untouched."""
    ext = os.path.splitext(filename)[1].lower()
    if ext not in SOURCE_COMMENTS:
        return text
    line_tok, block = SOURCE_COMMENTS[ext]
    allow_triple = ext == ".py"

    out, in_block, in_triple = [], False, None
    for line in text.split("\n"):
        buf = [" "] * len(line)
        i, n = 0, len(line)
        while i < n:
            if in_block:
                end = line.find(block[1], i)
                stop = n if end == -1 else end
                for k in range(i, stop):
                    buf[k] = line[k]
                if end == -1:
                    i = n
                else:
                    i, in_block = end + len(block[1]), False
                continue
            if in_triple:
                end = line.find(in_triple, i)
                stop = n if end == -1 else end
                for k in range(i, stop):
                    buf[k] = line[k]
                if end == -1:
                    i = n
                else:
                    i, in_triple = end + 3, None
                continue
            ch = line[i]
            if allow_triple and ch in "'\"" and line.startswith(ch * 3, i):
                in_triple = ch * 3
                i += 3
                continue
            if ch in "'\"`":
                # A URL or a regex inside a string is not a comment.
                i = _skip_string(line, i)
                continue
            # `\//` closes a regex literal, it does not open a comment.
            # /localhost:4160\// was read as code plus a comment, and the
            # linter then reported the statement's own semicolon as prose.
            if (line_tok and line.startswith(line_tok, i)
                    and not (i > 0 and line[i - 1] == "\\")):
                for k in range(i + len(line_tok), n):
                    buf[k] = line[k]
                i = n
                continue
            if block and line.startswith(block[0], i):
                in_block = True
                i += len(block[0])
                continue
            i += 1
        out.append(JSDOC_STAR.sub(lambda m: m.group(1) + " " + m.group(2), "".join(buf)))
    return "\n".join(out)


def _git(args):
    try:
        r = subprocess.run(["git"] + args, capture_output=True, text=True, check=False)
    except OSError:
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def changed_files(scopes):
    """Files that differ from the merge base with main, filtered to `scopes`.

    The merge base, not the branch tip: a stale branch diffed against the tip
    reports every file somebody else changed, which is not this branch's work.
    """
    base = _git(["merge-base", "HEAD", "origin/main"]) or _git(["merge-base", "HEAD", "main"])
    if not base:
        # "Nothing changed" and "I could not work out what changed" are different
        # answers, and a shallow clone produces the second while looking like the
        # first. A check that cannot determine its own scope must not pass.
        print("ste-lint: no merge base with main. Fetch full history "
              "(actions/checkout fetch-depth: 0).", file=sys.stderr)
        raise SystemExit(2)
    names = set()
    names |= set(_git(["diff", "--name-only", base]).splitlines())
    names |= set(_git(["diff", "--name-only", "HEAD"]).splitlines())
    names |= set(_git(["ls-files", "--others", "--exclude-standard"]).splitlines())

    picked = []
    for name in sorted(n for n in names if n):
        if scopes and not any(name == s or name.startswith(s.rstrip("/") + "/") for s in scopes):
            continue
        if name.startswith(VENDORED):
            continue
        if os.path.splitext(name)[1].lower() not in LINTABLE:
            continue
        if os.path.isfile(name):
            picked.append(name)
    return picked

# --- end seanorepo modification ----------------------------------------------


def _word_re(base):
    return re.compile(r"\b" + base + r"(?:s|es|ed|d|ing)?\b", re.I)


def lint(text, filename="<stdin>"):
    text = extract_prose(text, filename)
    findings = []
    words_total = 0
    in_fence = False
    # first occurrence of each synonym-group member: (group_idx, base) -> (line, col, match)
    seen_synonyms = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        if CODE_FENCE.match(line.strip()):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        line = INLINE_CODE.sub("", line)
        words_total += len(line.split())
        for rule_id, level, pattern, msg in RULES:
            for m in pattern.finditer(line):
                findings.append({"file": filename, "line": lineno, "col": m.start() + 1,
                                 "rule": rule_id, "level": level,
                                 "match": m.group(0), "message": msg})
        for gi, group in enumerate(SYNONYM_GROUPS):
            for base in group:
                if (gi, base) in seen_synonyms:
                    continue
                m = _word_re(base).search(line)
                if m:
                    seen_synonyms[(gi, base)] = (lineno, m.start() + 1, m.group(0))
        for sent in re.split(r"(?<=[.!?])\s+", line):
            n = len(sent.split())
            if n > MAX_WORDS:
                findings.append({"file": filename, "line": lineno, "col": 1,
                                 "rule": "long-sentence", "level": "advisory-free",
                                 "match": f"{n} words",
                                 "message": f"Sentence has {n} words (cap {MAX_WORDS}). Split it."})
    # synonym rotation: flag each member after the first, at its first occurrence
    for gi, group in enumerate(SYNONYM_GROUPS):
        present = [(seen_synonyms[(gi, b)], b) for b in group if (gi, b) in seen_synonyms]
        if len(present) > 1:
            present.sort()  # document order
            first_base = present[0][1]
            for (lineno, col, match), base in present[1:]:
                findings.append({"file": filename, "line": lineno, "col": col,
                                 "rule": "synonym-rotation", "level": "advisory",
                                 "match": match,
                                 "message": f"'{base}' and '{first_base}' name the same action. Pick one and use it every time."})
    findings.sort(key=lambda f: (f["line"], f["col"]))
    return findings, words_total


def report(findings, words_total, as_json, hard_count, baseline):
    rate = round(len(findings) * 100 / words_total, 1) if words_total else 0.0
    if as_json:
        print(json.dumps({"violations": findings, "count": len(findings),
                          "hard_count": hard_count, "baseline": baseline,
                          "words": words_total, "per_100_words": rate}, indent=2))
        return
    for f in findings:
        print(f"{f['file']}:{f['line']}:{f['col']} {f['rule']}: {f['message']} [{f['match']}]")
    print(f"\n{len(findings)} violations ({hard_count} hard, baseline {baseline}), "
          f"{words_total} words, {rate} per 100 words")
    print("Hedges/modality (may, might, could) are never flagged: confidence is content.")


def selftest():
    bad = ("The panel is removed; spin up the job. "
           "Perform an analysis of the seamless log. "
           "We have received the report.")
    findings, _ = lint(bad)
    rules = {f["rule"] for f in findings}
    for expected in ("semicolon", "phrasal-verb", "nominalization",
                     "marketing-adjective", "passive-voice", "present-perfect"):
        assert expected in rules, expected
    # hedges must never be flagged, including modal + perfect infinitive
    findings, _ = lint("The request may have failed. It could be a timeout. "
                       "The disk might have filled.")
    assert findings == [], findings
    # code blocks skipped
    findings, _ = lint("```\nx = a; y = b\n```")
    assert findings == []
    findings, _ = lint(("word " * 30).strip() + ".")
    assert any(f["rule"] == "long-sentence" for f in findings)
    # synonym rotation: second member flagged, first named as the keeper
    findings, _ = lint("Check the config file. Then verify the output. Verify twice.")
    rot = [f for f in findings if f["rule"] == "synonym-rotation"]
    assert len(rot) == 1 and "'verify' and 'check'" in rot[0]["message"], rot
    # single consistent term: no flag
    findings, _ = lint("Check the config. Check the output.")
    assert not any(f["rule"] == "synonym-rotation" for f in findings)
    # per-file labels
    findings, _ = lint("a; b", filename="x.md")
    assert findings[0]["file"] == "x.md"
    # source files: comments are prose, code is not
    tsx = "const a = 1;\n// The panel is removed; do a test.\nconst b = 2;\n"
    findings, _ = lint(tsx, filename="x.tsx")
    semis = [f for f in findings if f["rule"] == "semicolon"]
    assert len(semis) == 1, semis
    assert semis[0]["line"] == 2, semis            # line numbers survive extraction
    assert semis[0]["col"] == 24, semis            # and so do columns

    # a URL in a string is not a comment
    findings, _ = lint('const u = "https://x.example/a;b";\n', filename="x.ts")
    assert findings == [], findings

    # a regex literal ending \// is not a comment either
    findings, _ = lint("await expect(p).toHaveURL(/host:4160\\//);\n", filename="x.ts")
    assert findings == [], findings

    # block comments, JSDoc stars stripped so the marker is not counted as a word
    doc = "/**\n * We have received the report.\n */\nconst x = 1;\n"
    findings, words = lint(doc, filename="x.ts")
    assert any(f["rule"] == "present-perfect" for f in findings), findings
    assert words == 5, words

    # python docstrings are prose, python code is not
    py = 'def f():\n    """Perform an analysis of the log."""\n    return 1\n'
    assert any(f["rule"] == "nominalization" for f in lint(py, filename="x.py")[0])

    # markdown is untouched by extraction
    assert extract_prose("a; b", "x.md") == "a; b"

    _selftest_changed()
    print("selftest OK")


def _selftest_changed():
    """changed_files against a throwaway repository.

    Builds real history rather than mocking git: the rule under test is which
    commits the merge base picks, and a mock would only assert our own belief
    about that.
    """
    import shutil
    import tempfile

    if not shutil.which("git"):
        return
    here = os.getcwd()
    tmp = tempfile.mkdtemp(prefix="ste-selftest-")
    try:
        os.chdir(tmp)
        _git(["init", "-q", "-b", "main"])
        _git(["config", "user.email", "t@t"])
        _git(["config", "user.name", "t"])
        open("base.md", "w").write("base\n")
        _git(["add", "-A"])
        _git(["commit", "-qm", "base"])

        # main moves on after the branch point, CHANGING a file that also exists
        # on the branch. A file that only exists on main would be filtered out by
        # the isfile check instead, and the assertion below would pass whether or
        # not we used the merge base — a test that cannot fail for the right
        # reason (REQ-QUALITY-001).
        _git(["checkout", "-qb", "work"])
        _git(["checkout", "-q", "main"])
        open("base.md", "w").write("base, edited by somebody else\n")
        _git(["add", "-A"])
        _git(["commit", "-qm", "elsewhere"])

        _git(["checkout", "-q", "work"])
        open("mine.md", "w").write("mine\n")
        _git(["add", "-A"])
        _git(["commit", "-qm", "mine"])
        open("untracked.md", "w").write("untracked\n")
        os.makedirs("app", exist_ok=True)
        open("app/scoped.md", "w").write("scoped\n")
        open("skip.bin", "w").write("binary\n")

        got = set(changed_files([]))
        assert "mine.md" in got, got
        assert "untracked.md" in got, got
        assert "base.md" not in got, got       # merge base, not the branch tip
        assert "skip.bin" not in got, got       # extension filter

        assert set(changed_files(["app"])) == {"app/scoped.md"}, changed_files(["app"])
        assert changed_files(["nothing-here"]) == []
    finally:
        os.chdir(here)
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    as_json = "--json" in argv
    only_changed = False
    baseline = 0
    disabled = set()
    paths = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--baseline":
            i += 1
            baseline = int(argv[i])
        elif a == "--disable":
            i += 1
            disabled = set(argv[i].split(","))
        elif a == "--changed":
            only_changed = True
        elif not a.startswith("--"):
            paths.append(a)
        i += 1

    if only_changed:
        scope_note = ", ".join(paths) if paths else "the whole repo"
        paths = changed_files(paths)
        if not paths:
            if not as_json:
                print(f"no changed files to lint (compared against {scope_note})")
            else:
                print(json.dumps({"violations": [], "count": 0, "hard_count": 0,
                                  "baseline": baseline, "words": 0, "per_100_words": 0.0}))
            return 0

    findings, words_total = [], 0
    if paths:
        for p in paths:
            f, w = lint(open(p, encoding="utf-8").read(), filename=p)
            findings.extend(f)
            words_total += w
    else:
        findings, words_total = lint(sys.stdin.read())

    findings = [f for f in findings if f["rule"] not in disabled]
    hard_count = sum(1 for f in findings if f["level"] == "advisory-free")
    report(findings, words_total, as_json, hard_count, baseline)
    return 1 if hard_count > baseline else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
