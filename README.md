# claude-statusline

A single-script status line for [Claude Code](https://claude.com/claude-code): git project + branch/commit, model name and effort level, 5-hour and 7-day rate-limit usage as mini progress bars, a context-window usage bar, input/output token counts, and session cost (with a live THB conversion) — all on one line, colored by severity.

## Preview

```
● claude-statusline (main@5ee0cab) | Sonnet 5 (medium) | 5h ━━━─── 42% (2h13m) | 7d ━───── 18% (4d5h) | ctx ━━──── 31% | ↓ 15.5k · ↑ 1.2k | $0.012 (฿0.41)
```

- `●` / `○` — filled when running as a normal interactive session, hollow when running inside a background job (`CLAUDE_JOB_DIR` set)
- `claude-statusline (main@5ee0cab)` — repo name (or folder name as a fallback) with current branch and short commit hash
- `Sonnet 5 (medium)` — active model and effort/thinking level, colored per model family (Opus purple, Sonnet blue, Haiku green, Fable red)
- `5h` / `7d` — rate-limit usage bars with time remaining until reset
- `ctx` — context window usage bar
- `↓ 15.5k · ↑ 1.2k` — input (`↓`) / output (`↑`) token counts, rounded to k/M, separated by a middle dot
- `$0.012 (฿0.41)` — cumulative session cost in USD (3 decimals under $1, 2 decimals at or above), followed by a live THB conversion in parens when a rate is available

Bars and percentages are colored green under 50%, yellow from 50–79%, and red at 80%+, so color always signals severity rather than being decorative. The token and cost segments aren't severity-based — they use fixed accent colors (cyan for tokens, amber-yellow for cost) since there's no natural threshold for either.

## Requirements

- `bash`
- `python3` (used only to parse the JSON Claude Code passes in on stdin, and to parse the THB exchange-rate API response)
- `git` (optional — git segments are omitted outside a repo)
- `curl` (optional — the THB conversion in the cost segment is omitted without it, or if the exchange-rate API is unreachable)
- `awk`, `date`, `stat` (standard on any Linux/macOS box)

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
3. Renders each segment (project/git, model/effort, rate limits, context, tokens, cost) only if its data is present, joining non-empty segments with a dim `|` separator.

The cost segment additionally tries to fetch a live USD→THB exchange rate (via `curl`, from `open.er-api.com`) to show a THB conversion alongside the USD figure. The rate is cached on disk for 12 hours (`~/.cache/claude-statusline/thb_rate.cache`) so most renders don't hit the network, and any failure (no `curl`, no network, bad response) just drops the THB conversion rather than erroring or stalling the statusline — network calls are capped at 2 seconds.

Everything is a single self-contained bash script — no dependencies to install beyond what's already on a typical dev machine.

## Customizing

Colors, bar width, and which segments appear are all defined near the top and inline through `statusline-command.sh` — it's meant to be forked and tweaked:

- `COLOR_*` variables set the palette (256-color ANSI codes)
- `make_bar` controls bar width/characters (default width `6`, using `━`/`─`)
- `model_color` maps model name substrings to colors
- `pct_color` sets the 50%/80% severity thresholds
- `fmt_tokens` / `fmt_cost` control how token counts (`k`/`M`) and USD cost (`$0.012`/`$3.46`) are formatted
- `fmt_cost_thb` / `get_thb_rate` / `THB_RATE_TTL` / `THB_RATE_CACHE` control the THB conversion's formatting, cache location, and cache lifetime (default 12h)
