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
#
# `claude-haiku-4-5` is a first-party id. On Bedrock/Vertex the id is provider-
# and account-specific (e.g. global.anthropic.claude-haiku-4-5-20251001-v1:0),
# so the first-party default would fail — and because these hooks fail open, it
# would look exactly like a clean review rather than an error. So: prefer an
# explicit override, then whatever small/fast model Claude Code is configured
# with, and on a provider backend with neither, pass no --model at all and let
# Claude Code pick a valid id itself. Guessing a provider id is not an option.
#
# `claude-agents setup` probes for a working id and writes it to the config file
# below, which is why the file is read before any of the fallbacks apply. The
# file also survives the environment git hooks *don't* inherit — a GUI client
# never sources ~/.zshrc, so an exported var alone silently reverts to default.
CLAUDE_AGENTS_CONFIG="${CLAUDE_AGENTS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-agents/config}"

# Read env.<KEY> from Claude Code's settings files, later file winning. Bedrock
# and Vertex are usually configured *there* rather than exported in the shell,
# so a shell-env-only check silently concludes "first-party" and then probes ids
# that cannot work on this account. Args: <KEY>.
claude_setting_env() {
  local key="$1" f v val=""
  for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
           ".claude/settings.json" ".claude/settings.local.json"; do
    [ -r "$f" ] || continue
    v="$(jq -r --arg k "$key" '.env[$k] // empty' "$f" 2>/dev/null)" || continue
    [ -n "$v" ] && val="$v"
  done
  printf '%s' "$val"
}

# Shell env first, then Claude Code's settings. "0"/"false" count as off.
claude_env_or_setting() {
  local key="$1" v
  eval "v=\"\${$key:-}\""
  [ -z "$v" ] && v="$(claude_setting_env "$key")"
  case "$v" in 0|false|False|FALSE) v="" ;; esac
  printf '%s' "$v"
}

# bedrock | vertex | first_party
agents_backend() {
  if   [ -n "$(claude_env_or_setting CLAUDE_CODE_USE_BEDROCK)" ]; then echo bedrock
  elif [ -n "$(claude_env_or_setting CLAUDE_CODE_USE_VERTEX)"  ]; then echo vertex
  else echo first_party; fi
}

