#!/usr/bin/env bash
# Agent: test-guardian. Advisory only — prints, never blocks the commit.
# Install: ln -sf ../../scripts/pre-commit.sh .git/hooks/pre-commit
set -euo pipefail
SELF="${BASH_SOURCE[0]}"
# Follow symlink (hooks are symlinked from .git/hooks) to find the real script dir.
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")" && pwd)"
source "$DIR/lib.sh"

DIFF="$(git diff --cached)"
[ -z "$DIFF" ] && exit 0

PROMPT="You are a test-coverage guardian. Look at this STAGED diff and identify any
new or substantially changed functions/methods that lack corresponding test coverage
in the diff. For each, name it and sketch the one or two test cases that matter most
(happy path + the risky edge). Ignore trivial changes, renames, and pure refactors.
If coverage looks adequate, say so in one line. Be brief; this is advisory.

DIFF:
$DIFF"

echo "── test-guardian (advisory) ─────────────────"
printf '%s' "$PROMPT" | claude -p - --allowedTools "" 2>/dev/null || echo "(test-guardian skipped)"
echo "─────────────────────────────────────────────"
exit 0   # never blocks
