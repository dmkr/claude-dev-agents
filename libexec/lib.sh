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

# Blocking hooks default to Haiku (the fastest model) for latency; override with
# CLAUDE_AGENTS_MODEL for a stronger review. CLAUDE_AGENTS_TIMEOUT caps the call
# so a slow/hung model (e.g. an always-thinking one on a big diff) can't stall
# a push — on timeout the hook fails open, same as any other model error.
CLAUDE_AGENTS_MODEL="${CLAUDE_AGENTS_MODEL:-claude-haiku-4-5}"
CLAUDE_AGENTS_TIMEOUT="${CLAUDE_AGENTS_TIMEOUT:-90}"

# Run "$@" with a wall-clock limit (seconds), returning its stdout. Prefers
# coreutils timeout/gtimeout; falls back to a portable background-and-kill so it
# works on a stock macOS. The child writes to a temp file, never the caller's
# capture pipe — so if the kill orphans a grandchild, the caller is not blocked.
run_timeout() {
  local secs="$1"; shift
  if command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  local tmp; tmp="$(mktemp)"
  "$@" >"$tmp" 2>/dev/null &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local timer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$timer" 2>/dev/null; wait "$timer" 2>/dev/null || true
  cat "$tmp"; rm -f "$tmp"
  return "$rc"
}

# Run claude headless, no tools, return raw text result (fail-open: any error,
# non-JSON, or timeout yields empty output, never a non-zero exit). Prompt via stdin.
claude_json() {
  local out
  out="$(run_timeout "$CLAUDE_AGENTS_TIMEOUT" \
        claude -p - --model "$CLAUDE_AGENTS_MODEL" --allowedTools "" --output-format json 2>/dev/null)" || true
  # `|| true` is load-bearing: on a timeout or error, `out` is empty/partial and
  # jq exits non-zero; without this the hooks (under `set -e`) would abort and
  # fail CLOSED. Fail open — emit whatever parsed (often nothing) and return 0.
  printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null | sed 's/```json//g; s/```//g' || true
}

# True if $1 is valid JSON.
is_json() { echo "$1" | jq empty 2>/dev/null; }

# Run the blocking reviewer over a diff spec (a range like origin/main..HEAD, a
# ref like HEAD, or --cached). Prints findings. Returns 1 only when the verdict
# is 'block'; empty/unparseable output fails open (returns 0). Args: <spec>.
run_review() {
  local spec="$1" diff brain prompt raw
  diff="$(agent_diff "$spec")"
  [ -z "$diff" ] && { echo "  (nothing to review)"; return 0; }
  brain="$(load_brain)"
  prompt="You are a rigorous staff-level engineer reviewing the diff below.
$brain

Return ONLY a JSON object, no markdown fences:
{\"findings\":[{\"severity\":\"error|warning|suggestion\",\"file\":\"\",\"line\":0,\"rule\":\"\",\"comment\":\"\"}],\"verdict\":\"block|pass\"}
Rules:
- severity 'error' ONLY for things that must block a push: bugs, security,
  data loss, broken contracts, or a repeat of a listed past lesson.
- verdict is 'block' iff any finding is 'error'.
- Report at most the 12 most severe findings. Be concise.

DIFF:
$diff"
  raw="$(printf '%s' "$prompt" | claude_json)"
  if ! is_json "$raw"; then
    echo "  reviewer output unparseable — allowing."
    return 0
  fi
  echo "$raw" | jq -r '.findings[]? | "  [\(.severity)] \(.file):\(.line) — \(.rule): \(.comment)"'
  [ "$(echo "$raw" | jq -r '.verdict')" = "block" ] && return 1 || return 0
}
