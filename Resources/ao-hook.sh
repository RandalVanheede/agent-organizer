#!/bin/sh
# Agent Organizer hook for Claude Code.
#   usage (from ~/.claude/settings.json hooks): ao-hook <EventName>
# Reads Claude's hook JSON on stdin and drops one event file for the app to
# pick up. No-op unless this claude runs inside an Agent Organizer tmux pane,
# so it never fires for sessions started elsewhere.
case "${TMUX:-}" in
  *"Agent Organizer/tmux.sock"*) ;;
  *) cat >/dev/null 2>&1; exit 0 ;;
esac

dir="$HOME/Library/Application Support/Agent Organizer/events"
mkdir -p "$dir" 2>/dev/null || exit 0

payload=$(cat)
[ -n "$payload" ] || payload='{}'

tmp="$dir/.tmp.$$"
printf '{"pane":"%s","event":"%s","payload":%s}\n' "${TMUX_PANE:-}" "${1:-unknown}" "$payload" > "$tmp" \
  && mv "$tmp" "$dir/$(date +%s)-$$.json"
exit 0
