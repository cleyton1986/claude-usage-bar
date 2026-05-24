#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const assert = require('assert');
const { execFileSync } = require('child_process');

const PLUGIN_ROOT = path.resolve(__dirname, '..');
const CLEANUP = path.join(PLUGIN_ROOT, 'bin', 'cleanup.js');
const SETUP   = path.join(PLUGIN_ROOT, 'src', 'hooks', 'setup.js');

function runCleanup(claudeDir, args = []) {
  return execFileSync(process.execPath, [CLEANUP, ...args], {
    env: { ...process.env, CLAUDE_CONFIG_DIR: claudeDir },
    encoding: 'utf8',
  });
}

function runSetup(claudeDir) {
  execFileSync(process.execPath, [SETUP], {
    env: { ...process.env, CLAUDE_CONFIG_DIR: claudeDir, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
  });
}

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'usage-bar-cleanup-test-'));
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

console.log('cleanup.js tests');

test('restores previous statusLine after cleanup', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({
    statusLine: { type: 'command', command: 'echo prev' },
  }));
  runSetup(dir);
  runCleanup(dir);
  const s = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
  assert.strictEqual(s.statusLine.command, 'echo prev');
  fs.rmSync(dir, { recursive: true });
});

test('removes statusLine when no previous command saved', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({}));
  runSetup(dir);
  runCleanup(dir);
  const s = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
  assert.ok(!s.statusLine, 'statusLine should be removed');
  fs.rmSync(dir, { recursive: true });
});

test('removes cache and prev-statusline files', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({}));
  fs.writeFileSync(path.join(dir, '.usage-bar-cache.json'), '{}');
  runSetup(dir);
  runCleanup(dir, ['--keep-bak']);
  assert.ok(!fs.existsSync(path.join(dir, '.usage-bar-cache.json')));
  assert.ok(!fs.existsSync(path.join(dir, '.usage-bar-prev-statusline')));
  fs.rmSync(dir, { recursive: true });
});

test('leaves unrelated statusLine untouched', () => {
  const dir = tmpDir();
  const other = { type: 'command', command: 'echo other' };
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({ statusLine: other }));
  runCleanup(dir);
  const s = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
  assert.deepStrictEqual(s.statusLine, other);
  fs.rmSync(dir, { recursive: true });
});

test('--keep-bak preserves backup file', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({}));
  runSetup(dir);
  runCleanup(dir, ['--keep-bak']);
  assert.ok(fs.existsSync(path.join(dir, 'settings.json.usage-bar.bak')));
  fs.rmSync(dir, { recursive: true });
});

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
