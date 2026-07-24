#!/usr/bin/env bash
# Pre-push agent.
#   1. reviewer (blocking)   — BLOCKS push on error-severity findings.
#   2. pr-description + drift — advisory; generated off the blocking path in the
#      background by pr-describe.sh -> .git/{PR_BODY,DRIFT}.md.
# Whitespace-only and docs-only pushes skip the model entirely.
# Install: ln -sf ../../scripts/pre-push.sh .git/hooks/pre-push
# Bypass:  git push --no-verify
set -euo pipefail
SELF="${BASH_SOURCE[0]}"
# Follow symlink (hooks are symlinked from .git/hooks) to find the real script dir.
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")" && pwd)"
source "$DIR/lib.sh"

# Refresh this repo's lessons from the central library before reviewing.
# Non-fatal: if the library isn't built yet, just proceed with whatever exists.
if [ -x "$DIR/sync-lessons.sh" ]; then
  "$DIR/sync-lessons.sh" >/dev/null 2>&1 || true
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null; then
  RANGE="origin/$BRANCH..HEAD"
else
  RANGE="$(git merge-base HEAD origin/HEAD 2>/dev/null || echo HEAD~1)..HEAD"
fi

DIFF="$(agent_diff "$RANGE")"
[ -z "$DIFF" ] && { echo "pre-push: nothing to review."; exit 0; }

# Skip the model entirely on trivially non-code pushes — a free, instant gate.
if [ -z "$(agent_diff_ws "$RANGE")" ]; then
  echo "pre-push: whitespace-only changes — skipping review."
  exit 0
fi
if agent_only_docs "$RANGE"; then
  echo "pre-push: docs/text-only changes — skipping review."
  exit 0
fi

# Advisory PR description + drift are generated off the blocking path, in a
# detached process, so the push waits only on the small, fast review call.
if [ "${CLAUDE_AGENTS_NO_PR_DESC:-}" != "1" ]; then
  nohup "$DIR/pr-describe.sh" "$RANGE" >/dev/null 2>&1 &
  echo "pre-push: PR description + drift → .git/{PR_BODY,DRIFT}.md (in background)"
fi

echo "pre-push: reviewing $RANGE with $CLAUDE_AGENTS_MODEL ..."
echo "── review ───────────────────────────────────"

# The blocking reviewer (verdict-only, so its output is small and fast) lives in
# lib.sh so `claude-agents review` can reuse it. It fails open on any error.
if run_review "$RANGE"; then
  echo "pre-push: passed."
  exit 0
fi
echo ""
echo "pre-push: BLOCKED — fix the [error] findings above, or: git push --no-verify"
exit 1
