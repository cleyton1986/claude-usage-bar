#!/usr/bin/env bash
# claude-usage-bar — statusLine wrapper for Claude Code.
#
# Called by Claude Code on every status update. Combines the user's previous
# statusLine output (e.g. caveman, ccusage) with this plugin's usage bars.
#
# Reads previous statusLine command from ~/.claude/.usage-bar-prev-statusline,
# runs it, and appends two color-coded usage bars (context + daily).
#
# Hardening:
#   - Refuses symlinks on the prev-cmd file (blocks redirect-to-secrets attacks)
#   - Caps prev-cmd at 512 bytes
#   - Strips control bytes from prev-cmd before eval

set -u

PREV_CMD_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.usage-bar-prev-statusline"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREV_OUT=""
if [ -f "$PREV_CMD_FILE" ] && [ ! -L "$PREV_CMD_FILE" ]; then
  # Read up to 512 bytes, strip control characters (block ANSI/escape injection)
  PREV_CMD=$(head -c 512 "$PREV_CMD_FILE" 2>/dev/null | tr -d '\000-\010\013-\037' | tr -d '\177')
  if [ -n "$PREV_CMD" ]; then
    PREV_OUT=$(eval "$PREV_CMD" 2>/dev/null || true)
  fi
fi

# Run usage bar renderer
USAGE_OUT=$(bash "${PLUGIN_DIR}/statusline.sh" 2>/dev/null || true)

# Combine outputs with two-space separator
if [ -n "$PREV_OUT" ] && [ -n "$USAGE_OUT" ]; then
  printf '%s  %s' "$PREV_OUT" "$USAGE_OUT"
elif [ -n "$PREV_OUT" ]; then
  printf '%s' "$PREV_OUT"
else
  printf '%s' "$USAGE_OUT"
fi
