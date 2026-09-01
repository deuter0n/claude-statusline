#!/bin/bash
# Statusline: git project name + branch + commit, model name + effort
# level, usage limits (5h / 7d, as progress bars), and context window
# progress bar.

input=$(cat)

eval "$(printf '%s' "$input" | python3 -c '
import json, sys, shlex, os, glob

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

model = data.get("model", {}).get("display_name", "") or ""
effort = data.get("effort", {}).get("level", "") or ""

cw = data.get("context_window", {}) or {}
used_pct = cw.get("used_percentage")
used_pct = "" if used_pct is None else str(used_pct)
in_tokens = cw.get("total_input_tokens")
in_tokens = "" if in_tokens is None else str(in_tokens)
out_tokens = cw.get("total_output_tokens")
out_tokens = "" if out_tokens is None else str(out_tokens)

cost = data.get("cost", {}) or {}
total_cost = cost.get("total_cost_usd")
total_cost = "" if total_cost is None else str(total_cost)

workspace = data.get("workspace", {}) or {}
project_dir = workspace.get("project_dir", "") or ""
cwd = workspace.get("current_dir", "") or ""
folder = project_dir.rstrip("/").split("/")[-1] if project_dir else ""
repo_name = workspace.get("repo", {}).get("name", "") or ""

rl = data.get("rate_limits", {}) or {}
five_hour = rl.get("five_hour", {}) or {}
seven_day = rl.get("seven_day", {}) or {}
five_pct = five_hour.get("used_percentage")
five_pct = "" if five_pct is None else str(five_pct)
week_pct = seven_day.get("used_percentage")
week_pct = "" if week_pct is None else str(week_pct)
five_reset = five_hour.get("resets_at")
five_reset = "" if five_reset is None else str(five_reset)
week_reset = seven_day.get("resets_at")
week_reset = "" if week_reset is None else str(week_reset)

for key, val in [("model", model), ("effort", effort), ("used_pct", used_pct), ("in_tokens", in_tokens), ("out_tokens", out_tokens), ("total_cost", total_cost), ("folder", folder), ("repo_name", repo_name), ("cwd", cwd), ("five_pct", five_pct), ("week_pct", week_pct), ("five_reset", five_reset), ("week_reset", week_reset)]:
    print(f"{key}={shlex.quote(val)}")
')"

[ -z "$cwd" ] && cwd=$(pwd)

project="$repo_name"
[ -z "$project" ] && project="$folder"

branch=""
commit=""
if command -v git >/dev/null 2>&1; then
  branch=$(git --no-optional-locks -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  commit=$(git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

make_bar() {
  local pct=$1
  local width=${2:-10}
  local filled empty bar
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN { n = int((p * w / 100) + 0.5); if (n < 0) n = 0; if (n > w) n = w; printf "%d", n }')
  empty=$((width - filled))
  bar=""
  [ "$filled" -gt 0 ] && bar+=$(printf '%0.s\xe2\x94\x81' $(seq 1 "$filled"))
  [ "$empty" -gt 0 ] && bar+=$(printf '%0.s\xe2\x94\x80' $(seq 1 "$empty"))
  printf '%s' "$bar"
}

bar=""
[ -n "$used_pct" ] && bar=$(make_bar "$used_pct" 6)
ctx_pct=""
[ -n "$used_pct" ] && ctx_pct="$(printf '%.0f' "$used_pct" 2>/dev/null)%"

fmt_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n / 1000000;
    else if (n >= 1000) printf "%.1fk", n / 1000;
    else printf "%d", n;
  }'
}

fmt_cost() {
  awk -v n="$1" 'BEGIN {
    if (n < 1) printf "$%.3f", n;
    else printf "$%.2f", n;
  }'
}

