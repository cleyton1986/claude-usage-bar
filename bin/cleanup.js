#!/usr/bin/env node
'use strict';

// Standalone cleanup script for claude-usage-bar.
//
// Removes everything the plugin writes outside its install directory:
//   - statusLine entry in ~/.claude/settings.json (only if it points to us)
//   - ~/.claude/.usage-bar-cache.json
//   - ~/.claude/.usage-bar-prev-statusline
//   - ~/.claude/settings.json.usage-bar.bak (after restoring it on demand)
//
// Usage:
//   node bin/cleanup.js              # remove plugin state, restore previous statusLine if known
//   node bin/cleanup.js --keep-bak   # leave the .usage-bar.bak backup file in place

const fs = require('fs');
const path = require('path');
const os = require('os');

const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const settingsPath = path.join(claudeDir, 'settings.json');
const backupPath = path.join(claudeDir, 'settings.json.usage-bar.bak');
const cacheFile = path.join(claudeDir, '.usage-bar-cache.json');
const prevCmdFile = path.join(claudeDir, '.usage-bar-prev-statusline');

const keepBak = process.argv.includes('--keep-bak');

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { return null; }
}

function writeSettings(s) {
  fs.writeFileSync(settingsPath, JSON.stringify(s, null, 2) + '\n', { mode: 0o600 });
}

function safeUnlink(file) {
  try { fs.unlinkSync(file); return true; }
  catch { return false; }
}

const actions = [];

// 1. Fix statusLine in settings.json
const settings = readJson(settingsPath) || {};
const current = settings.statusLine;
const currentCmd = current && current.type === 'command' ? current.command : null;
const looksLikeOurs = typeof currentCmd === 'string'
  && currentCmd.includes('claude-usage-bar')
  && currentCmd.includes('wrapper.sh');

if (looksLikeOurs) {
  // Restore previous statusLine command if we saved one
  let restored = false;
  if (fs.existsSync(prevCmdFile)) {
    const prev = fs.readFileSync(prevCmdFile, 'utf8').trim();
    if (prev) {
      settings.statusLine = { type: 'command', command: prev };
      actions.push(`Restored previous statusLine: ${prev}`);
      restored = true;
    }
  }
  if (!restored) {
    delete settings.statusLine;
    actions.push('Removed statusLine (no previous command saved)');
  }
  try { writeSettings(settings); }
  catch (err) {
    actions.push(`! failed to write settings.json: ${err.message}`);
  }
} else if (currentCmd) {
  actions.push('Left statusLine untouched (not ours)');
}

// 2. Remove plugin state files
if (safeUnlink(cacheFile))    actions.push(`Removed ${cacheFile}`);
if (safeUnlink(prevCmdFile))  actions.push(`Removed ${prevCmdFile}`);
if (!keepBak && safeUnlink(backupPath)) actions.push(`Removed ${backupPath}`);

if (actions.length === 0) {
  console.log('claude-usage-bar: nothing to clean up.');
} else {
  console.log('claude-usage-bar cleanup:');
  for (const a of actions) console.log(`  - ${a}`);
}

console.log('\nNext step: run `/plugin uninstall claude-usage-bar@claude-usage-bar` to remove the plugin itself.');
