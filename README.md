# claude-statusline

A single-script status line for [Claude Code](https://claude.com/claude-code): git project + branch/commit and working-tree state, model name and effort level, input/output token counts, session cost (with a live THB conversion), 5-hour and 7-day rate-limit usage as mini progress bars, a context-window usage bar, and a prompt-cache countdown. Colored by severity, and wrapped onto multiple lines when the terminal is too narrow.

## Preview

On a wide terminal everything fits on one line:

```
● claude-statusline (main@4ab7820) * ⇡1 | Sonnet 5 (medium) | ↓ 15.5k · ↑ 1.2k | $0.012 (฿0.41) | 5h ━━━─── 42% (2h13m) | 7d ━───── 18% (4d5h) | ctx ━━──── 31% | cache 4m
```

- `●` / `○`: filled for a normal interactive session, hollow inside a background job (`CLAUDE_JOB_DIR` set)
- `claude-statusline (main@4ab7820)`: repo name (or folder name as a fallback) with current branch and short commit hash (`HEAD` when detached)
- `*` / `⇡1` / `⇣2`: uncommitted changes (staged, unstaged, untracked or conflicted), commits ahead of / behind upstream. Each appears only when relevant
- `Sonnet 5 (medium)`: active model and effort level, colored per model family (Opus purple, Sonnet blue, Haiku green, Fable red), with `↯` after the name in fast mode
- `↓ 15.5k · ↑ 1.2k`: input (`↓`) / output (`↑`) token counts, rounded to k/M
- `$0.012 (฿0.41)`: cumulative session cost in USD (3 decimals under $1, 2 decimals at or above), followed by a live THB conversion when a rate is available
- `5h` / `7d`: rate-limit usage bars with time remaining until reset
- `ctx`: context window usage bar
- `cache 4m`: time left before the prompt cache expires, shown only while it's warm

Bars and percentages are green under 50%, yellow from 50–79% and red at 80%+, so color always signals severity rather than being decorative. The cache countdown uses the same colors in reverse: red under 5 minutes, yellow under 15. Tokens and cost have no natural threshold, so they use fixed accent colors (cyan and amber-yellow).

### Narrow terminals

When the line doesn't fit, it wraps at fixed points so the layout stays predictable: first after the cost, then also before the model name.

```
● claude-statusline (main@4ab7820) * ⇡1 | Sonnet 5 (medium) | ↓ 15.5k · ↑ 1.2k | $0.012 (฿0.41)
5h ━━━─── 42% (2h13m) | 7d ━───── 18% (4d5h) | ctx ━━──── 31% | cache 4m
```

```
● claude-statusline (main@4ab7820) * ⇡1
Sonnet 5 (medium) | ↓ 15.5k · ↑ 1.2k | $0.012 (฿0.41)
5h ━━━─── 42% (2h13m) | 7d ━───── 18% (4d5h) | ctx ━━──── 31% | cache 4m
```

If one of those lines is still too wide on its own, it wraps between segments.

## Requirements

- `bash`
- `python3` (used only to parse the JSON Claude Code passes in on stdin, and to parse the THB exchange-rate API response)
- `git` (optional; git segments are omitted outside a repo)
- `curl` (optional; the THB conversion in the cost segment is omitted without it, or if the exchange-rate API is unreachable)
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
    "command": "bash ~/.claude/statusline-command.sh",
    "refreshInterval": 1
  }
}
```

`refreshInterval` is optional. Without it, Claude Code only re-runs the script on events (a new assistant message, `/compact`, a permission-mode change, and so on), so the reset and cache countdowns only move when something happens. With `1`, the script also runs every second. It takes about 40 ms per run.

Claude Code picks up settings changes automatically.

## How it works

Claude Code runs the configured `statusLine` command, pipes a JSON blob (model, workspace, rate limits, context window, cost, prompt cache, etc.) to it on stdin, and sets `$COLUMNS` to the terminal width. The script:

1. Parses that JSON with an inline `python3` call and re-emits the fields as shell-safe `key=value` assignments, consumed via `eval`. Missing or `null` fields become empty strings.
2. Runs a single `git status --porcelain=v2 --branch` in the session's working directory to get the branch, commit, dirty state and ahead/behind counts, since the JSON payload doesn't include them.
3. Builds each segment only if its data is present, so missing data never leaves a stray separator. Each segment is assigned to one of three rows (project/git; model, tokens, cost; limits, context, cache).
4. Measures the segments and joins them with a dim `|`. They all go on one line if it fits within `$COLUMNS`, otherwise onto separate lines as described in [Narrow terminals](#narrow-terminals).

The cost segment also tries to fetch a live USD→THB exchange rate (via `curl`, from `open.er-api.com`) to show a THB conversion alongside the USD figure. The rate is cached on disk for 12 hours (`~/.cache/claude-statusline/thb_rate.cache`), so most runs don't hit the network. Any failure (no `curl`, no network, bad response) just drops the THB conversion rather than erroring or stalling the statusline, and network calls are capped at 2 seconds.

Everything is a single self-contained bash script, with no dependencies to install beyond what's already on a typical dev machine.

## Customizing

Colors, bar width, thresholds and segment layout are all defined inline in `statusline-command.sh`. It's meant to be forked and tweaked:

- `COLOR_*` variables set the palette (ANSI / 256-color codes)
- `model_color` maps model name substrings to colors
- `pct_color` sets the 50%/80% severity thresholds; `time_left_color` sets the cache countdown's 5m/15m thresholds
- `make_bar` draws the bars (`━`/`─`); `pct_seg` builds the `5h`/`7d`/`ctx` segments and sets their width (`6`)
- `fmt_tokens` / `fmt_cost` control how token counts (`k`/`M`) and USD cost (`$0.012`/`$3.46`) are formatted
- `fmt_cost_thb` / `get_thb_rate` / `THB_RATE_TTL` / `THB_RATE_CACHE` control the THB conversion's formatting, cache location, and cache lifetime (default 12h)
- The first argument to `add_seg` picks a segment's row (`0`–`2`), which controls where it wraps
