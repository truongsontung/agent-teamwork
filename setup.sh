#!/bin/bash
CONFIG="config.json"
SESSION=$(tmux display-message -p '#{session_name}')
MODEL=$(jq -r '.manager.model // "mimo/mimo-auto"' "$CONFIG" 2>/dev/null)
TOOL=$(jq -r '.manager.tool // "opencode"' "$CONFIG" 2>/dev/null)

export SESSION_NAME="$SESSION"

for d in .opencode .mimocode; do
    mkdir -p "$d/agents"
    [ -f "$d/agents/manager.md" ] || cp .opencode/agents/manager.md "$d/agents/manager.md"
done

tmux new-window -n "Manager"
tmux send-keys -t "Manager" "cd $(pwd) && export SESSION_NAME=$SESSION && $TOOL --model $MODEL --agent manager" Enter
echo "✓ Manager: window Manager, session $SESSION"
