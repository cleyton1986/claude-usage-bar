#!/usr/bin/env node
'use strict';

// SessionStart hook — wires claude-usage-bar into the user's statusLine,
// combining with any existing statusLine script (wrapper mode).
//
// Behavior:
//   - First run: detects current statusLine, saves it, installs wrapper
//   - Subsequent runs: idempotent, does nothing if already wired
//   - Safe: never overwrites unrelated settings, makes one-shot .bak backup
//
// Files written:
//   ~/.claude/settings.json                        (statusLine field only)
//   ~/.claude/.usage-bar-prev-statusline           (previous statusLine cmd)
//   ~/.claude/settings.json.usage-bar.bak          (one-shot backup, first install)

const fs = require('fs');
const path = require('path');
const os = require('os');

const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const settingsPath = path.join(claudeDir, 'settings.json');
const backupPath = path.join(claudeDir, 'settings.json.usage-bar.bak');
const prevCmdFile = path.join(claudeDir, '.usage-bar-prev-statusline');

const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT || path.resolve(__dirname, '..', '..');
const wrapperScript = path.join(pluginRoot, 'src', 'wrapper.sh');

function readSettings() {
  try { return JSON.parse(fs.readFileSync(settingsPath, 'utf8')); }
  catch { return {}; }
}

function writeSettings(s) {
  fs.writeFileSync(settingsPath, JSON.stringify(s, null, 2) + '\n', { mode: 0o600 });
}

function isOurWrapper(cmd) {
  return typeof cmd === 'string'
    && cmd.includes('claude-usage-bar')
    && cmd.includes('wrapper.sh');
}

function main() {
  const settings = readSettings();
  const current = settings.statusLine;
  const currentCmd = current && current.type === 'command' ? current.command : null;

  // Already wired — nothing to do
  if (isOurWrapper(currentCmd)) {
    process.exit(0);
  }

  // One-shot backup before first modification
  if (fs.existsSync(settingsPath) && !fs.existsSync(backupPath)) {
    try { fs.copyFileSync(settingsPath, backupPath); } catch {}
  }

  // Save previous statusLine command so wrapper.sh can call it
  if (currentCmd && !isOurWrapper(currentCmd)) {
    try { fs.writeFileSync(prevCmdFile, currentCmd, { mode: 0o600 }); } catch {}
  } else {
    try { fs.writeFileSync(prevCmdFile, '', { mode: 0o600 }); } catch {}
  }

  settings.statusLine = {
    type: 'command',
    command: `bash "${wrapperScript}"`,
  };

  try {
    writeSettings(settings);
  } catch (err) {
    process.stderr.write(`[claude-usage-bar] failed to update settings.json: ${err.message}\n`);
    process.exit(0);
  }

  process.exit(0);
}

main();
