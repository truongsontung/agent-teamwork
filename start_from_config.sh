#!/bin/bash
# Start Agent System from config.json
# Reads config and starts appropriate agents in tmux

set -e

CONFIG_FILE="config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config.json not found!"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required. Install with: apt install jq"
    exit 1
fi

# Read config
SESSION=$(jq -r '.session_name' "$CONFIG_FILE")
AGENT_A_TOOL=$(jq -r '.agents.A.tool' "$CONFIG_FILE")
AGENT_A_MODEL=$(jq -r '.agents.A.model' "$CONFIG_FILE")
AGENT_A_MODE=$(jq -r '.agents.A.mode' "$CONFIG_FILE")
AGENT_A_NAME=$(jq -r '.agents.A.name' "$CONFIG_FILE")

AGENT_B_TOOL=$(jq -r '.agents.B.tool' "$CONFIG_FILE")
AGENT_B_MODEL=$(jq -r '.agents.B.model' "$CONFIG_FILE")
AGENT_B_MODE=$(jq -r '.agents.B.mode' "$CONFIG_FILE")
AGENT_B_NAME=$(jq -r '.agents.B.name' "$CONFIG_FILE")

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Starting Agent System                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Agent A ($AGENT_A_NAME):                                  ║"
echo "║    Tool: $AGENT_A_TOOL                                         ║"
echo "║    Model: $AGENT_A_MODEL                                     ║"
echo "║    Mode: $AGENT_A_MODE                                        ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Agent B ($AGENT_B_NAME):                                   ║"
echo "║    Tool: $AGENT_B_TOOL                                         ║"
echo "║    Model: $AGENT_B_MODEL                                     ║"
echo "║    Mode: $AGENT_B_MODE                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Run handshake
./handshake.sh

# Kill existing session
tmux kill-session -t "$SESSION" 2>/dev/null

# Function to get start command based on tool
get_start_command() {
    local tool="$1"
    local model="$2"
    local mode="$3"
    local agent_label="$4"
    
    case "$tool" in
        opencode)
            echo "opencode --model $model --mode $mode"
            ;;
        mimo)
            echo "mimo --model $model"
            ;;
        claude)
            echo "claude --model $model"
            ;;
        codex)
            echo "codex --model $model"
            ;;
        *)
            echo "echo 'Unknown tool: $tool'"
            ;;
    esac
}

# Get commands
CMD_A=$(get_start_command "$AGENT_A_TOOL" "$AGENT_A_MODEL" "$AGENT_A_MODE" "A")
CMD_B=$(get_start_command "$AGENT_B_TOOL" "$AGENT_B_MODEL" "$AGENT_B_MODE" "B")

# Create session with Agent A
tmux new-session -d -s "$SESSION" -n "$AGENT_A_NAME" -x 120 -y 30

# Create window for Agent B
tmux new-window -t "$SESSION" -n "$AGENT_B_NAME"

# Setup Agent A window
tmux select-window -t "$SESSION:$AGENT_A_NAME"
tmux send-keys "cd $(pwd) && cat shared/messages/agent_a_context.txt && echo '' && echo 'Starting: $CMD_A' && $CMD_A" Enter

# Setup Agent B window
tmux select-window -t "$SESSION:$AGENT_B_NAME"
tmux send-keys "cd $(pwd) && cat shared/messages/agent_b_context.txt && echo '' && echo 'Starting: $CMD_B' && $CMD_B" Enter

# Go back to Agent A
tmux select-window -t "$SESSION:$AGENT_A_NAME"

echo "✓ Session '$SESSION' started!"
echo ""
echo "Connect: tmux attach -t $SESSION"
