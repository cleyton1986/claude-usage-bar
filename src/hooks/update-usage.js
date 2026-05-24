#!/usr/bin/env node
'use strict';

// UserPromptSubmit hook — keeps ~/.claude/.usage-bar-cache.json fresh.
//
// Two data sources:
//   1. Local JSONL transcript — session output tokens + context fallback
//   2. Anthropic OAuth usage endpoint (optional) — used when the user is
//      signed in with claude.ai Pro/Max and the statusLine's stdin doesn't
//      carry rate_limits (e.g. when ANTHROPIC_BASE_URL points at a proxy
//      that strips the rate-limit headers).
//
// The status line itself prefers Claude Code's own stdin JSON; this cache
// is a fallback for fields that may be absent there.

const fs = require('fs');
const path = require('path');
const os = require('os');
const https = require('https');

const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const cacheFile = path.join(claudeDir, '.usage-bar-cache.json');
const credentialsFile = path.join(claudeDir, '.credentials.json');

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

function readJson(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { return fallback; }
}

function getOAuthToken() {
  const creds = readJson(credentialsFile);
  if (!creds || !creds.claudeAiOauth) return null;
  const oauth = creds.claudeAiOauth;
  if (!oauth.accessToken) return null;
  if (oauth.expiresAt && Date.now() > oauth.expiresAt) return null;
  return { token: oauth.accessToken };
}

function fetchAnthropicUsage(token, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const req = https.request({
      method: 'GET',
      host: 'api.anthropic.com',
      path: '/api/oauth/usage',
      headers: {
        'Authorization': `Bearer ${token}`,
        'anthropic-beta': 'oauth-2025-04-20',
        'User-Agent': 'claude-usage-bar/1.0 (https://github.com/cleyton1986/claude-usage-bar)',
        'Accept': 'application/json',
      },
      timeout: timeoutMs,
    }, (res) => {
      let body = '';
      res.on('data', chunk => { body += chunk; });
      res.on('end', () => {
        if (res.statusCode !== 200) return resolve(null);
        try { resolve(JSON.parse(body)); }
        catch { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.end();
  });
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

  // Local: context + session tokens from JSONL
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

  // Optional: fetch quota from Anthropic OAuth endpoint as a fallback when
  // statusLine stdin doesn't carry rate_limits (e.g. when using a proxy).
  let quota = null;
  const oauth = getOAuthToken();
  if (oauth) {
    const usage = await fetchAnthropicUsage(oauth.token);
    if (usage) {
      quota = {
        fiveHour:  usage.five_hour  || null,
        sevenDay:  usage.seven_day  || null,
      };
    }
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
    quota,
  };

  try { fs.writeFileSync(cacheFile, JSON.stringify(cache)); } catch {}
  process.exit(0);
}

main().catch(() => process.exit(0));
