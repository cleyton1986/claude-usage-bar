#!/usr/bin/env bash
# claude-usage-bar — statusline renderer.
#
# Reads Claude Code's session JSON from stdin (official fields:
# context_window.*, rate_limits.*, model.*) and renders three lines:
#
#   CONTEXT(Model)  <bar>  <pct>%  <tokens>/<window>  [sess:<output>]
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

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CACHE="$CLAUDE_DIR/.usage-bar-cache.json"
CONFIG="$CLAUDE_DIR/.usage-bar-config.json"

# Capture stdin (the JSON Claude Code passes to statusLine)
STDIN=$(cat 2>/dev/null || true)

PARSED=$(STDIN="$STDIN" CACHE="$CACHE" CONFIG="$CONFIG" python3 <<'PYEOF'
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

def load_config():
    p = os.environ.get("CONFIG", "")
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {}

def short_model(model):
    if not model:
        return ""
    import re
    m = re.sub(r'-\d{8}$', '', model)
    parts = m.split('-')
    if len(parts) >= 4 and parts[0] == "claude":
        family = parts[1].capitalize()
        version = '-'.join(parts[2:])
        return f"{family}-{version}"
    return m

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
config = load_config() or {}

bar_width = int(config.get("bar_width", 10) or 10)
bar_width = max(4, min(40, bar_width))
show_context = bool(config.get("show_context", True))
show_session = bool(config.get("show_session", True))
show_week = bool(config.get("show_week", True))

def latest_model_from_transcript(path):
    """Read last model from JSONL — most recent non-tool assistant entry."""
    if not path:
        return ""
    import os as _os
    if not _os.path.exists(path):
        return ""
    last = ""
    try:
        with open(path, 'rb') as f:
            # Tail last 32 KB — enough for recent entries
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 32768))
            tail = f.read().decode('utf-8', errors='replace')
        for line in reversed(tail.splitlines()):
            if not line.strip():
                continue
            try:
                d = json.loads(line)
                m = (d.get('message') or {}).get('model')
                if m and m != 'unknown':
                    last = m
                    break
            except Exception:
                continue
    except Exception:
        pass
    return last

model = ""
# 1. transcript JSONL is freshest when OmniRouter rewrites/reroutes models
#    (stdin.model can stay fixed at Claude Code's configured model)
tp = cache.get("transcriptPath") or ""
model = latest_model_from_transcript(tp)
# 2. stdin official field
if not model:
    if isinstance(stdin.get("model"), dict):
        model = stdin.get("model", {}).get("id") or stdin.get("model", {}).get("name") or ""
    elif stdin.get("model"):
        model = str(stdin.get("model"))
# 3. fallback: cache (may lag one turn)
if not model:
    model = cache.get("model") or ""
model = short_model(model)

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

# Build labels with padding so bars align
ctx_label_raw = f"CONTEXT({model})" if model else "CONTEXT"
fixed_labels  = ["Tokens session", "Tokens Week"]
col_width = max(len(ctx_label_raw), max(len(l) for l in fixed_labels))
if model:
    ctx_prefix = "CONTEXT("
    ctx_model = model
    ctx_suffix = ")" + " " * (col_width - len(ctx_label_raw))
else:
    ctx_prefix = "CONTEXT"
    ctx_model = ""
    ctx_suffix = " " * (col_width - len(ctx_prefix))
session_label  = "Tokens session".ljust(col_width)
week_label     = "Tokens Week".ljust(col_width)

# Emit one field per line for shell to parse
print(ctx_pct)
print(fmt(ctx_tok_total))
print(fmt(ctx_win))
print(fmt(sess_out))
print(five_pct)
print(five_reset)
print(seven_pct)
print(seven_reset)
print(bar_width)
print(1 if show_context else 0)
print(1 if show_session else 0)
print(1 if show_week else 0)
print(ctx_prefix)
print(ctx_model)
print(ctx_suffix)
print(session_label)
print(week_label)
PYEOF
)

[ -z "$PARSED" ] && exit 0

IFS=$'\n' read -r -d '' CTX_PCT CTX_TOK CTX_WIN SESS_OUT FIVE_PCT FIVE_RESET SEVEN_PCT SEVEN_RESET BAR_WIDTH SHOW_CONTEXT SHOW_SESSION SHOW_WEEK CTX_PREFIX CTX_MODEL CTX_SUFFIX SESSION_LABEL WEEK_LABEL _ <<< "$PARSED"$'\n\0'

make_bar() {
  local pct=$1
  local width=${BAR_WIDTH:-10}
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
RED='\033[31m'

NEEDS_NEWLINE=0

if [ "${SHOW_CONTEXT:-1}" = "1" ]; then
  CTX_COLOR=$(color_for_pct "$CTX_PCT")
  CTX_BAR=$(make_bar "$CTX_PCT")
  printf "${GRAY}${CTX_PREFIX}${RESET}${RED}${CTX_MODEL}${RESET}${GRAY}${CTX_SUFFIX}${RESET} ${CTX_COLOR}${CTX_BAR}${RESET} %3d%% ${GRAY}${CTX_TOK}/${CTX_WIN}${RESET} ${GRAY}[sess:${SESS_OUT}]${RESET}" "$CTX_PCT"
  NEEDS_NEWLINE=1
fi

if [ "${SHOW_SESSION:-1}" = "1" ] && [ -n "$FIVE_PCT" ] && [ "$FIVE_PCT" -ge 0 ]; then
  FIVE_COLOR=$(color_for_pct "$FIVE_PCT")
  FIVE_BAR=$(make_bar "$FIVE_PCT")
  [ "$NEEDS_NEWLINE" = "1" ] && printf "\n"
  printf "${GRAY}${SESSION_LABEL}${RESET} ${FIVE_COLOR}${FIVE_BAR}${RESET} %3d%%" "$FIVE_PCT"
  [ -n "$FIVE_RESET" ] && printf " ${GRAY}↻ ${FIVE_RESET}${RESET}"
  NEEDS_NEWLINE=1
fi

if [ "${SHOW_WEEK:-1}" = "1" ] && [ -n "$SEVEN_PCT" ] && [ "$SEVEN_PCT" -ge 0 ]; then
  SEVEN_COLOR=$(color_for_pct "$SEVEN_PCT")
  SEVEN_BAR=$(make_bar "$SEVEN_PCT")
  [ "$NEEDS_NEWLINE" = "1" ] && printf "\n"
  printf "${GRAY}${WEEK_LABEL}${RESET} ${SEVEN_COLOR}${SEVEN_BAR}${RESET} %3d%%" "$SEVEN_PCT"
  [ -n "$SEVEN_RESET" ] && printf " ${GRAY}↻ ${SEVEN_RESET}${RESET}"
fi
