#!/usr/bin/env bash
# Agent: codebase Q&A. On-demand, not a hook.
# Usage: ask "where do we validate auth tokens?"
# Symlink onto PATH:  ln -sf "$PWD/scripts/ask.sh" ~/.local/bin/ask
set -euo pipefail
Q="$*"
[ -z "$Q" ] && { echo "usage: ask \"your question about this codebase\""; exit 1; }

# Let Claude read the repo to answer. Read-only tools.
claude -p "Answer this question about the current codebase. Cite the specific files
and functions involved. If you're unsure, say what you'd need to check.

Question: $Q" \
  --allowedTools "Read,Grep,Glob"
