#!/usr/bin/env bash
# On-demand reviewer — the pre-push gate without the push.
# Usage:
#   review.sh                 review uncommitted changes (working tree vs HEAD)
#   review.sh --staged        review only staged changes
#   review.sh <range>         review a range, e.g. origin/main..HEAD
# Exit 1 if the reviewer would block (error-severity findings), else 0.
set -euo pipefail
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")" && pwd)"
source "$DIR/lib.sh"

git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "error: not a git repo" >&2; exit 2; }

case "${1:-}" in
  --staged|--cached) SPEC="--cached"; LABEL="staged changes" ;;
  "")                SPEC="HEAD";     LABEL="uncommitted changes" ;;
  *)                 SPEC="$1";       LABEL="$1" ;;
esac

echo "reviewing $LABEL with $CLAUDE_AGENTS_MODEL_LABEL ..."
echo "── review ───────────────────────────────────"
if run_review "$SPEC"; then
  echo "review: pass"
else
  echo ""
  echo "review: BLOCK — error-severity findings above"
  exit 1
fi
