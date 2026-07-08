#!/bin/bash
# Start Agent System with Permission Handler
# Usage: ./start.sh [config_file]

CONFIG="${1:-config.json}"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Starting Agent System                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Run handshake
./handshake.sh

# Create permission policy
./permission_handler.sh policy

# Kill existing session
tmux kill-session -t "agent-session" 2>/dev/null

# Create session
tmux new-session -d -s "agent-session" -n "Manager" -x 120 -y 30
tmux new-window -t "agent-session" -n "Worker"

# Setup Agent A with permission handler
tmux select-window -t "agent-session:Manager"
tmux send-keys "cd $(pwd) && echo '=== AGENT A (MANAGER) ===' && echo '' && cat shared/messages/agent_a_context.txt && echo '' && echo '=== Permission Handler Ready ===' && echo 'Use: ./permission_handler.sh read <file>' && echo ''" Enter

# Setup Agent B
tmux select-window -t "agent-session:Worker"
tmux send-keys "cd $(pwd) && echo '=== AGENT B (WORKER) ===' && echo '' && cat shared/messages/agent_b_context.txt && echo ''" Enter

# Go back to Agent A
tmux select-window -t "agent-session:Manager"

echo "✓ Session started with Permission Handler!"
echo ""
echo "Connect: tmux attach -t agent-session"
echo ""
echo "Permission Policy:"
echo "  Auto-approve: *.md, *.txt, *.json, src/*"
echo "  Require approval: *.env, *.key, *credentials*"
