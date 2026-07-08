#!/bin/bash
# Agent Teamwork Setup

CONFIG="config.json"
SESSION=$(jq -r '.session_name // "agent-session"' "$CONFIG" 2>/dev/null)
MANAGER_MODEL=$(jq -r '.manager.model // "mimo/mimo-auto"' "$CONFIG" 2>/dev/null)

# Export for other scripts
export SESSION_NAME="$SESSION"

# Kill existing session
tmux kill-session -t "$SESSION" 2>/dev/null

# Create Manager window
tmux new-session -d -s "$SESSION" -n "Manager" -x 150 -y 40
tmux send-keys -t "$SESSION:Manager" "cd $(pwd) && cat prompts/manager_prompt.md" Enter

echo "✓ Agent Teamwork ready!"
echo "Session: $SESSION"
echo "Manager Model: $MANAGER_MODEL"
echo "Connect: tmux attach -t $SESSION"
