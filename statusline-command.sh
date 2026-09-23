#!/bin/bash
# Claude Code statusline: project/git, model/effort, tokens, cost, 5h/7d rate
# limits, context window and prompt-cache countdown. Segments are grouped into
# three rows that wrap onto separate lines when $COLUMNS is too narrow.

shopt -s extglob

eval "$(python3 -c '
import json, shlex, sys

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

def get(*path):
    # "" for anything missing or null, at any depth.
    node = data
    for key in path:
        node = node.get(key) if isinstance(node, dict) else None
    return "" if node is None else node

project_dir = str(get("workspace", "project_dir"))
cache_warm = get("prompt_cache", "warm")

fields = {
    "model": get("model", "display_name"),
    "effort": get("effort", "level"),
    "fast_mode": "true" if get("fast_mode") else "false",
    "used_pct": get("context_window", "used_percentage"),
    "in_tokens": get("context_window", "total_input_tokens"),
    "out_tokens": get("context_window", "total_output_tokens"),
    "total_cost": get("cost", "total_cost_usd"),
    "cwd": get("workspace", "current_dir"),
    "folder": project_dir.rstrip("/").split("/")[-1],
    "repo_name": get("workspace", "repo", "name"),
    "five_pct": get("rate_limits", "five_hour", "used_percentage"),
    "five_reset": get("rate_limits", "five_hour", "resets_at"),
    "week_pct": get("rate_limits", "seven_day", "used_percentage"),
    "week_reset": get("rate_limits", "seven_day", "resets_at"),
    "cache_warm": "" if cache_warm == "" else ("true" if cache_warm else "false"),
    "cache_expires_at": get("prompt_cache", "expires_at"),
}
for key, val in fields.items():
    print(f"{key}={shlex.quote(str(val))}")
')"

cwd=${cwd:-$PWD}
project=${repo_name:-$folder}
now=$(date +%s)

# One `git status` call yields branch, commit, dirty flag and ahead/behind.
# Fields are \037-separated so an empty commit (no commits yet) doesn't shift
# the rest, as whitespace splitting would.
branch="" commit="" g_dirty=0 g_ahead=0 g_behind=0
if command -v git >/dev/null 2>&1; then
  IFS=$'\037' read -r branch commit g_dirty g_ahead g_behind <<<"$(
    git --no-optional-locks -C "$cwd" status --porcelain=v2 --branch 2>/dev/null | awk '
      /^# branch.oid / { oid = $3 }
      /^# branch.head / { head = $3 }
      /^# branch.ab / { a = substr($3, 2); b = substr($4, 2) }
      /^[12u?] / { d = 1 }
      END {
        if (head == "(detached)") head = "HEAD"
        if (oid == "(initial)") oid = ""
        printf "%s\037%s\037%d\037%d\037%d", head, substr(oid, 1, 7), d, a, b
      }'
  )"
fi

# Palette: the project name and (branch@commit) share one orange so they read
# as a single unit; model name and effort share one family-based color for the
# same reason. Labels are neutral gray, and bars/percentages are colored by
# severity (green/yellow/red) so color on the line always means something. No
# bold anywhere, to keep the line light on dark terminals.
COLOR_PROJECT=$'\e[38;5;208m' # orange
COLOR_GITINFO=$'\e[38;5;208m' # orange
COLOR_MUTED=$'\e[37m'         # gray
COLOR_GREEN=$'\e[32m'
COLOR_YELLOW=$'\e[33m'
COLOR_RED=$'\e[31m'
COLOR_CYAN=$'\e[36m'
COLOR_COST=$'\e[38;5;178m' # dark gold-yellow
COLOR_SEP=$'\e[38;5;238m'  # dim gray, for a subtle field separator
RESET=$'\e[0m'
SEP=" ${COLOR_SEP}|${RESET} "

