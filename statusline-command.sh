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
fast_mode = "true" if data.get("fast_mode") else "false"

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

pc = data.get("prompt_cache", {}) or {}
cache_warm = pc.get("warm")
cache_warm = "" if cache_warm is None else ("true" if cache_warm else "false")
cache_expires_at = pc.get("expires_at")
cache_expires_at = "" if cache_expires_at is None else str(cache_expires_at)

for key, val in [("model", model), ("effort", effort), ("fast_mode", fast_mode), ("used_pct", used_pct), ("in_tokens", in_tokens), ("out_tokens", out_tokens), ("total_cost", total_cost), ("folder", folder), ("repo_name", repo_name), ("cwd", cwd), ("five_pct", five_pct), ("week_pct", week_pct), ("five_reset", five_reset), ("week_reset", week_reset), ("cache_warm", cache_warm), ("cache_expires_at", cache_expires_at)]:
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
  if [ -n "$branch" ]; then
    read -r g_dirty g_ahead g_behind <<<"$(
      git --no-optional-locks -C "$cwd" status --porcelain=v2 --branch 2>/dev/null | awk '
        /^# branch.ab / { a = substr($3, 2); b = substr($4, 2) }
        /^[12u?] / { d = 1 }
        END { printf "%d %d %d", d, a, b }'
    )"
  fi
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

THB_RATE_TTL=43200 # 12h; live rate is cached for this long before refetching
THB_RATE_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/thb_rate.cache"

