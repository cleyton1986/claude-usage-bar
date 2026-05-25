# claude-usage-bar

Live progress bars in the Claude Code status line, showing **context window usage**, **5-hour session quota** and **7-day weekly quota** — the same numbers that appear on the [claude.ai](https://claude.ai) dashboard.

```
CONTEXT(Sonnet-4-6) ███░░░░░░░  30% 306k/1.0M [sess:166k]
Tokens session      ███░░░░░░░  33% ↻ 47m
Tokens Week         █░░░░░░░░░  17% ↻ 2d
```

- **CONTEXT(Model)** — current model context window usage (input + cache tokens of the latest assistant response), with output tokens accumulated in the current session. The active model name is read dynamically from the current Claude Code transcript and highlighted in red.
- **Tokens session** — five-hour quota utilisation, with time until reset (Claude Pro/Max only)
- **Tokens Week** — seven-day quota utilisation, with time until reset (Claude Pro/Max only)
- **Color-coded** — green ≤70%, yellow 70–90%, red >90%
- **Combines with existing status lines** — wraps any prior `statusLine` command instead of replacing it
- **Quota bars** appear only when you are signed in with a Pro or Max plan; on free / API-only setups, only **CONTEXT(Model)** is shown

---

## Requirements

- Claude Code `>=` 2.0 (plugin system)
- Node.js `>=` 18
- bash `>=` 4
- python3

Tested on Linux and native Windows with Cygwin bash. Should work on macOS and WSL.

---

## Installation

### Option A — Terminal (works on macOS, Linux, Windows with Cygwin bash, WSL)

Run these three commands in your terminal:

```bash
claude plugins marketplace add cleyton1986/claude-usage-bar
claude plugins install claude-usage-bar@claude-usage-bar
claude plugins list
```

The last command should show `claude-usage-bar@claude-usage-bar` with status **enabled**.

**Then fully quit and reopen Claude Code** (not just a new conversation — the app itself must restart). On the next session start the `SessionStart` hook runs automatically and wires the bars into your status line.

> **macOS note**: if Claude Code is open in the Dock, right-click → Quit before reopening. A new conversation window is not enough.

### Option B — Inside Claude Code (slash commands)

```text
/plugin marketplace add cleyton1986/claude-usage-bar
/plugin install claude-usage-bar@claude-usage-bar
```

Then **fully quit and reopen Claude Code**.

### Verify it worked

After restarting, send any message. The status line should show three rows:

```
CONTEXT(Sonnet-4-6) ███░░░░░░░  30% 306k/1.0M [sess:166k]
Tokens session      ███░░░░░░░  33% ↻ 47m
Tokens Week         █░░░░░░░░░  17% ↻ 2d
```

If bars don't appear, see [Troubleshooting](#troubleshooting).

### From source (for development)

```bash
git clone https://github.com/cleyton1986/claude-usage-bar.git
claude plugins marketplace add /absolute/path/to/claude-usage-bar
claude plugins install claude-usage-bar@claude-usage-bar
```

---

## Configuration

No configuration required. The plugin auto-detects the current model, its context window (200k or 1M) and your plan tier. The `[1m]` and `-1m` model suffixes are used internally for context window detection but stripped from the display name to avoid ANSI escape collisions.

---

## How it works

| File | Purpose |
|---|---|
| `src/hooks/setup.js` | `SessionStart` hook — installs the wrapper into `settings.json` (idempotent) |
| `src/hooks/update-usage.js` | `UserPromptSubmit` hook — caches session output tokens and quota as fallback |
| `src/statusline.sh` | Reads Claude Code's stdin JSON in real-time, renders the progress bars |
| `src/wrapper.sh` | Statusline glue — pipes stdin to your previous statusLine command and to the renderer, then concatenates outputs |

### Data sources (real-time, no stale cache)

All values are read fresh on every render — there is no caching of live data.

**Context bar (CONTEXT(Model))**
- **Model name**: read directly from the latest JSONL transcript (`~/.claude/projects/**/*.jsonl`) — reflects the actual model in use, including any proxy-routed model.
- **Context %**: from `context_window.used_percentage` on stdin (written by Claude Code after each API response), falling back to summing `input_tokens + cache_read + cache_creation` from the current JSONL when stdin lacks it.

**Tokens session and Tokens Week quota bars** — three-tier, all real-time:

1. **stdin** — `rate_limits.five_hour` / `rate_limits.seven_day` on the statusLine stdin JSON. Present for Claude.ai Pro/Max when the API response carries `anthropic-ratelimit-*` headers. Not present when a proxy strips those headers.
2. **OAuth endpoint** (live HTTP) — when stdin lacks `rate_limits`, the renderer calls `https://api.anthropic.com/api/oauth/usage` using the OAuth token in `~/.claude/.credentials.json`. This ensures quota is always current even through proxies.
3. **Cache** — written by the `UserPromptSubmit` hook as a last-resort fallback only. Stale if the OAuth call fails.

If neither source is available (e.g. API-key-only setup), the Tokens session/Tokens Week bars are simply skipped — the limits don't apply to API-billed accounts.

The percentages match the ones shown on the [claude.ai](https://claude.ai) dashboard — same source, same numbers.

---

## Uninstall

Run the cleanup command first, then uninstall the plugin itself:

```text
/usage-bar:uninstall
/plugin uninstall claude-usage-bar@claude-usage-bar
```

`/usage-bar:uninstall` restores your previous `statusLine` command (if any), removes the cache file, the saved previous-statusLine file, and the one-shot backup. If you skip it and run only `/plugin uninstall`, the next session will detect the stale `statusLine` entry pointing to the removed plugin cache and the bar simply won't render — your shell isn't affected, but you'll want to clear the dead entry manually:

```bash
node -e "const fs=require('fs'),p=require('os').homedir()+'/.claude/settings.json';const s=JSON.parse(fs.readFileSync(p,'utf8'));delete s.statusLine;fs.writeFileSync(p,JSON.stringify(s,null,2)+'\n')"
```

---

## Troubleshooting

**Bars not showing after install**
- Fully quit and reopen Claude Code — the `SessionStart` hook only fires when the app starts a new session
- Run `claude plugins list` and verify `claude-usage-bar@claude-usage-bar` is **enabled**
- Check `~/.claude/settings.json` — the `statusLine.command` should point to `.../claude-usage-bar/.../src/wrapper.sh`
- Send one message after restart so Claude Code writes fresh stdin/transcript data

**Only CONTEXT(Model) bar shows, no Tokens session / Tokens Week**
- Expected if you're on an API-key setup (no Pro/Max plan) — these limits don't exist for API-billed accounts
- Or Claude.ai OAuth credentials are missing/expired in `~/.claude/.credentials.json`
- Or the session hasn't made its first API call yet (rate-limit fields appear only after the first response)

**Bars stuck at the same numbers**
- The renderer reads live stdin/transcript/OAuth first; cache is only a fallback
- Send one message to force Claude Code to write new statusLine stdin/transcript data
- If quota stays stale, check whether Claude Code is still signed in to Claude.ai Pro/Max

**`settings.json` keeps getting reset**
- Some launchers (e.g. provider-switcher scripts) overwrite `~/.claude/settings.json` on each start. Check `~/.zshrc` / `~/.bashrc` for `alias claude=` lines pointing to a switcher script.

**Windows-specific: bars not showing or garbled output**
- Ensure **Cygwin bash** is installed and `bash` is on your PATH — the plugin shell scripts require it
- Ensure **Python 3** is installed — the renderer is an inline Python script inside `statusline.sh`
- If you see a `UnicodeEncodeError` in the logs, your Python is using the wrong encoding — the v1.2.0+ fix adds `PYTHONIOENCODING=utf-8` automatically
- If transcript/model data is missing, verify `cygpath` is available (it ships with Cygwin) — it converts Cygwin paths to Windows paths for Python

---

## Privacy & security

- **Quota fallback**: when Claude Code's stdin lacks `rate_limits` (e.g. through a proxy), the renderer calls `https://api.anthropic.com/api/oauth/usage` using the OAuth token already stored by Claude Code in `~/.claude/.credentials.json`. No token is sent elsewhere.
- All other data comes from Claude Code's own session JSON on stdin and from local JSONL transcripts — no third-party services.
- Writes are restricted to `~/.claude/.usage-bar-*` files and the `statusLine` field of `~/.claude/settings.json`
- The wrapper strips control characters from the previous-statusLine command before executing it (prevents ANSI-escape injection)

---

## License

MIT — see [LICENSE](LICENSE).