pct_color() {
  if [ "$1" -ge 80 ]; then
    printf '%s' "$COLOR_RED"
  elif [ "$1" -ge 50 ]; then
    printf '%s' "$COLOR_YELLOW"
  else
    printf '%s' "$COLOR_GREEN"
  fi
}

# Severity by time remaining (inverse of pct_color: less time left = worse).
time_left_color() {
  if [ "$1" -le 300 ]; then
    printf '%s' "$COLOR_RED"
  elif [ "$1" -le 900 ]; then
    printf '%s' "$COLOR_YELLOW"
  else
    printf '%s' "$COLOR_GREEN"
  fi
}

model_color() {
  shopt -s nocasematch
  case "$1" in
  *opus*) printf '%s' $'\e[38;5;135m' ;; # purple
  *fable*) printf '%s' $'\e[31m' ;;      # red
  *sonnet*) printf '%s' $'\e[94m' ;;     # bright blue
  *haiku*) printf '%s' $'\e[32m' ;;      # green
  *) printf '%s' $'\e[37m' ;;            # gray
  esac
}

make_bar() {
  local pct=$1 width=$2 filled i bar=""
  filled=$(((pct * width + 50) / 100))
  ((filled < 0)) && filled=0
  ((filled > width)) && filled=$width
  for ((i = 0; i < width; i++)); do
    if ((i < filled)); then bar+="━"; else bar+="─"; fi
  done
  printf '%s' "$bar"
}

fmt_duration() {
  local secs=$1
  [ "$secs" -lt 0 ] && secs=0
  local d=$((secs / 86400)) h=$(((secs % 86400) / 3600)) m=$(((secs % 3600) / 60))
  if [ "$d" -gt 0 ]; then
    printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh%dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

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
  local rate="" mtime

  if [ -f "$THB_RATE_CACHE" ]; then
    mtime=$(stat -c %Y "$THB_RATE_CACHE" 2>/dev/null || stat -f %m "$THB_RATE_CACHE" 2>/dev/null)
    if [ -n "$mtime" ] && [ $((now - mtime)) -lt "$THB_RATE_TTL" ]; then
      rate=$(<"$THB_RATE_CACHE")
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
      printf '%s' "$rate" 2>/dev/null >"$THB_RATE_CACHE"
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
    if (v < 100) printf "฿%.2f", v;
    else printf "฿%.0f", v;
  }'
}

