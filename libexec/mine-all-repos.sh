#!/usr/bin/env bash
# Cross-repo PR-feedback miner.
# Finds every repo you've authored merged PRs in, collects review comments tagged
# with the language(s) of the files they touched, and distills them into a central
# lessons library split into language-agnostic and per-language files.
#
# Output: ~/.claude/lessons/{AGNOSTIC,python,go,typescript,...}.md
# Requires: gh (authenticated), claude, jq
set -euo pipefail

LESSONS_DIR="${LESSONS_DIR:-$HOME/.claude/lessons}"
MAX_PRS_PER_REPO="${MAX_PRS_PER_REPO:-30}"
SEARCH_LIMIT="${SEARCH_LIMIT:-200}"   # how many of your merged PRs to scan overall
mkdir -p "$LESSONS_DIR"

ME="$(gh api user -q .login)"
echo "Finding merged PRs authored by $ME across all repos..."

# All repos where you have merged PRs. GitHub search, deduped to owner/repo.
REPOS="$(
  gh search prs --author "$ME" --merged --limit "$SEARCH_LIMIT" \
     --json repository -q '.[].repository.nameWithOwner' \
  | sort -u
)"
[ -z "$REPOS" ] && { echo "No merged PRs found."; exit 0; }
echo "Repos:"; echo "$REPOS" | sed 's/^/  /'

# Map a filename to a language bucket by extension.
lang_of() {
  case "$1" in
    *.py) echo python ;;
    *.go) echo go ;;
    *.ts|*.tsx) echo typescript ;;
    *.js|*.jsx|*.mjs) echo javascript ;;
    *.rb) echo ruby ;;
    *.rs) echo rust ;;
    *.java) echo java ;;
    *.kt) echo kotlin ;;
    *.c|*.h) echo c ;;
    *.cpp|*.cc|*.hpp) echo cpp ;;
    *.cs) echo csharp ;;
    *.php) echo php ;;
    *.swift) echo swift ;;
    *.scala) echo scala ;;
    *.sh|*.bash) echo shell ;;
    *) echo _other ;;
  esac
}

# Collect comments as JSONL: {lang, path, body}. Inline comments carry a .path we
# can map to a language; summary reviews have no path -> language-agnostic pool.
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

while read -r REPO; do
  [ -z "$REPO" ] && continue
  echo "  scanning $REPO ..."
  for n in $(gh pr list --repo "$REPO" --author "$ME" --state merged \
               --limit "$MAX_PRS_PER_REPO" --json number -q '.[].number'); do
    # inline review comments (have a file path -> language)
    gh api "repos/$REPO/pulls/$n/comments" \
       -q '.[] | {path: .path, body: .body}' 2>/dev/null \
    | while IFS= read -r row; do
        [ -z "$row" ] && continue
        p="$(echo "$row" | jq -r '.path')"
        lang="$(lang_of "$p")"
        echo "$row" | jq -c --arg lang "$lang" '. + {lang: $lang}'
      done >> "$TMP" || true
    # top-level review bodies (no path -> agnostic)
    gh api "repos/$REPO/pulls/$n/reviews" \
       -q '.[] | select(.body != "") | {path: "(summary)", body: .body, lang: "_agnostic"}' \
       2>/dev/null >> "$TMP" || true
  done
done <<< "$REPOS"

TOTAL="$(wc -l < "$TMP" | tr -d ' ')"
[ "$TOTAL" -eq 0 ] && { echo "No review comments collected."; exit 0; }
echo "Collected $TOTAL comments. Distilling..."

# Which language buckets actually have content (besides agnostic/other).
LANGS="$(jq -r '.lang' "$TMP" | sort -u | grep -vE '^(_agnostic|_other)$' || true)"

# ---- language-agnostic pass ----
# Feed Claude the whole corpus and ask ONLY for cross-cutting lessons, so
# language-specific nits don't leak into the agnostic file.
jq -s '.' "$TMP" | claude -p "You are distilling code-review feedback into a durable
lessons file. The input is JSON review comments from many repositories and languages.
Extract ONLY language-AGNOSTIC lessons: recurring principles that apply regardless of
language — naming, error handling, API/interface design, testing discipline, commit
hygiene, readability, separation of concerns. EXCLUDE anything tied to a specific
language's syntax, idioms, or libraries. Group by theme; each lesson is one imperative
line with a parenthetical recurrence note. Markdown only, starting with
'# Language-agnostic lessons'. No preamble." \
  --allowedTools "" > "$LESSONS_DIR/AGNOSTIC.md"
echo "  wrote AGNOSTIC.md"

# ---- per-language passes ----
for lang in $LANGS; do
  jq -c "select(.lang == \"$lang\")" "$TMP" | jq -s '.' \
  | claude -p "You are distilling $lang-specific code-review feedback. Input is JSON
review comments on $lang files. Extract ONLY lessons specific to $lang — its idioms,
standard library, common footguns, tooling, type/error conventions. EXCLUDE generic
advice that would apply to any language (that lives elsewhere). Group by theme; each
lesson one imperative line with a recurrence note. Markdown only, starting with
'# $lang-specific lessons'. No preamble." \
    --allowedTools "" > "$LESSONS_DIR/$lang.md"
  echo "  wrote $lang.md"
done

echo "Done. Lessons library at $LESSONS_DIR"
ls -1 "$LESSONS_DIR"
