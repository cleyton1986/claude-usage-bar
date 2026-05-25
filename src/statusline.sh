#!/usr/bin/env bash
# claude-usage-bar — statusline renderer (real-time, no cached data).

set -u

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CACHE="$CLAUDE_DIR/.usage-bar-cache.json"
CONFIG="$CLAUDE_DIR/.usage-bar-config.json"
STDIN=$(cat 2>/dev/null || true)

STDIN="$STDIN" CLAUDE_DIR="$CLAUDE_DIR" CACHE="$CACHE" CONFIG="$CONFIG" python3 <<'PYEOF'
import json
import os
import re
import datetime

RESET = '\033[0m'
GRAY = '\033[90m'
RED = '\033[31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'


def load_stdin():
    raw = os.environ.get('STDIN', '').strip()
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except Exception:
        return {}


def load_config():
    try:
        with open(os.environ.get('CONFIG', '')) as f:
            return json.load(f)
    except Exception:
        return {}


def load_cache():
    try:
        with open(os.environ.get('CACHE', '')) as f:
            return json.load(f)
    except Exception:
        return {}


def fmt(n):
    try:
        n = int(n or 0)
    except Exception:
        return '0'
    if n >= 1000000:
        return f'{n / 1000000:.1f}M'
    if n >= 1000:
        return f'{n / 1000:.0f}k'
    return str(n)


def reset_str(value):
    if not value:
        return ''
    try:
        if isinstance(value, (int, float)):
            dt = datetime.datetime.fromtimestamp(value, tz=datetime.timezone.utc)
        else:
            dt = datetime.datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        now = datetime.datetime.now(datetime.timezone.utc)
        mins = int((dt - now).total_seconds() / 60)
        if mins <= 0:
            return ''
        if mins < 60:
            return f'{mins}m'
        hours = mins // 60
        if hours < 24:
            return f'{hours}h'
        return f'{hours // 24}d'
    except Exception:
        return ''


def pct_to_int(p):
    if p is None:
        return -1
    try:
        return int(round(float(p)))
    except Exception:
        return -1


def color_for_pct(pct):
    if pct <= 70:
        return GREEN
    if pct <= 90:
        return YELLOW
    return RED


def make_bar(pct, width):
    pct = max(0, min(100, int(pct or 0)))
    filled = pct * width // 100
    return '█' * filled + '░' * (width - filled)


def ctx_window_for_model(model):
    if not model:
        return 200000
    m = model.lower()
    # explicit 1M suffix variants
    if '[1m]' in m or '-1m' in m:
        return 1000000
    # claude 4: opus-4.x always 1M; sonnet-4.6+ is 1M; sonnet/haiku-4.5 is 200k
    if re.match(r'claude-opus-4', m):
        return 1000000
    if re.match(r'claude-sonnet-4-[6-9]', m):
        return 1000000
    if re.match(r'claude-sonnet-4-\d\d', m) and not re.match(r'claude-sonnet-4-[0-5]', m):
        return 1000000
    # claude-3.x and all others: 200k
    return 200000


def short_model(model):
    if not model:
        return ''
    model = re.sub(r'-\d{8}$', '', str(model))
    parts = model.split('-')
    if len(parts) >= 4 and parts[0] == 'claude':
        return f'{parts[1].capitalize()}-{"-".join(parts[2:])}'
    return model


def find_latest_transcript(claude_dir):
    root = os.path.join(claude_dir, 'projects')
    if not os.path.isdir(root):
        return ''
    latest = ('', -1)
    for base, _, files in os.walk(root):
        for name in files:
            if not name.endswith('.jsonl'):
                continue
            p = os.path.join(base, name)
            try:
                mtime = os.path.getmtime(p)
            except Exception:
                continue
            if mtime > latest[1]:
                latest = (p, mtime)
    return latest[0]


def latest_model_from_transcript(path):
    if not path or not os.path.exists(path):
        return ''
    try:
        with open(path, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 65536))
            tail = f.read().decode('utf-8', errors='replace')
        for line in reversed(tail.splitlines()):
            if not line.strip():
                continue
            try:
                data = json.loads(line)
                model = (data.get('message') or {}).get('model')
                if model and model != 'unknown':
                    return model
            except Exception:
                continue
    except Exception:
        pass
    return ''


def read_transcript_usage(path):
    if not path or not os.path.exists(path):
        return {}
    last_usage = None
    last_model = None
    session_output = 0
    try:
        with open(path, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 65536))
            tail = f.read().decode('utf-8', errors='replace')
        for line in tail.splitlines():
            if not line.strip():
                continue
            try:
                data = json.loads(line)
                msg = data.get('message')
                if msg and msg.get('role') == 'assistant' and msg.get('usage'):
                    last_usage = msg['usage']
                    last_model = msg.get('model')
                    session_output += msg['usage'].get('output_tokens', 0)
            except Exception:
                continue
    except Exception:
        pass
    if not last_usage:
        return {}
    return {'usage': last_usage, 'model': last_model, 'sessionOutput': session_output}


def fetch_oauth_usage(claude_dir):
    """Fetch quota from Anthropic OAuth endpoint — real-time."""
    import urllib.request
    creds_path = os.path.join(claude_dir, '.credentials.json')
    try:
        with open(creds_path) as f:
            creds = json.load(f)
    except Exception:
        return None
    oauth = creds.get('claudeAiOauth') or {}
    token = oauth.get('accessToken')
    if not token:
        return None
    try:
        req = urllib.request.Request(
            'https://api.anthropic.com/api/oauth/usage',
            headers={
                'Authorization': f'Bearer {token}',
                'anthropic-beta': 'oauth-2025-04-20',
                'Accept': 'application/json',
                'User-Agent': 'claude-usage-bar/1.0',
            }
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())
    except Exception:
        return None


