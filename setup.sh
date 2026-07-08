#!/bin/bash
# Agent Teamwork Setup

SESSION="agent-session"

# Kill existing session
tmux kill-session -t "$SESSION" 2>/dev/null

# Create Manager window
tmux new-session -d -s "$SESSION" -n "Manager" -x 150 -y 40
tmux send-keys -t "$SESSION:Manager" "cd $(pwd) && cat prompts/manager_prompt.md" Enter

echo "✓ Agent Teamwork ready!"
echo "Connect: tmux attach -t $SESSION"
