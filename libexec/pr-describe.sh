#!/usr/bin/env bash
# Advisory PR-description + architecture-drift generator. pre-push.sh runs this
# in the background so its (large) markdown output never blocks the push.
# Writes .git/PR_BODY.md and, when boundaries are crossed, .git/DRIFT.md.
# Args: <range>  (e.g. origin/main..HEAD)
set -euo pipefail
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")" && pwd)"
source "$DIR/lib.sh"

RANGE="${1:?usage: pr-describe.sh <range>}"
ROOT="$(agent_root)"
DIFF="$(agent_diff "$RANGE")"
[ -z "$DIFF" ] && exit 0

BRAIN="$(load_brain)"

PROMPT="You are a staff-level engineer. From the diff below, produce two things.
$BRAIN

Return ONLY a JSON object, no markdown fences:
{
  \"pr_description\": \"markdown PR body: summary, key changes, test notes\",
  \"drift\": { \"violations\": [{\"file\":\"\",\"comment\":\"\"}] }
}
Rules:
- drift.violations: only where the diff crosses an intended module boundary above.
  If no boundaries were provided or none crossed, return an empty array.
Be concise.

DIFF:
$DIFF"

RAW="$(printf '%s' "$PROMPT" | claude_json)"
is_json "$RAW" || exit 0

echo "$RAW" | jq -r '.pr_description // empty' > "$ROOT/.git/PR_BODY.md"

DRIFT="$(echo "$RAW" | jq -r '.drift.violations[]? | "- \(.file): \(.comment)"')"
if [ -n "$DRIFT" ]; then
  printf 'Architecture drift (advisory):\n%s\n' "$DRIFT" > "$ROOT/.git/DRIFT.md"
else
  rm -f "$ROOT/.git/DRIFT.md"
fi
