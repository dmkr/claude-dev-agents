#!/usr/bin/env bash
# Agent: commit-message writer. Drafts a message from the staged diff.
# Install: ln -sf ../../scripts/prepare-commit-msg.sh .git/hooks/prepare-commit-msg
# Git passes: $1=msg file, $2=source (message|template|merge|squash|commit)
set -euo pipefail
SELF="${BASH_SOURCE[0]}"
# Follow symlink (hooks are symlinked from .git/hooks) to find the real script dir.
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")" && pwd)"
source "$DIR/lib.sh"

MSG_FILE="$1"; SOURCE="${2:-}"

# Only draft when the user hasn't supplied their own message (e.g. no -m, no merge).
case "$SOURCE" in
  message|merge|squash|commit) exit 0 ;;
esac
# If the file already has a non-comment line, respect it.
if grep -qvE '^\s*(#.*)?$' "$MSG_FILE" 2>/dev/null; then exit 0; fi

DIFF="$(git diff --cached)"
[ -z "$DIFF" ] && exit 0

DRAFT="$(printf '%s' "You write clean git commit messages. From this staged diff, write a
conventional-commits style message: a concise <=72-char subject line, a blank line,
then 1-3 short bullet points of what changed and why. Output only the message text.

DIFF:
$DIFF" | claude -p - --allowedTools "" 2>/dev/null || true)"

if [ -n "$DRAFT" ]; then
  printf '%s\n\n%s\n' "$DRAFT" "$(cat "$MSG_FILE")" > "$MSG_FILE"
fi
exit 0
