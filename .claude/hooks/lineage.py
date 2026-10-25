#!/usr/bin/env python3
# Where: Claude Code PostToolUse hook, registered in .claude/settings.json.
# When: after each Edit, Write or NotebookEdit tool call.
# Why: an app opts in to lineage tracking with an apps/<app>/LINEAGE.md file.
# When a session touches a path in that app, this hook appends one row for the
# session to LINEAGE.md. A session gets one row only. The hook never blocks.
# Only edits count. A Bash call does not count, because most Bash calls only
# read files.

import json
import os
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone

APP_PATH = re.compile(r"^(.*)/apps/([^/]+)(?:/|$)")


def candidate_paths(event):
    cwd = event.get("cwd") or os.getcwd()
    tool_input = event.get("tool_input") or {}
    raw = [tool_input.get("file_path"), tool_input.get("notebook_path")]
    return [os.path.normpath(os.path.join(cwd, p)) for p in raw if p]


def lineage_files(paths):
    found = {}
    for path in paths:
        match = APP_PATH.match(path)
        if not match:
            continue
        root, app = match.groups()
        lineage = os.path.join(root, "apps", app, "LINEAGE.md")
        if os.path.isfile(lineage):
            found[lineage] = root
    return found


def branch(root):
    result = subprocess.run(
        ["git", "-C", root, "branch", "--show-current"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    return result.stdout.strip() or "(detached)"


def main():
    event = json.load(sys.stdin)
    session = event.get("session_id")
    if not session:
        return
    for lineage, root in lineage_files(candidate_paths(event)).items():
        with open(lineage, encoding="utf-8") as f:
            if session in f.read():
                continue
        seen = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
        host = socket.gethostname().split(".")[0]
        row = f"| `{session}` | {seen} | `{branch(root)}` | {host} |\n"
        with open(lineage, "a", encoding="utf-8") as f:
            f.write(row)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # A lineage failure must not block the session.
        print(f"lineage hook: {error}", file=sys.stderr)
    sys.exit(0)
