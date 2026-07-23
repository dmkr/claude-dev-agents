#!/usr/bin/env bash
# Combined pre-push agent: one claude call does three jobs.
#   1. reviewer        — BLOCKS push on error-severity findings
#   2. pr-description   — advisory, drafts a PR body -> .git/PR_BODY.md
#   3. drift-watcher    — advisory, checks BOUNDARIES.md
# Install: ln -sf ../../scripts/pre-push.sh .git/hooks/pre-push
# Bypass:  git push --no-verify
set -euo pipefail
SELF="${BASH_SOURCE[0]}"
# Follow symlink (hooks are symlinked from .git/hooks) to find the real script dir.
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")" && pwd)"
source "$DIR/lib.sh"

ROOT="$(agent_root)"

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

DIFF="$(git diff "$RANGE")"
[ -z "$DIFF" ] && { echo "pre-push: nothing to review."; exit 0; }
echo "pre-push: reviewing $RANGE ..."

BRAIN="$(load_brain)"

PROMPT="You are a rigorous staff-level engineer performing three jobs on the diff below.
$BRAIN

Return ONLY a JSON object, no markdown fences:
{
  \"review\": {
    \"findings\": [{\"severity\":\"error|warning|suggestion\",\"file\":\"\",\"line\":0,\"rule\":\"\",\"comment\":\"\"}],
    \"verdict\": \"block|pass\"
  },
  \"pr_description\": \"markdown PR body: summary, key changes, test notes\",
  \"drift\": {
    \"violations\": [{\"file\":\"\",\"comment\":\"\"}]
  }
}
Rules:
- review.severity 'error' ONLY for things that must block a push: bugs, security,
  data loss, broken contracts, or a repeat of a listed past lesson.
- review.verdict is 'block' iff any finding is 'error'.
- drift.violations: only where the diff crosses an intended module boundary above.
  If no boundaries were provided or none crossed, return an empty array.
Be concise.

DIFF:
$DIFF"

RAW="$(printf '%s' "$PROMPT" | claude_json)"

if ! is_json "$RAW"; then
  echo "pre-push: reviewer output unparseable; allowing push."
  echo "$RAW"; exit 0
fi

# ---- reviewer (blocking) ----
echo "── review ───────────────────────────────────"
echo "$RAW" | jq -r '.review.findings[]? | "  [\(.severity)] \(.file):\(.line) — \(.rule): \(.comment)"'

# ---- drift (advisory) ----
DRIFT_N="$(echo "$RAW" | jq '.drift.violations | length')"
if [ "$DRIFT_N" -gt 0 ]; then
  echo "── architecture drift (advisory) ────────────"
  echo "$RAW" | jq -r '.drift.violations[] | "  \(.file): \(.comment)"'
fi

# ---- pr description (advisory) -> file ----
echo "$RAW" | jq -r '.pr_description // empty' > "$ROOT/.git/PR_BODY.md"
if [ -s "$ROOT/.git/PR_BODY.md" ]; then
  echo "── pr description written to .git/PR_BODY.md ─"
  echo "  gh pr create --body-file .git/PR_BODY.md"
fi

# ---- verdict ----
if [ "$(echo "$RAW" | jq -r '.review.verdict')" = "block" ]; then
  echo ""
  echo "pre-push: BLOCKED — fix the [error] findings above, or: git push --no-verify"
  exit 1
fi
echo "pre-push: passed."
exit 0