fmt_duration() {
  local secs=$1
  [ "$secs" -lt 0 ] && secs=0
  local d=$((secs / 86400))
  local h=$(((secs % 86400) / 3600))
  local m=$(((secs % 3600) / 60))
  if [ "$d" -gt 0 ]; then
    printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh%dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

now=$(date +%s)

# Palette: the leading project field and branch@commit share one bright
# orange so they read as a single unit. Model name and effort share one
# family-based bright color so they read as a single unit too. Labels stay a
# bright neutral gray; bars/percentages are colored by severity
# (green/yellow/red) so color on the line always means something. Everything
# no bold, to keep the line lightweight on dark terminals.
COLOR_PROJECT=$'\033[38;5;208m' # orange
COLOR_GITINFO=$'\033[38;5;208m' # orange
COLOR_MUTED=$'\033[37m'   # gray
COLOR_GREEN=$'\033[32m'
COLOR_CYAN=$'\033[36m'
COLOR_YELLOW=$'\033[33m'
COLOR_COST=$'\033[38;5;178m' # for cost, a dark gold-yellow
COLOR_RED=$'\033[31m'
COLOR_BOLD_RED=$'\033[31m'
COLOR_SEP=$'\033[38;5;238m' # dim gray, for a subtle field separator
RESET=$'\033[0m'
SEP=" ${COLOR_SEP}|${RESET} "

if [ -n "$CLAUDE_JOB_DIR" ]; then
  mode_indicator="$(printf '%s\xe2\x97\x8b%s' "$COLOR_PROJECT" "$RESET")"
else
  mode_indicator="$(printf '%s\xe2\x97\x8f%s' "$COLOR_PROJECT" "$RESET")"
fi

pct_color() {
  local n
  n=$(awk -v p="$1" 'BEGIN { printf "%d", p }' 2>/dev/null)
  if [ "$n" -ge 80 ]; then
    printf '%s' "$COLOR_RED"
  elif [ "$n" -ge 50 ]; then
    printf '%s' "$COLOR_YELLOW"
  else
    printf '%s' "$COLOR_GREEN"
  fi
}

colorize_pct() {
  printf '%s%s%s' "$(pct_color "$1")" "$2" "$RESET"
}

model_color() {
  local m
  m=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$m" in
  *opus*) printf '%s' $'\033[38;5;135m' ;; # purple
  *fable*) printf '%s' $'\033[31m' ;;      # red
  *sonnet*) printf '%s' $'\033[94m' ;;     # bright blue
  *haiku*) printf '%s' $'\033[32m' ;;      # green
  *) printf '%s' $'\033[37m' ;;            # gray
  esac
}

limits=""
if [ -n "$five_pct" ]; then
  five_bar=$(make_bar "$five_pct" 6)
  seg="${COLOR_MUTED}5h ${RESET}$(colorize_pct "$five_pct" "$five_bar $(printf '%.0f' "$five_pct" 2>/dev/null)%")"
  if [ -n "$five_reset" ]; then
    seg="$seg ${COLOR_MUTED}($(fmt_duration $((${five_reset%.*} - now))))${RESET}"
  fi
  limits="$seg"
fi
if [ -n "$week_pct" ]; then
  week_bar=$(make_bar "$week_pct" 6)
  seg="${COLOR_MUTED}7d ${RESET}$(colorize_pct "$week_pct" "$week_bar $(printf '%.0f' "$week_pct" 2>/dev/null)%")"
  if [ -n "$week_reset" ]; then
    seg="$seg ${COLOR_MUTED}($(fmt_duration $((${week_reset%.*} - now))))${RESET}"
  fi
  limits="${limits:+$limits$SEP}$seg"
fi

out="$mode_indicator"
if [ -n "$project" ]; then
  seg="$(printf '%s%s%s' "$COLOR_PROJECT" "$project" "$RESET")"
  gitinfo="$branch"
  [ -n "$commit" ] && gitinfo="${gitinfo:+$gitinfo@}$commit"
  [ -n "$gitinfo" ] && seg="$seg $(printf '%s(%s)%s' "$COLOR_GITINFO" "$gitinfo" "$RESET")"
  out="${out:+$out }$seg"
elif [ -n "$branch" ]; then
  gitinfo="$branch"
  [ -n "$commit" ] && gitinfo="$gitinfo@$commit"
  out="${out:+$out }$(printf '%s(%s)%s' "$COLOR_GITINFO" "$gitinfo" "$RESET")"
fi
if [ -n "$model" ]; then
  mc="$(model_color "$model")"
  seg="$(printf '%s%s%s' "$mc" "$model" "$RESET")"
  if [ -n "$effort" ]; then
    seg="$seg $(printf '%s(%s)%s' "$mc" "$effort" "$RESET")"
  fi
  out="${out:+$out$SEP}$seg"
fi
if [ -n "$limits" ]; then
  out="${out:+$out$SEP}$limits"
fi
if [ -n "$bar" ]; then
  seg="${COLOR_MUTED}ctx ${RESET}$(colorize_pct "$used_pct" "$bar $ctx_pct")"
  out="${out:+$out$SEP}$seg"
fi
if [ -n "$in_tokens" ] || [ -n "$out_tokens" ]; then
  arrow_down=$(printf '\xe2\x86\x93')
  arrow_up=$(printf '\xe2\x86\x91')
  middle_dot=$(printf '\xc2\xb7')
  toks=""
  [ -n "$in_tokens" ] && toks="$(printf '%s%s %s%s' "$COLOR_CYAN" "$arrow_down" "$(fmt_tokens "$in_tokens")" "$RESET")"
  [ -n "$out_tokens" ] && toks="${toks:+$toks $(printf '%s%s%s' "$COLOR_SEP" "$middle_dot" "$RESET") }$(printf '%s%s %s%s' "$COLOR_CYAN" "$arrow_up" "$(fmt_tokens "$out_tokens")" "$RESET")"
  out="${out:+$out$SEP}$toks"
fi
if [ -n "$total_cost" ]; then
  seg="$(printf '%s%s%s' "$COLOR_COST" "$(fmt_cost "$total_cost")" "$RESET")"
  out="${out:+$out$SEP}$seg"
fi

printf '%s' "$out"
