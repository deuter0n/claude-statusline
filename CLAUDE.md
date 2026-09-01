# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single self-contained bash script (`statusline-command.sh`) that implements a Claude Code `statusLine` command. It reads the JSON payload Claude Code pipes to it on stdin and prints one colored status line (project/git, model/effort, 5h/7d rate-limit bars, context-window bar). There is no build step, package manager, or test suite — the script itself is the entire product.

## Testing changes

There's no automated test suite. To exercise the script, pipe a JSON payload matching Claude Code's statusline schema into it, e.g.:

```bash
echo '{"model":{"display_name":"Sonnet 5"},"effort":{"level":"medium"},"workspace":{"project_dir":"/path/to/repo","current_dir":"/path/to/repo"},"context_window":{"used_percentage":31},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1234567890},"seven_day":{"used_percentage":18,"resets_at":1234567890}}}' | bash statusline-command.sh
```

Check output with missing fields too (e.g. omit `rate_limits` or `context_window`) since every segment is conditionally rendered — a change should degrade gracefully when a field is absent, not error or leave stray separators.

To test it live in an actual session, point `~/.claude/settings.json`'s `statusLine.command` at your working copy of the script.

## Architecture

The script is one linear pipeline, in this order:

1. **Parse JSON → shell vars**: the only `python3` dependency, an inline `python3 -c` script that reads stdin JSON and prints `key=value` pairs (via `shlex.quote`) that get `eval`'d into the shell. This is the sole JSON-parsing boundary; everything after it is pure bash/awk.
2. **Resolve git info directly**: branch and short commit are fetched via `git rev-parse` against the session's `cwd`, not from the JSON payload (Claude Code doesn't include them).
3. **Render helpers**: `make_bar` (percentage → block-character bar), `fmt_duration` (seconds → `1d2h`/`3h4m`/`5m`), `pct_color`/`colorize_pct` (severity-threshold coloring), `model_color` (family-based coloring by substring match on model name).
4. **Segment assembly**: each segment (project/git, model/effort, 5h limit, 7d limit, context) is built into `out` only if its backing data is non-empty, joined with a shared `$SEP` (dim `│`). This conditional-append pattern is what makes segments disappear cleanly when data is missing — preserve it when adding new segments.

Color/threshold/width constants (`COLOR_*`, bar width `6`, the 50%/80% severity cutoffs in `pct_color`, model-family colors in `model_color`) are defined inline near where they're used, not centralized — the script is meant to be forked and tweaked directly rather than configured externally.
