#!/bin/bash
CONFIG="config.json"
SESSION=$(tmux display-message -p '#{session_name}')
MODEL=$(jq -r '.manager.model // "mimo/mimo-auto"' "$CONFIG" 2>/dev/null)
TOOL=$(jq -r '.manager.tool // "opencode"' "$CONFIG" 2>/dev/null)

export SESSION_NAME="$SESSION"

# Copy latest agent config to both tool dirs
for d in .opencode .mimocode; do
    mkdir -p "$d/agents"
    [ "$d" = ".opencode" ] || cp .opencode/agents/manager.md "$d/agents/manager.md"
done

# Kill old Manager window if exists, then create new
tmux kill-window -t "Manager" 2>/dev/null
tmux new-window -n "Manager"
tmux send-keys -t "Manager" "cd $(pwd) && export SESSION_NAME=$SESSION && $TOOL --model $MODEL --agent manager --trust" Enter
echo "✓ Manager: tab Manager, session $SESSION, tool $TOOL"
