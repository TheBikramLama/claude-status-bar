#!/bin/bash
# Claude Code status line (three-line layout)
#
# Line 1: bar session-reset-time | 🗓️ bar weekly-reset-time | Model bar(used/context)
# Line 2: project branch dot (dot: green = clean, orange = dirty; git only)
# Line 3: effort / thinking / output style
#
# Colours are dimmed to suit Claude Code's status line rendering.
#
# Portable by design: no hardcoded absolute paths (the usage cache's location
# is derived from $HOME, falling back to this script's own directory, falling
# back to a temp dir), and every external dependency (jq, python3, git, a
# pre-existing cache file) is optional — missing tools/fields degrade to
# placeholders instead of making the script error out.

input=$(cat)

# ---- helpers ----------------------------------------------------------

# True if $1 looks like a plain (optionally decimal, optionally signed) number.
is_num() {
  case "$1" in
    '') return 1 ;;
    *[!0-9.+-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Turn an epoch timestamp into a local 12-hour clock time, e.g. "10:00pm"
fmt_time_of_day() {
  local epoch="$1" epoch_int
  is_num "$epoch" || { echo "--"; return; }
  epoch_int="${epoch%%.*}"
  { [ -z "$epoch_int" ] || [ "$epoch_int" -le 0 ] 2>/dev/null; } && { echo "--"; return; }
  date -d "@$epoch_int" +"%I:%M%p" 2>/dev/null || date -r "$epoch_int" +"%I:%M%p" 2>/dev/null || echo "--"
}

# Turn an epoch timestamp into a local weekday/date/time, e.g. "Tue 10 Jan 04:45am"
fmt_weekday_time() {
  local epoch="$1" epoch_int
  is_num "$epoch" || { echo "--"; return; }
  epoch_int="${epoch%%.*}"
  { [ -z "$epoch_int" ] || [ "$epoch_int" -le 0 ] 2>/dev/null; } && { echo "--"; return; }
  date -d "@$epoch_int" +"%a %d %b %I:%M%p" 2>/dev/null || date -r "$epoch_int" +"%a %d %b %I:%M%p" 2>/dev/null || echo "--"
}

# Turn a raw token count into a short label, e.g. 45231 -> 45k, 1200000 -> 1.2M
fmt_tokens() {
  local n="$1"
  is_num "$n" || { echo "--"; return; }
  n="${n%%.*}"
  [ -z "$n" ] && { echo "--"; return; }
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    printf '%sM' "$(( n / 1000000 ))"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    printf '%sk' "$(( n / 1000 ))"
  else
    printf '%s' "$n"
  fi
}

# Build a gradient progress bar of $2 cells wide, with $3 centred inside as a
# label. The fill colour reflects usage severity for THIS bar's own
# percentage: green (pct <= 50), yellow/amber (50 < pct < 85), red
# (pct >= 85) — each a tight, low-variance ramp (a few tones, each held for
# two cells) so the bar reads as one smooth fade instead of a rainbow, even
# at high usage. Unfilled cells use a lighter grey so empty bars stay
# visible. The label's text colour is chosen once per bar (from the active
# severity tier) so every character in it renders in the same colour, no
# matter which cell it lands on. Built cell-by-cell (never indexes the
# coloured string by length).
make_bar() {
  local pct="$1" width="$2" label="$3"
  local filled i idx bg fg cell lablen labstart labend ch out tier label_fg
  is_num "$pct" || pct=0
  pct="${pct%%.*}"
  [ -z "$pct" ] && pct=0
  filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0

  # Tight, low-variance ramps: a handful of tones (each held for two cells)
  # within a single hue family per severity, instead of a wide light->dark
  # sweep. This keeps high-usage bars looking like one smooth red fade
  # rather than a rainbow of unrelated shades.
  local green=(120 120 84 84 41 41 35 35 29 29 22 22)
  local yellow=(220 220 214 214 208 208 172 172 136 136 94 94)
  local red=(203 203 196 196 160 160 124 124 88 88 52 52)

  local grad
  if [ "$pct" -ge 85 ]; then
    grad=("${red[@]}")
    tier=red
  elif [ "$pct" -gt 50 ]; then
    grad=("${yellow[@]}")
    tier=yellow
  else
    grad=("${green[@]}")
    tier=green
  fi
  local gradlen=${#grad[@]}

  lablen=${#label}
  if [ "$lablen" -ge "$width" ]; then
    # No room for a label inside the bar; just show the label as plain text.
    printf '%s' "$label"
    return
  fi
  labstart=$(( (width - lablen) / 2 ))
  labend=$(( labstart + lablen - 1 ))

  # Decide the label's text colour ONCE per bar (based on the active
  # severity tier), not per character/cell — otherwise individual digits of
  # the same value can end up in different colours as the label crosses
  # cell boundaries with different backgrounds.
  case "$tier" in
    red) label_fg=15 ;;
    *) label_fg=232 ;;
  esac

  out=""
  for (( i=0; i<width; i++ )); do
    if [ "$i" -lt "$filled" ]; then
      idx=$(( i * gradlen / width ))
      bg="${grad[$idx]}"
    else
      # Unfilled cells: a lighter grey so empty bars stay visible instead
      # of disappearing into the terminal background.
      bg=240
    fi

    if [ "$i" -ge "$labstart" ] && [ "$i" -le "$labend" ]; then
      ch="${label:$((i-labstart)):1}"
      fg="$label_fg"
      printf -v cell '\033[48;5;%sm\033[38;5;%sm\033[1m%s\033[0m' "$bg" "$fg" "$ch"
    else
      printf -v cell '\033[48;5;%sm \033[0m' "$bg"
    fi
    out+="$cell"
  done
  printf '%s' "$out"
}

# ---- locate a writable place for the small usage cache -------------------
# Never hardcode an absolute path: prefer $HOME/.claude (Claude Code's own
# config dir), fall back to the directory this script itself lives in, and
# finally fall back to a temp dir. Any of these steps may fail (read-only
# filesystem, $HOME unset, etc.) without the script erroring out — caching
# is a nice-to-have, not a hard requirement, and a missing cache file is
# handled gracefully everywhere below.
script_source="${BASH_SOURCE[0]:-$0}"
script_dir="$(CDPATH= cd -- "$(dirname -- "$script_source")" 2>/dev/null && pwd -P)"

cache_dir=""
if [ -n "$HOME" ]; then
  if [ -d "$HOME/.claude" ] || mkdir -p "$HOME/.claude" 2>/dev/null; then
    [ -w "$HOME/.claude" ] && cache_dir="$HOME/.claude"
  fi
fi
if [ -z "$cache_dir" ] && [ -n "$script_dir" ] && [ -w "$script_dir" ]; then
  cache_dir="$script_dir"
fi
[ -z "$cache_dir" ] && cache_dir="${TMPDIR:-/tmp}"
cache_file="$cache_dir/statusline-cache.sh"

# Read a single key out of the cache file, if it exists, without sourcing it
# (so a stray/foreign file can never inject arbitrary variables into this
# script's scope). Values are stored %q-quoted, so `eval` only ever expands
# a quoted string literal, never a variable name from the file.
cache_get() {
  local key="$1" line val=""
  [ -r "$cache_file" ] || { printf ''; return 0; }
  line=$(grep -m1 "^${key}=" "$cache_file" 2>/dev/null)
  [ -z "$line" ] && { printf ''; return 0; }
  val="${line#*=}"
  eval "val=$val" 2>/dev/null
  printf '%s' "$val"
}

# ---- gather data --------------------------------------------------------
# Prefer jq when available; fall back to python3; if neither is installed
# (or parsing fails), every field below simply stays empty and the
# defaults/cache fallbacks further down kick in instead of the script
# erroring out.

model="" dir="" five_pct="" five_reset="" week_pct="" week_reset=""
ctx_pct="" ctx_used="" ctx_size="" effort="" thinking="" style=""

json_lines=""
if command -v jq >/dev/null 2>&1; then
  json_lines=$(printf '%s' "$input" | jq -r '
    (.model.display_name // "Model"),
    (.workspace.current_dir // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // ""),
    (.context_window.used_percentage // ""),
    (.context_window.total_input_tokens // ""),
    (.context_window.context_window_size // ""),
    (.effort.level // "medium"),
    (if .thinking.enabled == true then "on" else "off" end),
    (.output_style.name // "default")
  ' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  json_lines=$(printf '%s' "$input" | python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

def g(*path, default=""):
    v = d
    for k in path:
        if not isinstance(v, dict) or k not in v:
            return default
        v = v[k]
    return default if v is None else v

for f in [
    g("model", "display_name", default="Model"),
    g("workspace", "current_dir", default=""),
    g("rate_limits", "five_hour", "used_percentage", default=""),
    g("rate_limits", "five_hour", "resets_at", default=""),
    g("rate_limits", "seven_day", "used_percentage", default=""),
    g("rate_limits", "seven_day", "resets_at", default=""),
    g("context_window", "used_percentage", default=""),
    g("context_window", "total_input_tokens", default=""),
    g("context_window", "context_window_size", default=""),
    g("effort", "level", default="medium"),
    "on" if g("thinking", "enabled", default=False) is True else "off",
    g("output_style", "name", default="default"),
]:
    print(f)
' 2>/dev/null)
fi

if [ -n "$json_lines" ]; then
  # Portable line-split (macOS ships Bash 3.2, which has no `mapfile`). A
  # `while read` loop over a here-string yields the same array as `mapfile -t`
  # on Bash 3.2/4/5 alike, preserving blank fields the JSON left empty.
  _fields=()
  while IFS= read -r _line; do
    _fields+=("$_line")
  done <<< "$json_lines"
  model="${_fields[0]:-}"
  dir="${_fields[1]:-}"
  five_pct="${_fields[2]:-}"
  five_reset="${_fields[3]:-}"
  week_pct="${_fields[4]:-}"
  week_reset="${_fields[5]:-}"
  ctx_pct="${_fields[6]:-}"
  ctx_used="${_fields[7]:-}"
  ctx_size="${_fields[8]:-}"
  effort="${_fields[9]:-}"
  thinking="${_fields[10]:-}"
  style="${_fields[11]:-}"
fi

[ -z "$model" ] && model="Model"
[ -z "$dir" ] && dir="$PWD"
project=$(basename "$dir")

[ -z "$effort" ] && effort="medium"
[ -z "$thinking" ] && thinking="off"
[ -z "$style" ] && style="default"

# ---- usage cache: fall back to last known values, then persist -----------
# rate_limits is only sent after a session's first API response, and
# context_window's usage fields are null until messages have been
# exchanged, so a fresh session legitimately has nothing to show yet. Fall
# back to whatever was last cached (if anything) so the bars don't flash
# "n/a" on every render, then persist whatever we ended up with for next
# time. Works even if the cache file has never existed before.

is_num "$five_pct" || five_pct="$(cache_get five_pct)"
is_num "$five_reset" || five_reset="$(cache_get five_reset)"
is_num "$week_pct" || week_pct="$(cache_get week_pct)"
is_num "$week_reset" || week_reset="$(cache_get week_reset)"
is_num "$ctx_pct" || ctx_pct="$(cache_get ctx_pct)"
is_num "$ctx_used" || ctx_used="$(cache_get ctx_used)"
is_num "$ctx_size" || ctx_size="$(cache_get ctx_size)"

if [ -n "$five_pct$week_pct$ctx_pct" ]; then
  cache_tmp=$(mktemp "${cache_file}.XXXXXX" 2>/dev/null)
  if [ -n "$cache_tmp" ]; then
    {
      printf 'five_pct=%s\n' "$(printf '%q' "$five_pct")"
      printf 'five_reset=%s\n' "$(printf '%q' "$five_reset")"
      printf 'week_pct=%s\n' "$(printf '%q' "$week_pct")"
      printf 'week_reset=%s\n' "$(printf '%q' "$week_reset")"
      printf 'ctx_pct=%s\n' "$(printf '%q' "$ctx_pct")"
      printf 'ctx_used=%s\n' "$(printf '%q' "$ctx_used")"
      printf 'ctx_size=%s\n' "$(printf '%q' "$ctx_size")"
    } > "$cache_tmp" 2>/dev/null && mv -f "$cache_tmp" "$cache_file" 2>/dev/null
  fi
fi

# ---- line 1: rate limits + model context usage --------------------------

if is_num "$five_pct"; then
  five_int=$(printf '%.0f' "$five_pct")
  five_bar=$(make_bar "$five_int" 12 "${five_int}%")
else
  five_bar=$(make_bar 0 12 "n/a")
fi
five_time=$(fmt_time_of_day "$five_reset")

if is_num "$week_pct"; then
  week_int=$(printf '%.0f' "$week_pct")
  week_bar=$(make_bar "$week_int" 12 "${week_int}%")
else
  week_bar=$(make_bar 0 12 "n/a")
fi
week_time=$(fmt_weekday_time "$week_reset")

if is_num "$ctx_pct" && is_num "$ctx_used" && is_num "$ctx_size"; then
  ctx_int=$(printf '%.0f' "$ctx_pct")
  ctx_label="$(fmt_tokens "$ctx_used")/$(fmt_tokens "$ctx_size")"
  ctx_bar=$(make_bar "$ctx_int" 12 "$ctx_label")
else
  ctx_bar=$(make_bar 0 12 "n/a")
fi

line1=$(printf '%s %s \033[2m|\033[0m \033[2m🗓️\033[0m %s %s \033[2m|\033[0m \033[1m%s\033[0m %s' \
  "$five_bar" "$five_time" "$week_bar" "$week_time" "$model" "$ctx_bar")

# ---- account / org label (from ~/.claude.json, not the stdin payload) ----
# The statusline JSON on stdin has no account/org field; that lives in
# $HOME/.claude.json under oauthAccount. Missing file/fields/tools all
# degrade to simply omitting the label — never hardcode an absolute path,
# always derive it from $HOME.

account_label=""
claude_json="${HOME:+$HOME/.claude.json}"
if [ -n "$claude_json" ] && [ -r "$claude_json" ]; then
  org_name="" email_addr="" acct_lines=""
  if command -v jq >/dev/null 2>&1; then
    acct_lines=$(jq -r '(.oauthAccount.organizationName // ""), (.oauthAccount.emailAddress // "")' "$claude_json" 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    acct_lines=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    d = {}
oauth = d.get("oauthAccount") or {}
print(oauth.get("organizationName") or "")
print(oauth.get("emailAddress") or "")
' "$claude_json" 2>/dev/null)
  else
    # Last-resort grep/sed fallback when neither jq nor python3 is available.
    org_name=$(grep -o '"organizationName"[[:space:]]*:[[:space:]]*"[^"]*"' "$claude_json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    email_addr=$(grep -o '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' "$claude_json" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    acct_lines="$org_name"$'\n'"$email_addr"
  fi

  if [ -n "$acct_lines" ]; then
    # Portable line-split (see note above): Bash 3.2 has no `mapfile`.
    _acct_fields=()
    while IFS= read -r _line; do
      _acct_fields+=("$_line")
    done <<< "$acct_lines"
    org_name="${_acct_fields[0]:-}"
    email_addr="${_acct_fields[1]:-}"
  fi

  # U+FE0E VARIATION SELECTOR-15 forces text (monochrome) presentation for
  # the preceding icon codepoint, instead of the terminal's default colour
  # emoji glyph, so the icon inherits the orange ANSI colour below. Written
  # as the explicit UTF-8 byte sequence (EF B8 8E) to avoid any ambiguity
  # from an invisible literal character in the source.
  vs15=$'\357\270\216'

  if [ -n "$org_name" ]; then
    # Org account: show the org name outright, building icon.
    account_label="🏢${vs15} $org_name"
  elif [ -n "$email_addr" ]; then
    # Individual account: never show the raw address — redact it to
    # "abc***@***.tld" (person icon). Anything that doesn't cleanly look
    # like local@domain.tld is left unset rather than guessed at.
    case "$email_addr" in
      *@*.*)
        local_part="${email_addr%%@*}"
        domain_part="${email_addr#*@}"
        tld="${domain_part##*.}"
        [ -n "$local_part" ] && [ -n "$tld" ] && \
          account_label="👤${vs15} ${local_part:0:3}***@***.${tld}"
        ;;
    esac
  fi
fi

account_part=""
[ -n "$account_label" ] && account_part=$(printf '\033[38;5;208m%s\033[0m \033[2m·\033[0m ' "$account_label")

# OS username, prefixed onto the project name as "user:project". Falls back
# to `id -un` if $USER isn't set; if neither yields anything, just the
# project name is shown (no dangling colon).
os_user="${USER:-}"
[ -z "$os_user" ] && os_user="$(id -un 2>/dev/null)"
if [ -n "$os_user" ]; then
  user_project="${os_user}:${project}"
else
  user_project="$project"
fi

# ---- line 2: account / user:project / git branch / clean-dirty indicator -

branch=""
dot=""
if command -v git >/dev/null 2>&1 && git --no-optional-locks -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git --no-optional-locks -C "$dir" branch --show-current 2>/dev/null)
  if [ -n "$(git --no-optional-locks -C "$dir" status --porcelain 2>/dev/null)" ]; then
    dot=$(printf '\033[38;5;208m●\033[0m')
  else
    dot=$(printf '\033[32m●\033[0m')
  fi
fi

if [ -n "$branch" ]; then
  line2=$(printf '\033[2m⤷\033[0m %s\033[34m%s\033[0m \033[2m⎇\033[0m \033[33m%s\033[0m %s' "$account_part" "$user_project" "$branch" "$dot")
else
  line2=$(printf '\033[2m⤷\033[0m %s\033[34m%s\033[0m' "$account_part" "$user_project")
fi

# ---- line 3: effort / thinking / output style ----------------------------
# One consistent colour (blue) across the entire line, rather than mixing
# a coloured label with greyed-out values.

line3=$(printf '\033[38;5;111m⚙ effort:%s · think:%s · style:%s\033[0m' \
  "$effort" "$thinking" "$style")

# ---- output ---------------------------------------------------------------

printf '%s\n%s\n%s\n' "$line1" "$line2" "$line3"

