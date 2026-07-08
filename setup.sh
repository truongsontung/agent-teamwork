#!/bin/bash
# Agent Teamwork Setup

CONFIG="config.json"
SESSION=$(jq -r '.session_name // "agent-session"' "$CONFIG" 2>/dev/null)
MANAGER_MODEL=$(jq -r '.manager.model // "mimo/mimo-auto"' "$CONFIG" 2>/dev/null)

# Export for other scripts
export SESSION_NAME="$SESSION"

MANAGER_TOOL=$(jq -r '.manager.tool // "opencode"' "$CONFIG" 2>/dev/null)
MANAGER_CMD="$MANAGER_TOOL --model $MANAGER_MODEL --agent manager"

SETUP_CMD="cd $(pwd) && export SESSION_NAME=$SESSION && echo '--- Launching Manager...' && $MANAGER_CMD"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    # Session exists: add Manager window
    tmux new-window -t "$SESSION" -n "Manager"
    tmux send-keys -t "$SESSION:Manager" "$SETUP_CMD" Enter
    echo "✓ Manager window added to session '$SESSION'"
else
    # Create new detached session (persists after SSH disconnect)
    tmux new-session -d -s "$SESSION" -n "Manager" -x 150 -y 40
    tmux send-keys -t "$SESSION:Manager" "$SETUP_CMD" Enter
    echo "✓ Agent Teamwork ready!"
    echo "Session: $SESSION"
    echo "Connect: tmux attach -t $SESSION"
fi
echo "Manager Tool: $MANAGER_TOOL"
echo "Manager Model: $MANAGER_MODEL"
