#!/usr/bin/env bash
# Open a PR using the body the pre-push hook already generated (.git/PR_BODY.md).
# Extra args pass through to `gh pr create` (e.g. --title, --base, --draft).
set -euo pipefail
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")" && pwd)"
source "$DIR/lib.sh"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not a git repo" >&2; exit 2; }
BODY="$ROOT/.git/PR_BODY.md"
DRIFT="$ROOT/.git/DRIFT.md"

[ -s "$BODY" ] || { echo "error: no .git/PR_BODY.md yet — it's written on push by the pre-push hook." >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "error: gh (GitHub CLI) not found — install it or open the PR manually with .git/PR_BODY.md" >&2; exit 1; }

if [ -s "$DRIFT" ]; then
  echo "heads-up — architecture drift flagged in the last review:"
  sed 's/^/  /' "$DRIFT"
  echo
fi

exec gh pr create --body-file "$BODY" "$@"
