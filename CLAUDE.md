# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single self-contained bash script (`statusline-command.sh`) that implements a Claude Code `statusLine` command. It reads the JSON payload Claude Code pipes to it on stdin and prints a colored status line (project/git, model/effort, tokens, cost, 5h/7d rate-limit bars, context-window bar, prompt-cache countdown), wrapping onto up to three lines when the terminal is narrow. There is no build step, package manager, or test suite — the script itself is the entire product.

## Testing changes

There's no automated test suite. To exercise the script, pipe a JSON payload matching Claude Code's statusline schema into it, setting `COLUMNS` to simulate the terminal width (Claude Code sets it before running the script; unset means "never wrap"):

```bash
echo '{"model":{"display_name":"Sonnet 5"},"effort":{"level":"medium"},"workspace":{"project_dir":"/path/to/repo","current_dir":"/path/to/repo"},"context_window":{"used_percentage":31,"total_input_tokens":15500,"total_output_tokens":1200},"cost":{"total_cost_usd":0.01234},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1234567890},"seven_day":{"used_percentage":18,"resets_at":1234567890}}}' | COLUMNS=80 bash statusline-command.sh
```

Check output with missing or `null` fields too (e.g. omit `rate_limits` or `context_window`) since every segment is conditionally rendered — a change should degrade gracefully when a field is absent, not error or leave stray separators. Also try several `COLUMNS` values (wide, ~90, ~60, ~30) to see the one-, two- and three-line layouts.

To test it live in an actual session, point `~/.claude/settings.json`'s `statusLine.command` at your working copy of the script.

## Architecture

The script is one linear pipeline, in this order:

1. **Parse JSON → shell vars**: an inline `python3 -c` script reads stdin JSON and prints `key=value` pairs (via `shlex.quote`) that get `eval`'d into the shell. Its `get(*path)` helper returns `""` for anything missing or `null` at any depth. This is the sole JSON-parsing boundary; everything after it is bash/awk.
2. **Resolve git info**: a single `git status --porcelain=v2 --branch` call against the session's `cwd`, parsed by `awk`, yields branch, short commit, a dirty flag and ahead/behind counts (Claude Code's payload doesn't include them). Fields are `\037`-separated so an empty commit (repo with no commits) doesn't shift the rest.
3. **Render helpers**: `pct_color`/`time_left_color` (severity coloring), `model_color` (family-based coloring by case-insensitive substring match), `make_bar` (integer percentage → `━`/`─` bar), `fmt_duration` (seconds → `1d2h`/`3h4m`/`5m`), `fmt_tokens` (→ `15.5k`/`1.5M`), `fmt_cost` (→ `$0.012`/`$3.46`), and `get_thb_rate`/`fmt_cost_thb` (fetches and disk-caches a live USD→THB rate via `curl` against `open.er-api.com`, 12h TTL, 2s network timeout, and prints nothing on any failure so the THB conversion just disappears).
4. **Segment assembly**: each segment is added with `add_seg <row> <text>` only if its backing data is non-empty. `add_seg` records the text, its visible width (`visible_width`: ANSI codes stripped, locale-independent character count) and its row in parallel arrays. This conditional-add pattern is what makes segments disappear cleanly when data is missing — preserve it when adding new segments. Rows:
   - row 0: `●`/`○` session indicator, project name, `(branch@commit)` plus `*` (dirty), `⇡N`/`⇣N` (ahead/behind)
   - row 1: model/effort (with `↯` in fast mode), tokens (`↓ N · ↑ N`), cost (with optional `(฿N)`)
   - row 2: `5h`/`7d` limits and `ctx` (all built by `pct_seg`), prompt-cache countdown
5. **Layout**: using the recorded widths and `$COLUMNS`, everything goes on one line if it fits; otherwise the break goes after row 1 (after cost); if rows 0+1 still don't fit, row 0 also gets its own line (break before the model). A row that alone overflows wraps greedily between its segments. Segments on a line are joined with `$SEP` (dim `|`) and lines with `\n`.

Color/threshold/width constants (`COLOR_*`, bar width `6`, the 50%/80% severity cutoffs in `pct_color`, the 5m/15m cutoffs in `time_left_color`, model-family colors in `model_color`) are defined inline near where they're used, not centralized — the script is meant to be forked and tweaked directly rather than configured externally.