def bool_cfg(config, key, default=True):
    value = config.get(key, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() not in ('0', 'false', 'no', 'off')
    return bool(value)


# --- Main ---
claude_dir = os.environ.get('CLAUDE_DIR', os.path.expanduser('~/.claude'))
stdin = load_stdin()
config = load_config()
cache = load_cache()

try:
    bar_width = int(config.get('bar_width', 10) or 10)
except Exception:
    bar_width = 10
bar_width = max(4, min(40, bar_width))
show_context = bool_cfg(config, 'show_context', True)
show_session = bool_cfg(config, 'show_session', True)
show_week = bool_cfg(config, 'show_week', True)

transcript = find_latest_transcript(claude_dir)

# --- Model: real-time from transcript ---
raw_model = latest_model_from_transcript(transcript)
if not raw_model:
    stdin_model = stdin.get('model')
    if isinstance(stdin_model, dict):
        raw_model = stdin_model.get('id') or stdin_model.get('name') or ''
    elif stdin_model:
        raw_model = str(stdin_model)
model = short_model(raw_model)

# --- Context: real-time from transcript ---
ctx_pct = None
ctx_win = None
ctx_total = 0
sess_out = 0

stdin_ctx = stdin.get('context_window') or {}
if stdin_ctx.get('used_percentage') is not None:
    ctx_pct = stdin_ctx.get('used_percentage')
    stdin_win = stdin_ctx.get('context_window_size') or 0
    model_win = ctx_window_for_model(raw_model)
    ctx_win = max(stdin_win, model_win)
    ctx_total = (stdin_ctx.get('total_input_tokens') or 0) + (stdin_ctx.get('total_output_tokens') or 0)
    if ctx_win > stdin_win and ctx_total > 0:
        ctx_pct = min(100, (ctx_total / ctx_win) * 100)

if ctx_pct is None and transcript:
    td = read_transcript_usage(transcript)
    if td:
        u = td['usage']
        ctx_win = ctx_window_for_model(td.get('model') or raw_model)
        ctx_total = (u.get('input_tokens') or 0) + (u.get('cache_read_input_tokens') or 0) + (u.get('cache_creation_input_tokens') or 0)
        if ctx_total > ctx_win:
            ctx_win = 1000000
        ctx_pct = min(100, (ctx_total / ctx_win) * 100) if ctx_win else 0
        sess_out = td['sessionOutput']

# session output from cache if not from transcript
if not sess_out:
    sess_out = (cache.get('session') or {}).get('outputTokens', 0)

ctx_pct = pct_to_int(ctx_pct or 0)

# --- Rate limits: real-time from stdin, then OAuth ---
rate_limits = stdin.get('rate_limits') or stdin.get('rateLimits') or {}
five = rate_limits.get('five_hour') or rate_limits.get('fiveHour') or {}
seven = rate_limits.get('seven_day') or rate_limits.get('sevenDay') or {}

if five or seven:
    five_pct = five.get('used_percentage')
    seven_pct = seven.get('used_percentage')
else:
    # Try OAuth fetch — real-time
    usage = fetch_oauth_usage(claude_dir)
    if usage:
        five = usage.get('five_hour') or {}
        seven = usage.get('seven_day') or {}
        five_pct = five.get('utilization')
        seven_pct = seven.get('utilization')
    else:
        # Last resort: cache quota
        quota = cache.get('quota') or {}
        five = quota.get('fiveHour') or {}
        seven = quota.get('sevenDay') or {}
        five_pct = five.get('utilization')
        seven_pct = seven.get('utilization')

five_pct = pct_to_int(five_pct)
seven_pct = pct_to_int(seven_pct)
five_reset = reset_str(five.get('resets_at'))
seven_reset = reset_str(seven.get('resets_at'))

# --- Render ---
ctx_label = f'CONTEXT({model})' if model else 'CONTEXT'
fixed_labels = ['Tokens session', 'Tokens Week']
label_width = max(len(ctx_label), max(len(l) for l in fixed_labels))

lines = []
if show_context:
    bar = make_bar(ctx_pct, bar_width)
    if model:
        padding = ' ' * (label_width - len(ctx_label))
        prefix = f'{GRAY}CONTEXT({RESET}{RED}{model}{RESET}{GRAY}){padding}{RESET}'
    else:
        prefix = f'{GRAY}{ctx_label.ljust(label_width)}{RESET}'
    lines.append(f'{prefix} {color_for_pct(ctx_pct)}{bar}{RESET} {ctx_pct:3d}% {GRAY}{fmt(ctx_total)}/{fmt(ctx_win)}{RESET} {GRAY}[sess:{fmt(sess_out)}]{RESET}')

if show_session and five_pct >= 0:
    bar = make_bar(five_pct, bar_width)
    line = f'{GRAY}{"Tokens session".ljust(label_width)}{RESET} {color_for_pct(five_pct)}{bar}{RESET} {five_pct:3d}%'
    if five_reset:
        line += f' {GRAY}↻ {five_reset}{RESET}'
    lines.append(line)

if show_week and seven_pct >= 0:
    bar = make_bar(seven_pct, bar_width)
    line = f'{GRAY}{"Tokens Week".ljust(label_width)}{RESET} {color_for_pct(seven_pct)}{bar}{RESET} {seven_pct:3d}%'
    if seven_reset:
        line += f' {GRAY}↻ {seven_reset}{RESET}'
    lines.append(line)

print('\n'.join(lines), end='')
PYEOF
