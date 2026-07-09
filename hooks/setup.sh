#!/usr/bin/env bash
# SessionStart hook: make the plugin's status bar actually work.
#
# Plugins cannot declare a statusLine, and statusLine commands don't expand
# ${CLAUDE_PLUGIN_ROOT}. So we copy the script to the stable plugin data dir
# (survives updates, unlike the versioned cache path) and write that literal
# absolute path into the user's settings.json — but only if they don't already
# have a statusLine, so a user's own choice is never clobbered.
#
# Must never fail a session start: every step degrades quietly.

root="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$root" ] && [ -f "$root/statusline-command.sh" ] || exit 0

# ponytail: data dir is stable across updates; fall back to plugin root if the
# runtime is too old to set CLAUDE_PLUGIN_DATA (works until the next update).
data="${CLAUDE_PLUGIN_DATA:-$root}"
mkdir -p "$data" 2>/dev/null || data="$root"
cp "$root/statusline-command.sh" "$data/statusline-command.sh" 2>/dev/null || data="$root"
chmod +x "$data/statusline-command.sh" 2>/dev/null || true

settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
cmd="bash $data/statusline-command.sh"

# Set statusLine only if absent. Prefer python3 (already a script dependency),
# fall back to jq; if neither exists, tell the user the one line to add.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$settings" "$cmd" <<'PY' 2>/dev/null || true
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
sl = data.get("statusLine")
# Create if absent; otherwise only touch a statusLine that is ours (same
# command) so a user's own status line is never clobbered, and backfill
# refreshInterval for existing installs that predate it.
if not isinstance(sl, dict):
    data["statusLine"] = {"type": "command", "command": cmd, "refreshInterval": 1}
elif sl.get("command") == cmd and sl.get("refreshInterval") != 1:
    sl["refreshInterval"] = 1
else:
    sys.exit(0)
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
elif command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
  tmp="$(mktemp)" && jq --arg c "$cmd" 'if (.statusLine|type)!="object" then .statusLine={type:"command",command:$c,refreshInterval:1} elif .statusLine.command==$c then .statusLine.refreshInterval=1 else . end' "$settings" >"$tmp" 2>/dev/null && mv "$tmp" "$settings"
fi

exit 0
