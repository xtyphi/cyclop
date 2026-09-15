#!/bin/bash
# Claude Code status line that also feeds Cyclop's Limits tab.
#
# Claude Code pipes its session JSON to the status line on every update, and
# for Pro/Max subscribers that JSON carries `rate_limits` (five_hour, seven_day:
# used_percentage, resets_at). The limits are copied to
# ~/Library/Application Support/Cyclop/claude-limits.json — the subscription
# token itself is never touched.
#
# Wire it up in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "<repo>/Scripts/claude-statusline.sh" }
set -uo pipefail

input="$(cat)"
dir="$HOME/Library/Application Support/Cyclop"

if jq -e '.rate_limits | objects | length > 0' >/dev/null 2>&1 <<<"$input"; then
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.claude-limits.XXXXXX")"
    # Written aside and moved in, so Cyclop never reads a half-written file.
    if jq -c --argjson now "$(date +%s)" '{updated_at: $now, rate_limits: .rate_limits}' \
        <<<"$input" >"$tmp"; then
        mv -f "$tmp" "$dir/claude-limits.json"
    else
        rm -f "$tmp"
    fi
fi

jq -r '
    def pct: . // empty | floor | tostring + "%";
    [
        (.model.display_name // empty),
        (.context_window.used_percentage | pct | "ctx " + .),
        (.rate_limits.five_hour.used_percentage | pct | "5h " + .),
        (.rate_limits.seven_day.used_percentage | pct | "wk " + .)
    ] | join(" · ")
' <<<"$input" 2>/dev/null
