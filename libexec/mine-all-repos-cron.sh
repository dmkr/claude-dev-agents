#!/usr/bin/env bash
# Wrapper so launchd can run the cross-repo PR-feedback miner.
# Unlike the old single-repo version, this discovers repos via `gh search prs`,
# so there's no repo to cd into — it just needs a sane env and PATH.
set -euo pipefail

LOG="$HOME/Library/Logs/mine-all-repos.log"
STAMP="$HOME/.claude/lessons/.last-run"

# launchd runs with a bare environment; put Homebrew + user bins on PATH so
# claude, gh, and jq resolve.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# If gh's keychain auth doesn't carry into the background context, uncomment:
# export GH_TOKEN="$(cat "$HOME/.config/gh/token" 2>/dev/null || true)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="

  # Skip-if-nothing-new guard: compare your most recent merged PR against last run.
  ME="$(gh api user -q .login 2>/dev/null || true)"
  LATEST="$(gh search prs --author "$ME" --merged --limit 1 \
             --json closedAt -q '.[0].closedAt' 2>/dev/null || true)"
  if [ -n "$LATEST" ] && [ -f "$STAMP" ] && [ "$LATEST" = "$(cat "$STAMP")" ]; then
    echo "No new merged PRs since last run ($LATEST). Skipping."
    exit 0
  fi

  "$SCRIPT_DIR/mine-all-repos.sh"

  # Record the newest merged PR timestamp so the next tick can skip if unchanged.
  mkdir -p "$(dirname "$STAMP")"
  [ -n "$LATEST" ] && echo "$LATEST" > "$STAMP"
} >> "$LOG" 2>&1
