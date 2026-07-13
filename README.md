# DEPRECATED

Please use this repo: [https://github.com/LipiTechnology/clade-code-statusbar](https://github.com/LipiTechnology/clade-code-statusbar)

# Claude Status Bar

A three-line status bar for Claude Code:

1. 5-hour rate-limit bar + reset time · weekly rate-limit bar + reset time · model + context-usage bar
2. account/org · `user:project` · git branch · clean/dirty dot
3. effort / thinking / output style

## Install as a plugin (recommended)

```
/plugin marketplace add TheBikramLama/claude-status-bar
/plugin install claude-status-bar@claude-status-bar
```

Restart Claude Code. A `SessionStart` hook copies the script into the plugin's
data dir and adds a `statusLine` entry to your `settings.json` — **only if you
don't already have one**, so a custom status line is never overwritten. Restart
once more and the bar appears.

To remove: `/plugin uninstall claude-status-bar@claude-status-bar`, then delete
the `statusLine` key from `~/.claude/settings.json`.

## Install manually (no plugin)

```
./install.sh     # copies to ~/.claude and wires settings.json
./uninstall.sh   # reverses it
```

## Requirements

`git` for the branch/dot line; `jq` **or** `python3` for parsing. All are
optional — missing tools degrade to placeholders, never an error.
