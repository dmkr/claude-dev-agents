#!/usr/bin/env bash
# Shared helpers for the local agent hooks. Sourced by the others.
set -euo pipefail

agent_root()   { git rev-parse --show-toplevel; }
agent_brain()  { echo "$(agent_root)/.claude/review"; }

# Concatenate whichever brain files exist, each under a labelled heading.
load_brain() {
  local d; d="$(agent_brain)"
  local out=""
  [ -f "$d/STYLE_GUIDE.md" ] && out+=$'\n## Team style guide\n'"$(cat "$d/STYLE_GUIDE.md")"
  [ -f "$d/LESSONS.md" ]     && out+=$'\n## Lessons from past PRs (do not repeat)\n'"$(cat "$d/LESSONS.md")"
  [ -f "$d/BOUNDARIES.md" ]  && out+=$'\n## Intended architecture / module boundaries\n'"$(cat "$d/BOUNDARIES.md")"
  printf '%s' "$out"
}

# Run claude headless, no tools, return raw text result. Args: prompt via stdin.
claude_json() {
  claude -p - --allowedTools "" --output-format json 2>/dev/null \
    | jq -r '.result // empty' \
    | sed 's/```json//g; s/```//g'
}

# True if $1 is valid JSON.
is_json() { echo "$1" | jq empty 2>/dev/null; }
