# claude-custom-shell

A Claude Code status line:

```
Opus 5.5 high | ████░░░░░░ 42% ⧗ 12 min | 34%↑ 4d2h | Documents/project | 🌿 rule-fixes | 📁 scratch
```

| Segment | What it shows |
|---|---|
| **Model** | Who's answering right now, plus the effort level. |
| **Context window** | Green under 50%, yellow under 80%, then red. When it fills up, Claude starts losing details. |
| **Prompt cache countdown** | Minutes until the prompt cache expires; after that the next message costs many times more. Blank when little is at stake (under 20k tokens to re-cache). |
| **Plan usage** | The window closest to its limit. `↑` means usage is running ahead of the clock. |
| **Limit reset** | When that plan limit starts over, in days and hours (`4d2h`, `18h`, `<1h`). |
| **Project** | Click to open its folder. |
| **Git worktree** | Shown only when working in a linked worktree. |
| **Scratchpad** | Claude's working files. Shown only when not empty; also clickable. |

## Install

Requires `bash`, `jq`, `curl`, `git`.

```sh
cp statusline.sh ~/.claude/statusline-command.sh
```

In `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/statusline-command.sh",
  "refreshInterval": 30
}
```

`refreshInterval` keeps the cache countdown ticking between messages.

## Notes

- Plan usage comes from stdin's `rate_limits` when Claude Code supplies it, merged with
  `/api/oauth/usage` (the endpoint `/usage` reads), cached for 5 minutes in
  `~/.cache/claude-statusline/` and refreshed in the background.
- Clickable segments use OSC 8 hyperlinks; your terminal needs to support them.
- `CACHE_STAKE_TOKENS` (default 20000) sets the cache-countdown threshold.
