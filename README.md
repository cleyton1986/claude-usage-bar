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

Tested on Linux. Should work on macOS and WSL. Not tested on native Windows (PowerShell).

---

## Installation

### From the marketplace (recommended)

Inside Claude Code:

```text
/plugin marketplace add cleyton1986/claude-usage-bar
/plugin install claude-usage-bar@claude-usage-bar
```

Then **restart Claude Code**. On the next session start, the plugin will:

1. Back up your current `~/.claude/settings.json` to `~/.claude/settings.json.usage-bar.bak` (one-shot, only if no backup exists yet)
2. Save your existing `statusLine` command to `~/.claude/.usage-bar-prev-statusline`
3. Install its wrapper as the new `statusLine`

The wrapper runs your previous status line first and appends the usage bars after it — nothing is overwritten or lost.

### From source (for development)

```bash
git clone https://github.com/cleyton1986/claude-usage-bar.git
```

Then in Claude Code:

```text
/plugin marketplace add /absolute/path/to/claude-usage-bar
/plugin install claude-usage-bar@claude-usage-bar
```

---

## Configuration

No configuration required. The plugin auto-detects the current model, its context window (200k or 1M for `[1m]` variants) and your plan tier.

---

## How it works

| File | Purpose |
|---|---|
| `src/hooks/setup.js` | `SessionStart` hook — installs the wrapper into `settings.json` (idempotent) |
| `src/hooks/update-usage.js` | `UserPromptSubmit` hook — sums session output tokens from the JSONL transcript into a cache |
| `src/statusline.sh` | Reads Claude Code's stdin JSON (and the cache as fallback), renders the progress bars |
| `src/wrapper.sh` | Statusline glue — pipes stdin to your previous statusLine command and to the renderer, then concatenates outputs |

### Data sources

All values come straight from Claude Code itself — no network calls, no third-party endpoints.

**Context bar (CONTEXT(Model))** — from the `context_window` field on stdin:
- `context_window.used_percentage` (and `context_window_size`) — written by Claude Code after each API response
- Falls back to summing `input_tokens + cache_read + cache_creation` from the current JSONL transcript when stdin is unavailable

**Tokens session and Tokens Week quota bars** — two-tier source:

1. **Primary**: from `rate_limits.five_hour` / `rate_limits.seven_day` on stdin. Sent by Claude Code only for Claude.ai Pro/Max subscribers, and only when the API response carries the `anthropic-ratelimit-*` headers (some proxies strip them).
2. **Fallback**: when stdin lacks `rate_limits`, the `UserPromptSubmit` hook queries `https://api.anthropic.com/api/oauth/usage` using the OAuth token already stored in `~/.claude/.credentials.json`, and writes the values into `~/.claude/.usage-bar-cache.json`. The status line reads them from there.

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
- Restart Claude Code — the `SessionStart` hook only fires on a new session
- Check `~/.claude/settings.json` — the `statusLine.command` should point to `.../claude-usage-bar/.../src/wrapper.sh`

**Only CONTEXT(Model) bar shows, no Tokens session / Tokens Week**
- Expected if you're on an API-key setup (no Pro/Max plan) — these limits don't exist for API-billed accounts
- Or the session hasn't made its first API call yet (rate-limit fields appear only after the first response)

**Bars stuck at the same numbers**
- The cache is updated by the `UserPromptSubmit` hook — after you send a message, not on every keystroke
- Check `~/.claude/.usage-bar-cache.json` — `updatedAt` should be a recent timestamp

**`settings.json` keeps getting reset**
- Some launchers (e.g. provider-switcher scripts) overwrite `~/.claude/settings.json` on each start. Check `~/.zshrc` / `~/.bashrc` for `alias claude=` lines pointing to a switcher script.

---

## Privacy & security

- The plugin makes **zero** network calls — all data comes from Claude Code's own session JSON on stdin and from local JSONL transcripts
- It does not read `~/.claude/.credentials.json` or any secret material
- Writes are restricted to `~/.claude/.usage-bar-*` files and the `statusLine` field of `~/.claude/settings.json`
- The wrapper strips control characters from the previous-statusLine command before executing it (prevents ANSI-escape injection)

---

## License

MIT — see [LICENSE](LICENSE).
