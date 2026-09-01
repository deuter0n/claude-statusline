# claude-statusline

A single-script status line for [Claude Code](https://claude.com/claude-code): git project + branch/commit, model name and effort level, 5-hour and 7-day rate-limit usage as mini progress bars, and a context-window usage bar — all on one line, colored by severity.

## Preview

```
● arc3 (main@ba57501) │ Sonnet 5(medium) │ 5h ▁▁▂▂▁▁ 42% (2h13m) │ 7d ▁▁▁▁▁▁ 18% (4d6h) │ ctx ▁▁▁ 31%
```

- `●` / `○` — filled when running as a normal interactive session, hollow when running inside a background job (`CLAUDE_JOB_DIR` set)
- `arc3 (main@ba57501)` — repo name (or folder name as a fallback) with current branch and short commit hash
- `Sonnet 5(medium)` — active model and effort/thinking level, colored per model family (Opus purple, Sonnet blue, Haiku green, Fable red)
- `5h` / `7d` — rate-limit usage bars with time remaining until reset
- `ctx` — context window usage bar

Bars and percentages are colored green under 50%, yellow from 50–79%, and red at 80%+, so color always signals severity rather than being decorative.

## Requirements

- `bash`
- `python3` (used only to parse the JSON Claude Code passes in on stdin)
- `git` (optional — git segments are omitted outside a repo)
- `awk`, `date` (standard on any Linux/macOS box)

## Install

Clone or copy `statusline-command.sh` to `~/.claude/statusline-command.sh`:

```bash
mkdir -p ~/.claude
curl -o ~/.claude/statusline-command.sh \
  https://raw.githubusercontent.com/deuter0n/claude-statusline/main/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh
```

Then point Claude Code at it in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

Restart Claude Code (or start a new session) to see it take effect.

## How it works

Claude Code invokes the configured `statusLine` command on every render, piping a JSON blob (model, workspace, rate limits, context window, etc.) to it on stdin. The script:

1. Parses that JSON with an inline `python3` call and re-emits the fields as shell-safe `key=value` assignments, consumed via `eval`.
2. Resolves git branch/commit for the session's working directory directly with `git rev-parse`, since the JSON payload doesn't include them.
3. Renders each segment (project/git, model/effort, rate limits, context) only if its data is present, joining non-empty segments with a dim `│` separator.

Everything is a single self-contained bash script — no dependencies to install beyond what's already on a typical dev machine.

## Customizing

Colors, bar width, and which segments appear are all defined near the top and inline through `statusline-command.sh` — it's meant to be forked and tweaked:

- `COLOR_*` variables set the palette (256-color ANSI codes)
- `make_bar` controls bar width/characters (default width `6`, using `━`/`─`)
- `model_color` maps model name substrings to colors
- `pct_color` sets the 50%/80% severity thresholds

## License

No license file yet — add one (e.g. MIT) if you want to make reuse terms explicit.