# Set-but-empty and unset are different answers here: an empty value is setup's
# way of recording "this backend only works with Claude Code's own default, so
# pass no --model". Falling through to the id-guessing below in that case would
# reintroduce exactly the 404 setup just probed its way around — so track
# whether the value was *defined* (${x+y}), not whether it is non-empty.
_ca_env_defined="${CLAUDE_AGENTS_MODEL+yes}"
_ca_env_value="${CLAUDE_AGENTS_MODEL:-}"
if [ -r "$CLAUDE_AGENTS_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$CLAUDE_AGENTS_CONFIG"
fi
# Environment beats the file.
[ -n "$_ca_env_defined" ] && CLAUDE_AGENTS_MODEL="$_ca_env_value"

if [ -z "${CLAUDE_AGENTS_MODEL+yes}" ]; then
  CLAUDE_AGENTS_MODEL="$(claude_env_or_setting ANTHROPIC_DEFAULT_HAIKU_MODEL)"
  [ -z "$CLAUDE_AGENTS_MODEL" ] \
    && CLAUDE_AGENTS_MODEL="$(claude_env_or_setting ANTHROPIC_SMALL_FAST_MODEL)"
  # Only the first-party backend has an id we can safely assume.
  if [ -z "$CLAUDE_AGENTS_MODEL" ] && [ "$(agents_backend)" = "first_party" ]; then
    CLAUDE_AGENTS_MODEL="claude-haiku-4-5"
  fi
fi
unset _ca_env_defined _ca_env_value

# An empty model means "let Claude Code decide" — omit the flag entirely rather
# than passing --model "". Built as an array so the empty case adds no argument.
CLAUDE_AGENTS_MODEL_ARGS=()
CLAUDE_AGENTS_MODEL_LABEL="Claude Code's default model"
if [ -n "$CLAUDE_AGENTS_MODEL" ]; then
  CLAUDE_AGENTS_MODEL_ARGS=(--model "$CLAUDE_AGENTS_MODEL")
  CLAUDE_AGENTS_MODEL_LABEL="$CLAUDE_AGENTS_MODEL"
fi

CLAUDE_AGENTS_TIMEOUT="${CLAUDE_AGENTS_TIMEOUT:-90}"

# Run "$@" with a wall-clock limit (seconds), returning its stdout. Prefers
# coreutils timeout/gtimeout; falls back to a portable background-and-kill so it
# works on a stock macOS. The child writes to a temp file, never the caller's
# capture pipe — so if the kill orphans a grandchild, the caller is not blocked.
# The explicit `<&0` is load-bearing: a non-interactive shell assigns /dev/null
# to an async command's stdin unless stdin is redirected explicitly, which would
# silently feed the model an empty prompt (callers pipe the prompt in on stdin).
run_timeout() {
  local secs="$1"; shift
  if command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  local tmp; tmp="$(mktemp)"
  "$@" <&0 >"$tmp" 2>/dev/null &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local timer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$timer" 2>/dev/null; wait "$timer" 2>/dev/null || true
  cat "$tmp"; rm -f "$tmp"
  return "$rc"
}

# Run claude headless, no tools, return the raw envelope JSON (empty on timeout
# or hard failure). Callers want claude_json; this exists so the doctor can read
# the error fields too. Prompt via stdin.
claude_raw() {
  # ${a[@]+"${a[@]}"} — expanding an empty array is an unbound-variable error
  # under `set -u` on bash 3.2 (what stock macOS ships), so guard the expansion.
  run_timeout "$CLAUDE_AGENTS_TIMEOUT" \
    claude -p - ${CLAUDE_AGENTS_MODEL_ARGS[@]+"${CLAUDE_AGENTS_MODEL_ARGS[@]}"} \
    --allowedTools "" --output-format json 2>/dev/null || true
}

# Human-readable reason the last call failed, or empty if it didn't. A model id
# this backend doesn't recognise surfaces here as a 404.
claude_error() {
  printf '%s' "$1" | jq -r '
    if (.is_error // false) then
      ((.api_error_status // .terminal_reason // "error") | tostring)
        + ": " + ((.result // "unknown") | tostring | .[0:160])
    else empty end' 2>/dev/null || true
}

# Extract the assistant text from a raw envelope, stripping code fences.
# Args: <raw envelope>. Returns empty if the call errored.
claude_result() {
  printf '%s' "$1" \
    | jq -r 'if (.is_error // false) then empty else (.result // empty) end' 2>/dev/null \
    | sed 's/```json//g; s/```//g' || true
}

# Run claude headless, no tools, return raw text result (fail-open: any error,
# non-JSON, or timeout yields empty output, never a non-zero exit). Prompt via stdin.
claude_json() {
  local out
  out="$(claude_raw)"
  # An API failure still exits 0 with well-formed JSON — is_error:true,
  # api_error_status:404, subtype:"success" — and puts the error prose in
  # .result. Extracting .result unconditionally would hand that sentence back as
  # if the model had said it, so gate on is_error and emit nothing instead.
  #
  # `|| true` is load-bearing: on a timeout or error, `out` is empty/partial and
  # jq exits non-zero; without this the hooks (under `set -e`) would abort and
  # fail CLOSED. Fail open — emit whatever parsed (often nothing) and return 0.
  printf '%s' "$out" \
    | jq -r 'if (.is_error // false) then empty else (.result // empty) end' 2>/dev/null \
    | sed 's/```json//g; s/```//g' || true
}

# True if $1 is valid JSON. The emptiness guard is load-bearing: `jq empty` on
# empty input succeeds (there are simply no values to reject), so without it an
# empty reviewer result parses as valid, yields no findings and no verdict, and
# is reported as a clean pass.
is_json() {
  case "$1" in *[![:space:]]*) ;; *) return 1 ;; esac
  echo "$1" | jq empty 2>/dev/null
}

# Print the JSON object embedded in $1, or return 1. Models are asked for bare
# JSON but often wrap it in a sentence ("Here's my review: {...} Hope that
# helps!"), which is a formatting quirk, not a failed review — salvage it rather
# than discarding a perfectly good verdict. Spans the first '{' to the last '}'
# (greedy), so nested objects survive.
extract_json() {
  local s="$1" cand
  is_json "$s" && { printf '%s' "$s"; return 0; }
  cand="$(printf '%s' "$s" | awk '{a = a $0 ORS}
    END { i = index(a, "{"); if (i == 0) exit 1
          b = substr(a, i); if (match(b, /.*\}/)) printf "%s", substr(b, 1, RLENGTH) }')" || return 1
  [ -n "$cand" ] && is_json "$cand" && { printf '%s' "$cand"; return 0; }
  return 1
}

# --------------------------------------------------------------- model probing
# True if this backend accepts model id "$1" (empty = whatever Claude Code would
# pick on its own). One tiny call; a rejected id 404s with duration_api_ms 0, so
# walking a candidate list is cheap. Short timeout — we're testing reachability,
# not waiting out a real generation.
probe_model() {
  local id="${1:-}" raw args=()
  [ -n "$id" ] && args=(--model "$id")
  raw="$(printf 'Reply with the single word: ok' \
    | run_timeout "${CLAUDE_AGENTS_PROBE_TIMEOUT:-30}" \
      claude -p - ${args[@]+"${args[@]}"} --allowedTools "" --output-format json 2>/dev/null || true)"
  [ -n "$raw" ] && [ -z "$(claude_error "$raw")" ]
}

# Ask Claude Code itself which model ids it uses on this backend: one call with
# no --model, then read the modelUsage keys off the response. This is the only
# discovery path that works uniformly across first-party, Bedrock, and Vertex —
# no id formats to guess, no cloud CLI required, and the ids are known-valid
# because they were just used. Prints one id per line, fastest-class first.
models_in_use() {
  local raw
  raw="$(printf 'Reply with the single word: ok' \
    | run_timeout "${CLAUDE_AGENTS_PROBE_TIMEOUT:-30}" \
      claude -p - --allowedTools "" --output-format json 2>/dev/null || true)"
  [ -n "$raw" ] && [ -z "$(claude_error "$raw")" ] || return 1
  # Haiku-class first (that's what the hooks want), then everything else.
  printf '%s' "$raw" | jq -r '(.modelUsage // {} | keys) as $k
    | ($k | map(select(test("haiku"; "i"))))[]?, ($k | map(select(test("haiku"; "i") | not)))[]?' \
    2>/dev/null || return 1
}

# Model ids to try, best (cheapest/fastest) first. On Bedrock the ids are
# account-specific, so ask AWS for the real ones rather than guessing; the
# static entries are only a fallback for when the aws CLI isn't around.
model_candidates() {
  local backend; backend="$(agents_backend)"
  if [ "$backend" = "bedrock" ]; then
    if command -v aws >/dev/null 2>&1; then
      # Inference profiles first (what `global.anthropic.*` ids are), then
      # on-demand foundation models. Haiku before Sonnet, newest first.
      aws bedrock list-inference-profiles --query \
        'inferenceProfileSummaries[].inferenceProfileId' --output text 2>/dev/null \
        | tr '\t' '\n' | grep -i 'anthropic.*haiku' | sort -r
      aws bedrock list-foundation-models --by-provider anthropic --query \
        'modelSummaries[].modelId' --output text 2>/dev/null \
        | tr '\t' '\n' | grep -i haiku | sort -r
    fi
    echo "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    echo "us.anthropic.claude-haiku-4-5-20251001-v1:0"
  elif [ "$backend" = "vertex" ]; then
    echo "claude-haiku-4-5@20251001"
    echo "claude-haiku-4-5"
  else
    echo "claude-haiku-4-5"
    echo "haiku"
  fi
}

# Print the first candidate this backend accepts and return 0. Prints nothing
# and still returns 0 when only Claude Code's own default works — that is a
# valid configuration (the hooks just omit --model). Returns 1 if nothing works,
# which means the CLI itself is broken or unauthenticated, not a model problem.
detect_model() {
  local c
  # 1. Ask Claude Code which ids it actually uses here. Backend-agnostic and
  #    already proven valid, so this is tried before any guessing.
  #
  #    Haiku-class only, deliberately. modelUsage reports what *that call*
  #    happened to use, so the list is non-deterministic: haiku shows up only
  #    when a background task ran, and otherwise it is just the main model.
  #    Accepting whatever came back would quietly pin every hook to Opus — the
  #    exact opposite of wanting a cheap, fast reviewer.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in *[Hh]aiku*) ;; *) continue ;; esac
    if probe_model "$c"; then printf '%s\n' "$c"; return 0; fi
  done <<< "$(models_in_use 2>/dev/null || true)"
  # 2. Guess from the backend's known id shapes.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if probe_model "$c"; then printf '%s\n' "$c"; return 0; fi
  done <<< "$(model_candidates)"
  # 3. Whatever Claude Code picks on its own — valid, just not necessarily fast.
  probe_model "" && return 0
  return 1
}

# Persist the chosen model so git hooks see it regardless of how the push was
# launched. Args: <model id> (empty is meaningful — see detect_model).
write_model_config() {
  local id="${1:-}" dir
  dir="$(dirname "$CLAUDE_AGENTS_CONFIG")"
  mkdir -p "$dir"
  {
    echo "# Written by \`claude-agents setup\`. Edit freely; the environment"
    echo "# variable CLAUDE_AGENTS_MODEL still overrides whatever is set here."
    echo "# An empty value means: pass no --model and let Claude Code choose."
    echo "CLAUDE_AGENTS_MODEL='$id'"
  } > "$CLAUDE_AGENTS_CONFIG"
}

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

Your entire response must be a single JSON object and nothing else. Start with
{ and end with }. No preamble, no explanation, no markdown fences, no closing
remark. Shape:
{\"findings\":[{\"severity\":\"error|warning|suggestion\",\"file\":\"\",\"line\":0,\"rule\":\"\",\"comment\":\"\"}],\"verdict\":\"block|pass\"}
Rules:
- severity 'error' ONLY for things that must block a push: bugs, security,
  data loss, broken contracts, or a repeat of a listed past lesson.
- verdict is 'block' iff any finding is 'error'.
- Report at most the 12 most severe findings. Be concise.

DIFF:
$diff"
  # Distinguish the three ways this can go wrong. They all fail open, but
  # collapsing them into one "unparseable" line hid a machine whose model id
  # didn't exist for an entire release — every push looked reviewed and wasn't.
  local envelope err
  envelope="$(printf '%s' "$prompt" | claude_raw)"
  err="$(claude_error "$envelope")"
  # run_timeout kills the CLI mid-stream, which it reports as aborted_streaming
  # rather than as a timeout — surface it as the timeout it actually is.
  if [ -z "$envelope" ] || case "$err" in *aborted_streaming*) true ;; *) false ;; esac; then
    echo "  reviewer: no response within ${CLAUDE_AGENTS_TIMEOUT}s — allowing."
    echo "    the model may be too slow for this diff; raise CLAUDE_AGENTS_TIMEOUT,"
    echo "    or pick a faster model (run: claude-agents doctor)"
    return 0
  elif [ -n "$err" ]; then
    echo "  reviewer: model call failed — $err"
    echo "    allowing the push; run 'claude-agents doctor' to diagnose"
    return 0
  fi

  raw="$(claude_result "$envelope")"
  local parsed
  if ! parsed="$(extract_json "$raw")"; then
    echo "  reviewer: expected JSON, got prose — allowing. First 200 chars:"
    printf '%s\n' "$raw" | head -c 200 | sed 's/^/    /'
    echo
    return 0
  fi
  raw="$parsed"
  echo "$raw" | jq -r '.findings[]? | "  [\(.severity)] \(.file):\(.line) — \(.rule): \(.comment)"'
  [ "$(echo "$raw" | jq -r '.verdict')" = "block" ] && return 1 || return 0
}
