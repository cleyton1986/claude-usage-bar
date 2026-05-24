#!/usr/bin/env bash
# claude-usage-bar — statusline renderer.
#
# Reads Claude Code's session JSON from stdin (official fields:
# context_window.*, rate_limits.*, model.*) and renders three lines:
#
#   CONTEXT -  <bar>  <pct>%  <tokens>/<window>  [sess:<output>]
#   Tokens session  <bar>  <pct>%  ↻ <reset>
#   Tokens Week     <bar>  <pct>%  ↻ <reset>
#
# Falls back to ~/.claude/.usage-bar-cache.json (written by update-usage.js)
# when stdin does not contain the expected fields — e.g. when the script
# is invoked manually or before the first API response of the session.
#
# Colors: green ≤70%, yellow 70–90%, red >90%.
# Requirements: bash >= 4, python3.

set -u

CACHE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.usage-bar-cache.json"

# Capture stdin (the JSON Claude Code passes to statusLine)
STDIN=$(cat 2>/dev/null || true)

PARSED=$(STDIN="$STDIN" CACHE="$CACHE" python3 <<'PYEOF'
import sys, json, os, datetime

def load_stdin():
    raw = os.environ.get("STDIN", "").strip()
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None

def load_cache():
    p = os.environ.get("CACHE", "")
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {}

def fmt(n):
    try:
        n = int(n or 0)
    except Exception:
        return "0"
    if n >= 1000000: return f"{n/1000000:.1f}M"
    if n >= 1000:    return f"{n/1000:.0f}k"
    return str(n)

def reset_str(value):
    if not value:
        return ""
    try:
        if isinstance(value, (int, float)):
            dt = datetime.datetime.fromtimestamp(value, tz=datetime.timezone.utc)
        else:
            dt = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        now = datetime.datetime.now(datetime.timezone.utc)
        mins = int((dt - now).total_seconds() / 60)
        if mins <= 0:
            return ""
        if mins < 60:
            return f"{mins}m"
        hours = mins // 60
        if hours < 24:
            return f"{hours}h"
        return f"{hours // 24}d"
    except Exception:
        return ""

stdin = load_stdin() or {}
cache = load_cache() or {}

# Context window — prefer stdin (official), fall back to cache
ctx = stdin.get("context_window") or {}
ctx_pct  = ctx.get("used_percentage")
ctx_win  = ctx.get("context_window_size")
ctx_in   = (ctx.get("total_input_tokens") or 0)
ctx_out  = (ctx.get("total_output_tokens") or 0)

if ctx_pct is None or ctx_win is None:
    c = cache.get("ctx") or {}
    ctx_pct = c.get("pct", 0)
    ctx_win = c.get("window", 200000)
    ctx_in  = c.get("tokens", 0)
    ctx_out = 0

ctx_tok_total = int(ctx_in) + int(ctx_out)
ctx_pct = int(round(float(ctx_pct or 0)))

# Session output tokens — from cache (hook-computed)
sess_out = (cache.get("session") or {}).get("outputTokens", 0)

# Rate limits — prefer stdin official, fall back to cache.quota
rl = stdin.get("rate_limits") or {}
five  = rl.get("five_hour") or {}
seven = rl.get("seven_day") or {}

if not five and not seven:
    q = cache.get("quota") or {}
    five  = q.get("fiveHour") or {}
    seven = q.get("sevenDay") or {}
    five_pct  = five.get("utilization")
    seven_pct = seven.get("utilization")
    five_reset_raw  = five.get("resets_at")
    seven_reset_raw = seven.get("resets_at")
else:
    five_pct  = five.get("used_percentage")
    seven_pct = seven.get("used_percentage")
    five_reset_raw  = five.get("resets_at")
    seven_reset_raw = seven.get("resets_at")

def pct_to_int(p):
    if p is None: return -1
    try: return int(round(float(p)))
    except: return -1

five_pct  = pct_to_int(five_pct)
seven_pct = pct_to_int(seven_pct)
five_reset  = reset_str(five_reset_raw)
seven_reset = reset_str(seven_reset_raw)

# Emit one field per line for shell to parse
print(ctx_pct)
print(fmt(ctx_tok_total))
print(fmt(ctx_win))
print(fmt(sess_out))
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

# Line 1 — CTX (always)
CTX_COLOR=$(color_for_pct "$CTX_PCT")
CTX_BAR=$(make_bar "$CTX_PCT" 10)
printf "${GRAY}CONTEXT -${RESET} ${CTX_COLOR}${CTX_BAR}${RESET} %3d%% ${GRAY}${CTX_TOK}/${CTX_WIN}${RESET} ${GRAY}[sess:${SESS_OUT}]${RESET}" "$CTX_PCT"

# Line 2 — 5H (only if available)
if [ -n "$FIVE_PCT" ] && [ "$FIVE_PCT" -ge 0 ]; then
  FIVE_COLOR=$(color_for_pct "$FIVE_PCT")
  FIVE_BAR=$(make_bar "$FIVE_PCT" 10)
  printf "\n${GRAY}Tokens session${RESET} ${FIVE_COLOR}${FIVE_BAR}${RESET} %3d%%" "$FIVE_PCT"
  [ -n "$FIVE_RESET" ] && printf " ${GRAY}↻ ${FIVE_RESET}${RESET}"
fi

# Line 3 — 7D (only if available)
if [ -n "$SEVEN_PCT" ] && [ "$SEVEN_PCT" -ge 0 ]; then
  SEVEN_COLOR=$(color_for_pct "$SEVEN_PCT")
  SEVEN_BAR=$(make_bar "$SEVEN_PCT" 10)
  printf "\n${GRAY}Tokens Week${RESET} ${SEVEN_COLOR}${SEVEN_BAR}${RESET} %3d%%" "$SEVEN_PCT"
  [ -n "$SEVEN_RESET" ] && printf " ${GRAY}↻ ${SEVEN_RESET}${RESET}"
fi
