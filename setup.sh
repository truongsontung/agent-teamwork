#!/bin/bash
# Agent Teamwork Setup

CONFIG="config.json"
SESSION=$(jq -r '.session_name // "agent-session"' "$CONFIG" 2>/dev/null)
MANAGER_MODEL=$(jq -r '.manager.model // "mimo/mimo-auto"' "$CONFIG" 2>/dev/null)

# Export for other scripts
export SESSION_NAME="$SESSION"

MANAGER_TOOL=$(jq -r '.manager.tool // "opencode"' "$CONFIG" 2>/dev/null)
MANAGER_CMD="$MANAGER_TOOL --model $MANAGER_MODEL --agent manager"

# Copy agent config for both opencode and mimo
for d in .opencode .mimocode; do
    mkdir -p "$d/agents"
    [ -f "$d/agents/manager.md" ] || cp .opencode/agents/manager.md "$d/agents/manager.md"
done

SETUP_CMD="cd $(pwd) && export SESSION_NAME=$SESSION && echo '--- Launching Manager...' && $MANAGER_CMD"

if [ -n "$TMUX" ]; then
    # Inside tmux → use current session name
    CURRENT_SESSION=$(tmux display-message -p '#{session_name}')
    SETUP_CMD="cd $(pwd) && export SESSION_NAME=$CURRENT_SESSION && echo '--- Launching Manager...' && $MANAGER_CMD"
    tmux new-window -n "Manager"
    tmux send-keys -t "Manager" "$SETUP_CMD" Enter
    echo "✓ Manager window created in session '$CURRENT_SESSION'"
else
    # Outside tmux → create detached session
    tmux kill-session -t "$SESSION" 2>/dev/null
    tmux new-session -d -s "$SESSION" -n "Manager" -x 150 -y 40
    tmux send-keys -t "$SESSION:Manager" "$SETUP_CMD" Enter
    echo "✓ Agent Teamwork ready!"
    echo "Session: $SESSION"
    echo "Connect: tmux attach -t $SESSION"
fi
echo "Manager Tool: $MANAGER_TOOL"
echo "Manager Model: $MANAGER_MODEL"
