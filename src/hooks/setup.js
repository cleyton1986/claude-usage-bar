#!/usr/bin/env node
'use strict';

// SessionStart hook — wires claude-usage-bar into the user's statusLine.
//
// Behavior:
//   - Detects stale state from a previous install (broken statusLine path
//     pointing to a deleted plugin cache directory) and self-heals
//   - Backs up the current settings.json once, on first install
//   - Saves the existing statusLine command so the wrapper can call it
//   - Idempotent: re-running with the same plugin version is a no-op

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

function commandTargetExists(cmd) {
  // Extract the path between quotes after "bash"
  // bash "<path>"  or  bash <path>
  if (typeof cmd !== 'string') return false;
  const quoted = cmd.match(/bash\s+"([^"]+)"/);
  const unquoted = cmd.match(/bash\s+(\S+)/);
  const target = (quoted || unquoted || [])[1];
  if (!target) return true;  // unknown shape — don't claim it's missing
  try { fs.accessSync(target, fs.constants.R_OK); return true; }
  catch { return false; }
}

function main() {
  const settings = readSettings();
  const current = settings.statusLine;
  const currentCmd = current && current.type === 'command' ? current.command : null;

  // Already pointing to OUR current wrapper — nothing to do
  if (currentCmd === `bash "${wrapperScript}"`) {
    process.exit(0);
  }

  // Detect stale state: settings points to a previous version of our wrapper
  // whose cache directory was removed. Treat it as "no previous statusLine"
  // rather than saving the broken path.
  const isStaleOurWrapper = isOurWrapper(currentCmd) && !commandTargetExists(currentCmd);

  // One-shot backup (only the first time we ever modify settings)
  if (fs.existsSync(settingsPath) && !fs.existsSync(backupPath)) {
    try { fs.copyFileSync(settingsPath, backupPath); } catch {}
  }

  // Save previous statusLine command (unless it's ours, broken or current)
  if (currentCmd && !isOurWrapper(currentCmd) && !isStaleOurWrapper) {
    try { fs.writeFileSync(prevCmdFile, currentCmd, { mode: 0o600 }); } catch {}
  } else if (!fs.existsSync(prevCmdFile)) {
    try { fs.writeFileSync(prevCmdFile, '', { mode: 0o600 }); } catch {}
  }
  // else: keep the existing prev-cmd file (carries the user's original command
  // across plugin version bumps)

  settings.statusLine = {
    type: 'command',
    command: `bash "${wrapperScript}"`,
  };

  try { writeSettings(settings); }
  catch (err) {
    process.stderr.write(`[claude-usage-bar] failed to update settings.json: ${err.message}\n`);
  }

  process.exit(0);
}

main();
