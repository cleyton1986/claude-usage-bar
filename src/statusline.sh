#!/usr/bin/env bash
# claude-usage-bar — statusline renderer.
# Reads ~/.claude/.usage-bar-cache.json and renders:
#   CTX bar  — current session context window usage (always shown)
#   5H bar   — five-hour quota usage (claude.ai Pro/Max plans only)
#   7D bar   — seven-day quota usage (claude.ai Pro/Max plans only)
#
# Colors: green ≤70%, yellow 70–90%, red >90%
# Requirements: bash >= 4, python3

CACHE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.usage-bar-cache.json"

[ -L "$CACHE" ] && exit 0
[ ! -f "$CACHE" ] && exit 0

PARSED=$(python3 - "$CACHE" <<'PYEOF'
import sys, json

try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)

def fmt(n):
    n = int(n or 0)
    if n >= 1000000: return f"{n/1000000:.1f}M"
    if n >= 1000:    return f"{n/1000:.0f}k"
    return str(n)

ctx = d.get("ctx") or {}
ses = d.get("session") or {}
quota = d.get("quota") or {}

ctx_pct = int(ctx.get("pct", 0))
ctx_tok = fmt(ctx.get("tokens", 0))
ctx_win = fmt(ctx.get("window", 200000))
sess_out = fmt(ses.get("outputTokens", 0))

five = quota.get("fiveHour") or {}
seven = quota.get("sevenDay") or {}
five_pct = int(five.get("utilization", -1)) if five else -1
seven_pct = int(seven.get("utilization", -1)) if seven else -1

# resets_at to local short time
import datetime
def reset_str(iso):
    if not iso: return ""
    try:
        dt = datetime.datetime.fromisoformat(iso.replace("Z","+00:00"))
        dt_local = dt.astimezone()
        delta = dt_local - datetime.datetime.now().astimezone()
        mins = int(delta.total_seconds() / 60)
        if mins < 0: return ""
        if mins < 60: return f"{mins}m"
        hours = mins // 60
        if hours < 24: return f"{hours}h"
        return f"{hours//24}d"
    except Exception:
        return ""

five_reset = reset_str(five.get("resets_at"))
seven_reset = reset_str(seven.get("resets_at"))

print(ctx_pct)
print(ctx_tok)
print(ctx_win)
print(sess_out)
print(five_pct)
print(five_reset)
print(seven_pct)
print(seven_reset)
PYEOF
)

[ -z "$PARSED" ] && exit 0

IFS=$'\n' read -r -d '' CTX_PCT CTX_TOK CTX_WIN SESS_OUT FIVE_PCT FIVE_RESET SEVEN_PCT SEVEN_RESET _ <<< "$PARSED"$'\n\0'

make_bar() {
  local pct=$1
  local width=${2:-10}
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local bar=""
  local i
  for ((i=0; i<filled; i++)); do bar="${bar}█"; done
  for ((i=0; i<empty; i++)); do bar="${bar}░"; done
  printf '%s' "$bar"
}

color_for_pct() {
  local pct=$1
  if   [ "$pct" -le 70 ]; then printf '\033[32m'
  elif [ "$pct" -le 90 ]; then printf '\033[33m'
  else                          printf '\033[31m'
  fi
}

RESET='\033[0m'
GRAY='\033[90m'

# CTX bar — always shown
CTX_COLOR=$(color_for_pct "$CTX_PCT")
CTX_BAR=$(make_bar "$CTX_PCT" 10)
printf "${GRAY}CTX${RESET} ${CTX_COLOR}${CTX_BAR}${RESET} ${CTX_PCT}%% ${GRAY}${CTX_TOK}/${CTX_WIN}${RESET} ${GRAY}[sess:${SESS_OUT}]${RESET}"

# 5H bar — only when quota data present
if [ -n "$FIVE_PCT" ] && [ "$FIVE_PCT" -ge 0 ]; then
  FIVE_COLOR=$(color_for_pct "$FIVE_PCT")
  FIVE_BAR=$(make_bar "$FIVE_PCT" 8)
  printf "  ${GRAY}5H${RESET} ${FIVE_COLOR}${FIVE_BAR}${RESET} ${FIVE_PCT}%%"
  [ -n "$FIVE_RESET" ] && printf " ${GRAY}↻${FIVE_RESET}${RESET}"
fi

# 7D bar — only when quota data present
if [ -n "$SEVEN_PCT" ] && [ "$SEVEN_PCT" -ge 0 ]; then
  SEVEN_COLOR=$(color_for_pct "$SEVEN_PCT")
  SEVEN_BAR=$(make_bar "$SEVEN_PCT" 8)
  printf "  ${GRAY}7D${RESET} ${SEVEN_COLOR}${SEVEN_BAR}${RESET} ${SEVEN_PCT}%%"
  [ -n "$SEVEN_RESET" ] && printf " ${GRAY}↻${SEVEN_RESET}${RESET}"
fi
