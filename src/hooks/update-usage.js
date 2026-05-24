#!/usr/bin/env node
'use strict';

// UserPromptSubmit hook — keeps ~/.claude/.usage-bar-cache.json fresh.
//
// The status line itself reads Claude Code's official session JSON on stdin
// (context_window.*, rate_limits.*), so for live usage the cache is only a
// fallback. We still populate it after every prompt with:
//
//   - cumulative output tokens for the current session (sum from JSONL)
//   - last known context window + model (when stdin fields are absent)
//
// Errors are swallowed; this hook must never block Claude Code.

const fs = require('fs');
const path = require('path');
const os = require('os');

const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const cacheFile = path.join(claudeDir, '.usage-bar-cache.json');

// Context window per model family (tokens). More specific patterns first.
const CONTEXT_WINDOW = [
  [/\[1m\]$/,                          1000000],
  [/^claude-sonnet-4.*-1m/,            1000000],
  [/^claude-(opus|sonnet|haiku)-4/,    200000],
  [/^claude-3-5/,                      200000],
  [/^claude-3-7/,                      200000],
  [/^claude-3-(opus|sonnet|haiku)/,    200000],
];

function contextWindowForModel(model) {
  if (!model) return 200000;
  for (const [pattern, size] of CONTEXT_WINDOW) {
    if (pattern.test(model)) return size;
  }
  return 200000;
}

function readSessionData(sessionFile) {
  if (!sessionFile || !fs.existsSync(sessionFile)) return null;

  let last = null;
  let sessionOutputTokens = 0;
  const raw = fs.readFileSync(sessionFile, 'utf8');
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    try {
      const d = JSON.parse(line);
      const msg = d.message;
      if (msg && msg.role === 'assistant' && msg.usage) {
        last = { usage: msg.usage, model: msg.model };
        sessionOutputTokens += (msg.usage.output_tokens || 0);
      }
    } catch {}
  }
  if (!last) return null;
  return { ...last, sessionOutputTokens };
}

async function main() {
  let input = '';
  for await (const chunk of process.stdin) input += chunk;

  let hookData = {};
  try { hookData = JSON.parse(input); } catch {}

  const transcriptPath = hookData.transcript_path || null;

  let ctxTokens = 0;
  let ctxWindow = 200000;
  let model = null;
  let sessionOutputTokens = 0;

  const sessionData = readSessionData(transcriptPath);
  if (sessionData) {
    const u = sessionData.usage;
    model = sessionData.model;
    ctxWindow = contextWindowForModel(model);
    ctxTokens = (u.input_tokens || 0)
      + (u.cache_read_input_tokens || 0)
      + (u.cache_creation_input_tokens || 0);
    sessionOutputTokens = sessionData.sessionOutputTokens;
    if (ctxTokens > ctxWindow && ctxWindow < 1000000) ctxWindow = 1000000;
  }

  const cache = {
    updatedAt: Date.now(),
    model,
    ctx: {
      tokens: ctxTokens,
      window: ctxWindow,
      pct: Math.min(100, (ctxTokens / ctxWindow) * 100),
    },
    session: { outputTokens: sessionOutputTokens },
  };

  try { fs.writeFileSync(cacheFile, JSON.stringify(cache)); } catch {}
  process.exit(0);
}

main().catch(() => process.exit(0));
