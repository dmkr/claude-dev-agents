# Working agreement (global)

Before writing or editing code in any repo, load the local "brain" if it exists,
and follow it. These are the same standards the pre-push reviewer enforces, so
aligning up front avoids getting blocked at push time.

## Read these first (when present, at the repo root)

- `.claude/review/STYLE_GUIDE.md` — team style rules. Follow them.
- `.claude/review/LESSONS.md` — lessons distilled from past PR review feedback,
  already filtered to this repo's languages plus cross-cutting principles. Treat
  each line as a mistake I've been told about before; do not repeat it.
- `.claude/review/BOUNDARIES.md` — intended module/import boundaries. Do not add
  code that crosses them. If a task seems to require crossing one, stop and say so
  rather than doing it silently.

If a file is absent, skip it — no need to mention that it's missing.

## How to apply them

- When these rules conflict with a quick-and-dirty approach, prefer the rules.
- When writing new functions, include the tests that matter (happy path + the
  risky edge). The pre-commit test-guardian will otherwise flag their absence.
- Keep changes within the intended boundaries; surface architectural tradeoffs
  explicitly instead of quietly working around them.
- Don't restate these rules back to me in every response; just follow them.

## Context

The lessons above come from a central cross-repo library at `~/.claude/lessons/`
that is re-mined daily from my merged PRs. The per-repo `LESSONS.md` is a synced
slice of it (agnostic + this repo's languages), refreshed on each push. So
`.claude/review/LESSONS.md` is always the right file to trust in a given repo.
