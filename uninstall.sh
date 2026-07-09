#!/usr/bin/env bash
# Uninstall Claude Code status bar.
# Removes the installed script and clears statusLine from settings.json.
set -eu

dest_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
script="$dest_dir/statusline-command.sh"
settings="$dest_dir/settings.json"
cache="$dest_dir/statusline-cache.sh"

rm -f "$script" "$cache" && echo "Removed $script"

# Drop statusLine from settings.json, preserving everything else.
if [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq 'del(.statusLine)' "$settings" >"$tmp" && mv "$tmp" "$settings"
  echo "Cleared statusLine from $settings"
elif [ -f "$settings" ]; then
  echo "jq not found. Remove the \"statusLine\" key from $settings manually."
fi

echo "Done. Restart Claude Code to apply."
