#!/usr/bin/env bash
# claude-usage-bar — statusLine wrapper for Claude Code.
#
# Receives Claude Code's session JSON on stdin and combines:
#   - Output of the user's previous statusLine command (if any)
#   - Output of statusline.sh (the usage bar renderer)
#
# The session JSON is forwarded to both children so they can use the official
# Claude Code fields (rate_limits, context_window, model, etc).
#
# Hardening:
#   - Refuses symlinks on the prev-cmd file
#   - Caps prev-cmd at 512 bytes; strips control bytes before eval

set -u

PREV_CMD_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.usage-bar-prev-statusline"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Capture stdin once — both children need it
STDIN=$(cat)

# Run previous statusLine command, forwarding stdin
PREV_OUT=""
if [ -f "$PREV_CMD_FILE" ] && [ ! -L "$PREV_CMD_FILE" ]; then
  PREV_CMD=$(head -c 512 "$PREV_CMD_FILE" 2>/dev/null | tr -d '\000-\010\013-\037' | tr -d '\177')
  if [ -n "$PREV_CMD" ]; then
    PREV_OUT=$(printf '%s' "$STDIN" | eval "$PREV_CMD" 2>/dev/null || true)
  fi
fi

# Run usage bar renderer, forwarding stdin
USAGE_OUT=$(printf '%s' "$STDIN" | bash "${PLUGIN_DIR}/statusline.sh" 2>/dev/null || true)

# Combine: previous output, then usage bars on new lines
if [ -n "$PREV_OUT" ] && [ -n "$USAGE_OUT" ]; then
  printf '%s\n%s' "$PREV_OUT" "$USAGE_OUT"
elif [ -n "$PREV_OUT" ]; then
  printf '%s' "$PREV_OUT"
else
  printf '%s' "$USAGE_OUT"
fi
