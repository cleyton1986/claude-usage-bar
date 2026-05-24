#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const assert = require('assert');
const { execFileSync } = require('child_process');

const PLUGIN_ROOT = path.resolve(__dirname, '..');
const SETUP = path.join(PLUGIN_ROOT, 'src', 'hooks', 'setup.js');

function run(claudeDir) {
  return execFileSync(process.execPath, [SETUP], {
    env: { ...process.env, CLAUDE_CONFIG_DIR: claudeDir, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
    encoding: 'utf8',
  });
}

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'usage-bar-test-'));
}

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (err) {
    console.error(`  ✗ ${name}`);
    console.error(`    ${err.message}`);
    failed++;
  }
}

console.log('setup.js tests');

test('installs wrapper into empty settings.json', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({}));
  run(dir);
  const s = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
  assert.strictEqual(s.statusLine.type, 'command');
  assert.ok(s.statusLine.command.includes('wrapper.sh'));
  fs.rmSync(dir, { recursive: true });
});

test('saves previous statusLine to prev-statusline file', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({
    statusLine: { type: 'command', command: 'echo prev' },
  }));
  run(dir);
  const prev = fs.readFileSync(path.join(dir, '.usage-bar-prev-statusline'), 'utf8').trim();
  assert.strictEqual(prev, 'echo prev');
  fs.rmSync(dir, { recursive: true });
});

test('is idempotent — second run is a no-op', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({}));
  run(dir);
  const s1 = fs.readFileSync(path.join(dir, 'settings.json'), 'utf8');
  const mtime1 = fs.statSync(path.join(dir, 'settings.json')).mtimeMs;
  run(dir);
  const mtime2 = fs.statSync(path.join(dir, 'settings.json')).mtimeMs;
  assert.strictEqual(mtime1, mtime2, 'settings.json should not be rewritten on second run');
  fs.rmSync(dir, { recursive: true });
});

test('creates one-shot backup of settings.json', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({ theme: 'dark' }));
  run(dir);
  const bak = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json.usage-bar.bak'), 'utf8'));
  assert.strictEqual(bak.theme, 'dark');
  fs.rmSync(dir, { recursive: true });
});

test('detects stale wrapper and does not save it as prev-statusline', () => {
  const dir = tmpDir();
  const staleCmd = 'bash "/nonexistent/claude-usage-bar/old/src/wrapper.sh"';
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({
    statusLine: { type: 'command', command: staleCmd },
  }));
  run(dir);
  const prev = fs.existsSync(path.join(dir, '.usage-bar-prev-statusline'))
    ? fs.readFileSync(path.join(dir, '.usage-bar-prev-statusline'), 'utf8').trim()
    : '';
  assert.notStrictEqual(prev, staleCmd, 'stale wrapper must not be saved as prev');
  fs.rmSync(dir, { recursive: true });
});

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
