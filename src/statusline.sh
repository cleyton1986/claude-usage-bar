#!/usr/bin/env bash
# claude-usage-bar — statusline renderer.

set -u

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CACHE="$CLAUDE_DIR/.usage-bar-cache.json"
CONFIG="$CLAUDE_DIR/.usage-bar-config.json"
STDIN=$(cat 2>/dev/null || true)

STDIN="$STDIN" CACHE="$CACHE" CONFIG="$CONFIG" python3 <<'PYEOF'
import json
import os
import re
import datetime

RESET = '\033[0m'
GRAY = '\033[90m'
RED = '\033[31m'
GREEN = '\033[32m'
YELLOW = '\033[33m'


def load_json_file(path, fallback=None):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return fallback if fallback is not None else {}


def load_stdin():
    raw = os.environ.get('STDIN', '').strip()
    if not raw:
        return {}
    try:
        return json.loads(raw)
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


def short_model(model):
    if not model:
        return ''
    model = re.sub(r'-\d{8}$', '', str(model))
    parts = model.split('-')
    if len(parts) >= 4 and parts[0] == 'claude':
        return f'{parts[1].capitalize()}-{"-".join(parts[2:])}'
    return model


def latest_transcript_path():
    root = os.path.join(os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude'), 'projects')
    latest = ('', -1)
    for base, _, files in os.walk(root):
        for name in files:
            if not name.endswith('.jsonl'):
                continue
            path = os.path.join(base, name)
            try:
                mtime = os.path.getmtime(path)
            except Exception:
                continue
            if mtime > latest[1]:
                latest = (path, mtime)
    return latest[0]


def latest_model_from_transcript(path):
    if not path or not os.path.exists(path):
        path = latest_transcript_path()
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


def bool_cfg(config, key, default=True):
    value = config.get(key, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() not in ('0', 'false', 'no', 'off')
    return bool(value)


stdin = load_stdin()
cache = load_json_file(os.environ.get('CACHE', ''), {})
config = load_json_file(os.environ.get('CONFIG', ''), {})

try:
    bar_width = int(config.get('bar_width', 10) or 10)
except Exception:
    bar_width = 10
bar_width = max(4, min(40, bar_width))
show_context = bool_cfg(config, 'show_context', True)
show_session = bool_cfg(config, 'show_session', True)
show_week = bool_cfg(config, 'show_week', True)

model = latest_model_from_transcript(cache.get('transcriptPath') or '')
if not model:
    stdin_model = stdin.get('model')
    if isinstance(stdin_model, dict):
        model = stdin_model.get('id') or stdin_model.get('name') or ''
    elif stdin_model:
        model = str(stdin_model)
if not model:
    model = cache.get('model') or ''
model = short_model(model)

ctx = stdin.get('context_window') or {}
ctx_pct = ctx.get('used_percentage')
ctx_win = ctx.get('context_window_size')
ctx_in = ctx.get('total_input_tokens') or 0
ctx_out = ctx.get('total_output_tokens') or 0

if ctx_pct is None or ctx_win is None:
    cached_ctx = cache.get('ctx') or {}
    ctx_pct = cached_ctx.get('pct', 0)
    ctx_win = cached_ctx.get('window', 200000)
    ctx_in = cached_ctx.get('tokens', 0)
    ctx_out = 0

ctx_total = int(ctx_in or 0) + int(ctx_out or 0)
ctx_pct = pct_to_int(ctx_pct)
sess_out = (cache.get('session') or {}).get('outputTokens', 0)

rate_limits = stdin.get('rate_limits') or {}
five = rate_limits.get('five_hour') or {}
seven = rate_limits.get('seven_day') or {}

if not five and not seven:
    quota = cache.get('quota') or {}
    five = quota.get('fiveHour') or {}
    seven = quota.get('sevenDay') or {}
    five_pct = five.get('utilization')
    seven_pct = seven.get('utilization')
else:
    five_pct = five.get('used_percentage')
    seven_pct = seven.get('used_percentage')

five_pct = pct_to_int(five_pct)
seven_pct = pct_to_int(seven_pct)
five_reset = reset_str(five.get('resets_at'))
seven_reset = reset_str(seven.get('resets_at'))

ctx_label = f'CONTEXT({model})' if model else 'CONTEXT'
labels = [ctx_label, 'Tokens session', 'Tokens Week']
label_width = max(len(label) for label in labels)

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