# Visible width of $1 in REPLY: ANSI color codes stripped, and UTF-8
# continuation bytes dropped so multibyte glyphs count as one column whatever
# the caller's locale (under C/POSIX, ${#var} would count bytes).
visible_width() {
  local LC_ALL=C
  local plain=${1//$'\e['*([0-9;])m/}
  plain=${plain//[$'\x80'-$'\xbf']/}
  REPLY=${#plain}
}

# Segments go into parallel arrays tagged with their row, so the layout step
# below can wrap whole rows onto separate lines when the terminal is narrow:
#   row 0: session/project/git   row 1: model, tokens, cost
#   row 2: rate limits, context window, prompt cache
segs=() widths=() rows=()
add_seg() {
  visible_width "$2"
  segs+=("$2") widths+=("$REPLY") rows+=("$1")
}

# "label ━━━─── 42%" colored by severity, plus "(time to reset)" if given.
pct_seg() {
  local label=$1 pct reset=$3 seg
  printf -v pct '%.0f' "$2"
  seg="${COLOR_MUTED}$label ${RESET}$(pct_color "$pct")$(make_bar "$pct" 6) $pct%${RESET}"
  [ -n "$reset" ] && seg+=" ${COLOR_MUTED}($(fmt_duration $((${reset%.*} - now))))${RESET}"
  add_seg 2 "$seg"
}

if [ -n "$CLAUDE_JOB_DIR" ]; then
  seg="${COLOR_PROJECT}○${RESET}"
else
  seg="${COLOR_PROJECT}●${RESET}"
fi
[ -n "$project" ] && seg+=" ${COLOR_PROJECT}$project${RESET}"
if [ -n "$branch" ]; then
  git_part="($branch${commit:+@$commit})"
  [ "$g_dirty" -gt 0 ] && git_part+=" *"
  [ "$g_ahead" -gt 0 ] && git_part+=" ⇡$g_ahead"
  [ "$g_behind" -gt 0 ] && git_part+=" ⇣$g_behind"
  seg+=" ${COLOR_GITINFO}$git_part${RESET}"
fi
add_seg 0 "$seg"

if [ -n "$model" ]; then
  seg=$model
  [ "$fast_mode" = true ] && seg+=" ↯"
  [ -n "$effort" ] && seg+=" ($effort)"
  add_seg 1 "$(model_color "$model")$seg${RESET}"
fi
if [ -n "$in_tokens" ] || [ -n "$out_tokens" ]; then
  seg=""
  [ -n "$in_tokens" ] && seg="↓ $(fmt_tokens "$in_tokens")"
  [ -n "$out_tokens" ] && seg+="${seg:+ · }↑ $(fmt_tokens "$out_tokens")"
  add_seg 1 "${COLOR_CYAN}$seg${RESET}"
fi
if [ -n "$total_cost" ]; then
  seg=$(fmt_cost "$total_cost")
  thb=$(fmt_cost_thb "$total_cost")
  [ -n "$thb" ] && seg+=" ($thb)"
  add_seg 1 "${COLOR_COST}$seg${RESET}"
fi

[ -n "$five_pct" ] && pct_seg 5h "$five_pct" "$five_reset"
[ -n "$week_pct" ] && pct_seg 7d "$week_pct" "$week_reset"
[ -n "$used_pct" ] && pct_seg ctx "$used_pct"
if [ "$cache_warm" = true ] && [ -n "$cache_expires_at" ]; then
  cache_left=$((${cache_expires_at%.*} - now))
  [ "$cache_left" -gt 0 ] &&
    add_seg 2 "${COLOR_MUTED}cache ${RESET}$(time_left_color "$cache_left")$(fmt_duration "$cache_left")${RESET}"
fi

# Claude Code doesn't connect this script to the terminal (tput/stty can't
# see it), but it sets $COLUMNS to the terminal width before running us.
term_width=${COLUMNS:-0}
case "$term_width" in *[!0-9]*) term_width=0 ;; esac
visible_width "$SEP"
sep_w=$REPLY

# Width of rows $1..$2 laid out on a single line, in REPLY.
rows_width() {
  local i w=0 n=0
  for i in "${!segs[@]}"; do
    ((rows[i] >= $1 && rows[i] <= $2)) || continue
    w=$((w + widths[i]))
    n=$((n + 1))
  done
  REPLY=$((n > 1 ? w + (n - 1) * sep_w : w))
}

# Map each row to an output line: everything on one line if it fits, else
# break after row 1 (cost), else after rows 0 and 1 (before the model).
rows_width 0 2
all_w=$REPLY
rows_width 0 1
top_w=$REPLY
if ((term_width == 0 || all_w <= term_width)); then
  line_of_row=(0 0 0)
elif ((top_w <= term_width)); then
  line_of_row=(0 0 1)
else
  line_of_row=(0 1 2)
fi

# Pack segments into lines. A row that alone overflows still wraps greedily.
lines=() line="" line_w=0 prev=0
for i in "${!segs[@]}"; do
  cur=${line_of_row[rows[i]]}
  w=${widths[i]}
  if [ -n "$line" ] && ((cur == prev)) && ((term_width == 0 || line_w + sep_w + w <= term_width)); then
    line+="$SEP${segs[i]}"
    line_w=$((line_w + sep_w + w))
  else
    [ -n "$line" ] && lines+=("$line")
    line=${segs[i]}
    line_w=$w
  fi
  prev=$cur
done
lines+=("$line")

IFS=$'\n'
printf '%s' "${lines[*]}"
