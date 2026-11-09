# claude-custom-shell

A Claude Code status line:

```
Opus 5.5 high | ████▎⡪⡪⡪⡪⡪ 42% ⧗ 12 min | 34%↑ 4d2h | Documents/project | 🌿 main | 📁 scratch
```

| Segment | What it shows |
|---|---|
| **Model** | Who's answering right now, plus the effort level. |
| **Context window** | Solid bar on a dark diagonal-hatched track, 1/8-cell precision. Green under 50%, yellow under 80%, then red. When it fills up, Claude starts losing details. |
| **Prompt cache countdown** | Minutes until the prompt cache expires; after that the next message costs many times more. Blank when little is at stake (under 20k tokens to re-cache). |
| **Plan usage** | The window closest to its limit. `↑` means usage is running ahead of the clock. |
| **Limit reset** | When that plan limit starts over, in days and hours (`4d2h`, `18h`, `<1h`). |
| **Project** | The project folder (last two path parts). |
| **Git worktree** | 🌿 + the worktree or branch name when inside git. Hidden otherwise. |
| **Scratchpad** | Claude's working files. Shown only when not empty. |

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
- `STATUSLINE_LINKS=1` makes project and scratchpad clickable (OSC 8 links). Off by default
  because VS Code draws a dashed underline under links.
- `CACHE_STAKE_TOKENS` (default 20000) sets the cache-countdown threshold.
- The scratch folder uses the Nerd Font folder glyph (tan) so it always shows in color;
  needs a Nerd Font in the terminal. `STATUSLINE_ICONS=emoji` uses 📁 instead; `=nerd` also swaps 🌿 for the Nerd Font leaf.
