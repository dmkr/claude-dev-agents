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

# Paths excluded from review: generated, vendored, lock, and minified files.
# One source of truth so agent_diff and its variants stay in sync.
AGENT_DIFF_EXCLUDES=(
  ':(exclude)*.lock' ':(exclude)*-lock.json' ':(exclude)*.lock.json'
  ':(exclude)go.sum' ':(exclude)*.min.js' ':(exclude)*.min.css'
  ':(exclude)*.map' ':(exclude)vendor/**' ':(exclude)node_modules/**'
  ':(exclude)dist/**' ':(exclude)build/**' ':(exclude)*.snap'
)

# Emit the review diff for a range: reviewable files only, capped in size so a
# huge push can't stall the gate. Truncation is noted on stderr (stdout stays
# the diff). Args: <range>.
agent_diff() {
  local range="$1" cap="${CLAUDE_AGENTS_DIFF_CAP:-120000}" diff
  diff="$(git diff "$range" -- . "${AGENT_DIFF_EXCLUDES[@]}")"
  if [ "${#diff}" -gt "$cap" ]; then
    printf '  \033[33m!\033[0m diff truncated to %s chars for review speed\n' "$cap" >&2
    diff="${diff:0:$cap}"$'\n\n[diff truncated at '"$cap"' chars]'
  fi
  printf '%s' "$diff"
}

# Reviewable diff ignoring all whitespace. Empty output => the change is
# whitespace-only and safe to skip. Args: <range>.
agent_diff_ws() {
  git diff -w "$1" -- . "${AGENT_DIFF_EXCLUDES[@]}"
}

# True when every changed reviewable file is documentation/text. Args: <range>.
agent_only_docs() {
  local files f
  files="$(git diff --name-only "$1" -- . "${AGENT_DIFF_EXCLUDES[@]}")"
  [ -n "$files" ] || return 1
  while IFS= read -r f; do
    case "$f" in
      *.md|*.markdown|*.rst|*.txt|*.adoc) ;;
      LICENSE|LICENSE.*|NOTICE|AUTHORS|CHANGELOG|CHANGELOG.*) ;;
      docs/*|*/docs/*) ;;
      *) return 1 ;;
    esac
  done <<< "$files"
  return 0
}

# Run claude headless, no tools, return raw text result. Args: prompt via stdin.
# The blocking hooks default to Haiku (the fastest model) for latency; override
# with CLAUDE_AGENTS_MODEL to trade speed for a stronger review.
CLAUDE_AGENTS_MODEL="${CLAUDE_AGENTS_MODEL:-claude-haiku-4-5}"
claude_json() {
  claude -p - --model "$CLAUDE_AGENTS_MODEL" --allowedTools "" --output-format json 2>/dev/null \
    | jq -r '.result // empty' \
    | sed 's/```json//g; s/```//g'
}

# True if $1 is valid JSON.
is_json() { echo "$1" | jq empty 2>/dev/null; }
