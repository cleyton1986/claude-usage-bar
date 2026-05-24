# claude-usage-bar

Live progress bars in the Claude Code status line, showing **context window usage**, **5-hour session quota** and **7-day weekly quota** — the same numbers that appear on the [claude.ai](https://claude.ai) dashboard.

```
[CAVEMAN]  CTX ███░░░░░░░ 30% 306k/1.0M [sess:166k]  5H ██░░░░░░ 33% ↻48m  7D █░░░░░░░ 17% ↻2d
```

- **CTX** — current model context window usage (input + cache tokens of the latest assistant response), with output tokens accumulated in the current session
- **5H** — five-hour quota utilisation, with time until reset (Claude Pro/Max only)
- **7D** — seven-day quota utilisation, with time until reset (Claude Pro/Max only)
- **Color-coded** — green ≤70%, yellow 70–90%, red >90%
- **Combines with existing status lines** — wraps any prior `statusLine` command (e.g. `caveman`) instead of replacing it
- **Quota bars** appear only when you are signed in with a Pro or Max plan; on free / API-only setups, only **CTX** is shown

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

No configuration required. The plugin auto-detects:
- Your model and its context window (200k for Claude 3.x/4.x, 1M for `[1m]` variants)
- Whether you're signed in with a Pro/Max plan (OAuth credentials in `~/.claude/.credentials.json`)

---

## How it works

| File | Purpose |
|---|---|
| `src/hooks/setup.js` | `SessionStart` hook — installs the wrapper into `settings.json` (idempotent) |
| `src/hooks/update-usage.js` | `UserPromptSubmit` hook — fetches quota from Anthropic, reads session JSONL, writes cache |
| `src/statusline.sh` | Reads cache, renders ANSI progress bars |
| `src/wrapper.sh` | Statusline glue — runs previous statusLine command + appends usage bars |

The hook fires after each prompt submission. It writes `~/.claude/.usage-bar-cache.json`; the status line script only reads that cache (< 1ms) on every render — no expensive work in the render path.

### Data sources

**Context bar (CTX)** — computed locally:
- Reads the latest assistant message in the current session's JSONL transcript
- Sums `input_tokens` + `cache_read_input_tokens` + `cache_creation_input_tokens` = real tokens sent to the model
- Detects 1M-context tier automatically when observed tokens exceed the default window

**5-hour and 7-day quota bars (5H, 7D)** — fetched from Anthropic:
- `GET https://api.anthropic.com/api/oauth/usage`
- Authenticated with the OAuth `accessToken` from `~/.claude/.credentials.json` (the same token Claude Code uses to talk to Anthropic on Pro/Max plans)
- Returns the exact same `five_hour.utilization` / `seven_day.utilization` percentages shown on the claude.ai dashboard
- Times out after 5 s; on failure the bars simply do not render

If you use Claude Code with an API key (`ANTHROPIC_AUTH_TOKEN`) instead of a Pro/Max OAuth login, the OAuth-based quota bars are skipped — only the CTX bar shows. The 5h/7d limits do not apply to API-billed accounts.

---

## Uninstall

In Claude Code:

```text
/plugin uninstall claude-usage-bar@claude-usage-bar
```

To restore the original status line:

```bash
cp ~/.claude/settings.json.usage-bar.bak ~/.claude/settings.json
```

To remove leftover files:

```bash
rm -f ~/.claude/.usage-bar-cache.json \
      ~/.claude/.usage-bar-prev-statusline
```

---

## Troubleshooting

**Bars not showing after install**
- Restart Claude Code — the `SessionStart` hook only fires on a new session
- Check `~/.claude/settings.json` — the `statusLine.command` should point to `.../claude-usage-bar/.../src/wrapper.sh`

**Only CTX bar shows, no 5H / 7D**
- Expected if you're on an API-key setup (no Pro/Max plan)
- Or your OAuth token expired — run `claude` and log in again
- Or you're behind a network proxy that blocks `api.anthropic.com`

**Bars stuck at the same numbers**
- The cache is updated by the `UserPromptSubmit` hook — after you send a message, not on every keystroke
- Check `~/.claude/.usage-bar-cache.json` — `updatedAt` should be a recent timestamp

**`settings.json` keeps getting reset**
- Some launchers (e.g. provider-switcher scripts) overwrite `~/.claude/settings.json` on each start. Check `~/.zshrc` / `~/.bashrc` for `alias claude=` lines pointing to a switcher script.

---

## Privacy & security

- The plugin reads `~/.claude/.credentials.json` only to obtain the OAuth access token used by Claude Code itself
- The token is sent **only** to `api.anthropic.com/api/oauth/usage`, the official Anthropic endpoint already used by the Claude Code client
- No data is sent to any third party
- Writes are restricted to `~/.claude/.usage-bar-*` files and the `statusLine` field of `~/.claude/settings.json`
- The wrapper strips control characters from the previous-statusLine command before executing it (prevents ANSI-escape injection)

---

## License

MIT — see [LICENSE](LICENSE).
