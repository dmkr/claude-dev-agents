# claude-dev-agents

A local multi-agent development setup built on `claude -p`. Five agents share one
per-repo "brain," fed by a daily cross-repo miner that learns from your merged-PR
review feedback so you stop repeating the same mistakes.

## Install

```bash
brew install dmkr/tap/claude-agents
```

Claude Code isn't on Homebrew, so install it separately:

```bash
curl -fsSL https://claude.ai/install.sh | bash
gh auth login
```

Then:

```bash
claude-agents setup                        # one-time machine wiring
cd ~/code/some-repo && claude-agents install   # per repo
```

## Commands

| Command | What it does |
|---|---|
| `claude-agents setup` | Global `CLAUDE.md`, lessons dir, daily miner (launchd) |
| `claude-agents install [PATH]` | Git hooks + seeded brain files in a repo |
| `claude-agents mine` | Run the cross-repo lesson miner now |
| `claude-agents sync` | Sync central lessons into this repo |
| `claude-agents ask "..."` | Ask a question about this codebase |
| `claude-agents review [SPEC]` | Run the reviewer without pushing (`--staged`, or a range) |
| `claude-agents pr [gh args]` | Open a PR with the generated `.git/PR_BODY.md` |
| `claude-agents status` | Health check (miner, lessons, hooks) |
| `claude-agents doctor` | Verify dependencies |
| `claude-agents uninstall` | Remove machine wiring |

## The agents

- **Test-guardian** (`pre-commit`, advisory) — flags new functions lacking tests.
- **Commit-message writer** (`prepare-commit-msg`) — drafts messages from the diff.
- **Reviewer + PR-description + drift-watcher** (`pre-push`) — the reviewer
  blocks the push on serious issues in one fast call (Haiku by default). The
  PR description and drift check are advisory: they run in the background so
  they don't slow the push, writing `.git/{PR_BODY,DRIFT}.md`. Whitespace-only
  and docs-only pushes skip the model entirely.
- **Codebase Q&A** (`claude-agents ask`) — answers with file/function citations.
- **Cross-repo lesson miner** (daily) — distills review feedback from every repo
  you've authored merged PRs in, split into language-agnostic and per-language
  lessons, synced into each repo on push.

## Layout

```
~/.claude/CLAUDE.md      # global instructions for interactive Claude Code
~/.claude/lessons/       # central mined lessons (source of truth)
<repo>/.claude/review/   # per-repo brain: style, boundaries, synced lessons
<repo>/.git/hooks/       # symlinks into the brew libexec
```

## The brain

Two files you write per repo:

- `STYLE_GUIDE.md` — concrete, checkable conventions the reviewer enforces.
- `BOUNDARIES.md` — what may import what; the drift-watcher flags crossings.

One file generated for you:

- `LESSONS.md` — synced from `~/.claude/lessons/`, filtered to this repo's
  languages plus cross-cutting principles.

## Notes

- Hooks fail open: if Claude errors, the git operation proceeds. Only a clean
  `error`-severity finding blocks a push. Override with `git push --no-verify`.
- `claude -p` draws on the Agent SDK credit bucket, separate from interactive use.
- Hooks run on Haiku for speed. Set `CLAUDE_AGENTS_MODEL` (e.g.
  `claude-opus-4-8`) to trade latency for a stronger review.
- **`claude-agents setup` auto-detects the model.** Model ids are backend- and
  (on Bedrock) account-specific, so setup probes candidates fastest-first —
  asking `aws bedrock list-inference-profiles` for the real ids where available
  — and records the first that answers in
  `~/.config/claude-agents/config`. The hooks read that file, so the choice
  survives environments git hooks don't inherit (GUI clients never source
  `~/.zshrc`). Re-run `setup` after switching backends.
- Full resolution order: `CLAUDE_AGENTS_MODEL` → the config file →
  `ANTHROPIC_DEFAULT_HAIKU_MODEL` → `ANTHROPIC_SMALL_FAST_MODEL` → on a provider
  backend with none of those, no `--model` flag at all (Claude Code picks) →
  otherwise `claude-haiku-4-5`. An *explicitly empty* value means "pass no
  `--model`" and is distinct from unset.
- Because the hooks fail open, a model id the backend rejects looks identical to
  a clean review. `claude-agents doctor` makes one live call to tell them apart —
  run it after changing backends or moving to a new machine.
- Git hooks inherit the environment of whatever ran `git push`. Exporting
  `CLAUDE_AGENTS_MODEL` in `~/.zshrc` covers terminal pushes but not GUI clients
  (Fork, Tower, VS Code) — use `~/.zshenv` if you push from those.
- `CLAUDE_AGENTS_TIMEOUT` (seconds, default 90) caps each model call; on timeout
  the hook fails open (the push proceeds), so a slow model can't stall you.
- `CLAUDE_AGENTS_DIFF_CAP` (chars, default 120000) bounds the diff sent to the
  reviewer; `CLAUDE_AGENTS_NO_PR_DESC=1` skips the background PR-description and
  drift pass (one fewer `claude -p` call per push).
- Repo hooks are symlinked via Homebrew's stable `opt` path, so a `brew upgrade`
  doesn't break them. If a hook ever shows "symlink broken" in `status` (e.g.
  after an older install), re-run `claude-agents install` to re-link.
- Move the lessons library by setting `LESSONS_DIR`.
- Miner cadence lives in the plist (`StartInterval`, seconds). Default: daily.

## License

MIT