# Prints a THB rate: cached value if fresh, else refetches and re-caches it.
# Prints nothing on any failure (no curl, no network, bad response) so the
# THB segment just disappears rather than showing a stale/wrong number.
# Network calls are capped at 2s so an unreachable API never stalls the
# statusline for long.
get_thb_rate() {
  local rate="" mtime now_ts

  if [ -f "$THB_RATE_CACHE" ]; then
    mtime=$(stat -c %Y "$THB_RATE_CACHE" 2>/dev/null || stat -f %m "$THB_RATE_CACHE" 2>/dev/null)
    now_ts=$(date +%s)
    if [ -n "$mtime" ] && [ $((now_ts - mtime)) -lt "$THB_RATE_TTL" ]; then
      rate=$(cat "$THB_RATE_CACHE" 2>/dev/null)
    fi
  fi

  if [ -z "$rate" ] && command -v curl >/dev/null 2>&1; then
    rate=$(curl -s --max-time 2 "https://open.er-api.com/v6/latest/USD" 2>/dev/null |
      python3 -c '
import json, sys
try:
    r = json.load(sys.stdin).get("rates", {}).get("THB")
    if r:
        print(r)
except Exception:
    pass
' 2>/dev/null)
    if [ -n "$rate" ]; then
      mkdir -p "$(dirname "$THB_RATE_CACHE")" 2>/dev/null
      printf '%s' "$rate" >"$THB_RATE_CACHE" 2>/dev/null
    fi
  fi

  printf '%s' "$rate"
}

fmt_cost_thb() {
  local rate
  rate=$(get_thb_rate)
  [ -z "$rate" ] && return
  awk -v n="$1" -v r="$rate" 'BEGIN {
    v = n * r;
    if (v < 100) printf "\xe0\xb8\xbf%.2f", v;
    else printf "\xe0\xb8\xbf%.0f", v;
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
MIDDLE_DOT=$(printf '\xc2\xb7')

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

# Severity by time remaining (inverse of pct_color: less time left = worse).
time_left_color() {
  local secs=$1
  if [ "$secs" -le 300 ]; then
    printf '%s' "$COLOR_RED"
  elif [ "$secs" -le 900 ]; then
    printf '%s' "$COLOR_YELLOW"
  else
    printf '%s' "$COLOR_GREEN"
  fi
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

git_state=""
[ "${g_dirty:-0}" -gt 0 ] && git_state="${git_state:+$git_state }${COLOR_GITINFO}*${RESET}"
[ "${g_ahead:-0}" -gt 0 ] && git_state="${git_state:+$git_state }${COLOR_GITINFO}⇡${g_ahead}${RESET}"
[ "${g_behind:-0}" -gt 0 ] && git_state="${git_state:+$git_state }${COLOR_GITINFO}⇣${g_behind}${RESET}"

# Segments are collected into an array (rather than one joined string) so
# they can be greedily wrapped across lines when $COLUMNS is too narrow.
segs=()

seg="$mode_indicator"
gitinfo=""
if [ -n "$branch" ]; then
  gitinfo="$branch"
  [ -n "$commit" ] && gitinfo="$gitinfo@$commit"
  gitinfo="$(printf '%s(%s)%s' "$COLOR_GITINFO" "$gitinfo" "$RESET")"
fi
if [ -n "$project" ]; then
  proj="$(printf '%s%s%s' "$COLOR_PROJECT" "$project" "$RESET")"
  [ -n "$gitinfo" ] && proj="$proj $gitinfo"
  [ -n "$git_state" ] && proj="$proj $git_state"
  seg="$seg $proj"
elif [ -n "$gitinfo" ]; then
  [ -n "$git_state" ] && gitinfo="$gitinfo $git_state"
  seg="$seg $gitinfo"
fi
segs+=("$seg")

model_idx=-1
if [ -n "$model" ]; then
  mc="$(model_color "$model")"
  seg="$(printf '%s%s%s' "$mc" "$model" "$RESET")"
  if [ "$fast_mode" = "true" ]; then
    seg="$seg $(printf '%s\xe2\x86\xaf%s' "$mc" "$RESET")"
  fi
  if [ -n "$effort" ]; then
    seg="$seg $(printf '%s(%s)%s' "$mc" "$effort" "$RESET")"
  fi
  segs+=("$seg")
  model_idx=$((${#segs[@]} - 1))
fi
if [ -n "$in_tokens" ] || [ -n "$out_tokens" ]; then
  arrow_down=$(printf '\xe2\x86\x93')
  arrow_up=$(printf '\xe2\x86\x91')
  toks=""
  [ -n "$in_tokens" ] && toks="$(printf '%s%s %s%s' "$COLOR_CYAN" "$arrow_down" "$(fmt_tokens "$in_tokens")" "$RESET")"
  [ -n "$out_tokens" ] && toks="${toks:+$toks $(printf '%s%s%s' "$COLOR_CYAN" "$MIDDLE_DOT" "$RESET") }$(printf '%s%s %s%s' "$COLOR_CYAN" "$arrow_up" "$(fmt_tokens "$out_tokens")" "$RESET")"
  segs+=("$toks")
fi
cost_idx=-1
if [ -n "$total_cost" ]; then
  thb="$(fmt_cost_thb "$total_cost")"
  seg="$(printf '%s%s%s' "$COLOR_COST" "$(fmt_cost "$total_cost")" "$RESET")"
  [ -n "$thb" ] && seg="$seg $(printf '%s(%s)%s' "$COLOR_COST" "$thb" "$RESET")"
  segs+=("$seg")
  cost_idx=$((${#segs[@]} - 1))
fi
[ -n "$limits" ] && segs+=("$limits")
if [ -n "$bar" ]; then
  segs+=("${COLOR_MUTED}ctx ${RESET}$(colorize_pct "$used_pct" "$bar $ctx_pct")")
fi
if [ "$cache_warm" = "true" ] && [ -n "$cache_expires_at" ]; then
  cache_left=$((${cache_expires_at%.*} - now))
  if [ "$cache_left" -gt 0 ]; then
    segs+=("${COLOR_MUTED}cache ${RESET}$(time_left_color "$cache_left")$(fmt_duration "$cache_left")${RESET}")
  fi
fi

# Claude Code doesn't connect this script to the terminal (tput/stty can't
# see it), but it sets $COLUMNS to the terminal width before running us.
vislen() {
  printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g' | wc -m
}

term_width="${COLUMNS:-0}"
case "$term_width" in '' | *[!0-9]*) term_width=0 ;; esac

# Greedily packs the given segments into $lines, wrapping whenever the next
# segment would overflow $term_width.
pack_group() {
  local line="" seg candidate
  for seg in "$@"; do
    [ -z "$seg" ] && continue
    if [ -z "$line" ]; then
      line="$seg"
    else
      candidate="$line$SEP$seg"
      if [ "$term_width" -gt 0 ] && [ "$(vislen "$candidate")" -gt "$term_width" ]; then
        lines+=("$line")
        line="$seg"
      else
        line="$candidate"
      fi
    fi
  done
  [ -n "$line" ] && lines+=("$line")
}

full_joined=""
for seg in "${segs[@]}"; do
  [ -z "$seg" ] && continue
  full_joined="${full_joined:+$full_joined$SEP}$seg"
done

lines=()
if [ "$cost_idx" -ge 0 ] && [ "$term_width" -gt 0 ] && [ "$(vislen "$full_joined")" -gt "$term_width" ]; then
  # Doesn't fit on one line: force the break right after the cost segment
  # rather than wherever the greedy pack would otherwise land it.
  group1_joined=""
  for seg in "${segs[@]:0:$((cost_idx + 1))}"; do
    [ -z "$seg" ] && continue
    group1_joined="${group1_joined:+$group1_joined$SEP}$seg"
  done
  if [ "$model_idx" -ge 0 ] && [ "$(vislen "$group1_joined")" -gt "$term_width" ]; then
    # Still doesn't fit in two lines: force a third break right before the
    # model segment rather than wherever the greedy pack would land it.
    pack_group "${segs[@]:0:$model_idx}"
    pack_group "${segs[@]:$model_idx:$((cost_idx + 1 - model_idx))}"
  else
    pack_group "${segs[@]:0:$((cost_idx + 1))}"
  fi
  pack_group "${segs[@]:$((cost_idx + 1))}"
else
  pack_group "${segs[@]}"
fi

printf '%s' "${lines[0]}"
for ((i = 1; i < ${#lines[@]}; i++)); do
  printf '\n%s' "${lines[$i]}"
done
