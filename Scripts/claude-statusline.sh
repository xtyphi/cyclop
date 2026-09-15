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
    file="$dir/claude-limits.json"
    # A damaged file is treated as absent rather than blocking every write.
    old="$(jq -c 'objects' "$file" 2>/dev/null)"
    [ -n "$old" ] || old='{}'
    tmp="$(mktemp "$dir/.claude-limits.XXXXXX")"
    # Merged window by window with what is already on disk. Several sessions
    # write here, and an idle one re-renders with the numbers it last saw: for
    # the same window (same resets_at) usage only grows, so a lower figure is
    # an older one and loses. A window missing from this update is kept —
    # Claude Code drops a window once it resets, and Cyclop shows a passed
    # resets_at as full on its own.
    if jq -c --argjson now "$(date +%s)" --argjson old "$old" '
        def pick($new; $prev):
            if $new == null then $prev
            elif $prev == null then $new
            elif ($prev.resets_at // 0) > ($new.resets_at // 0) then $prev
            elif $prev.resets_at == $new.resets_at
                 and ($prev.used_percentage // 0) > ($new.used_percentage // 0) then $prev
            else $new end;
        ($old.rate_limits // {}) as $p
        | {five_hour: pick(.rate_limits.five_hour; $p.five_hour),
           seven_day: pick(.rate_limits.seven_day; $p.seven_day)}
        | with_entries(select(.value != null)) as $merged
        | {updated_at: (if $merged == $p then ($old.updated_at // $now) else $now end),
           rate_limits: $merged}
    ' <<<"$input" >"$tmp" 2>/dev/null; then
        # Written aside and moved in, so Cyclop never reads a half-written file.
        mv -f "$tmp" "$file"
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
