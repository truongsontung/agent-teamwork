#!/bin/bash
# One-click Setup & Run - Reads everything from config.json

set -e

CONFIG="config.json"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Agent System Setup                             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Read config
AGENT_A_TOOL=$(jq -r '.agents.A.tool' "$CONFIG")
AGENT_A_MODEL=$(jq -r '.agents.A.model' "$CONFIG")
AGENT_A_PERM_MODE=$(jq -r '.agents.A.permission.mode' "$CONFIG")

AGENT_B_TOOL=$(jq -r '.agents.B.tool' "$CONFIG")
AGENT_B_MODEL=$(jq -r '.agents.B.model' "$CONFIG")
AGENT_B_PERM_MODE=$(jq -r '.agents.B.permission.mode' "$CONFIG")

# Show config
echo "┌─────────────────────────────────────────────────────────┐"
echo "│  AGENT A (Manager)                                     │"
echo "├─────────────────────────────────────────────────────────┤"
echo "│  Tool:       $AGENT_A_TOOL"
echo "│  Model:      $AGENT_A_MODEL"
echo "│  Permission: $AGENT_A_PERM_MODE (tự quyết định)"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│  AGENT B (Worker)                                      │"
echo "├─────────────────────────────────────────────────────────┤"
echo "│  Tool:       $AGENT_B_TOOL"
echo "│  Model:      $AGENT_B_MODEL"
echo "│  Permission: $AGENT_B_PERM_MODE (do A quyết định)"
echo "└─────────────────────────────────────────────────────────┘"
echo ""

# Check dependencies
echo "1. Checking dependencies..."
if ! command -v jq &> /dev/null; then
    sudo apt install jq -y
fi
echo "   ✓ jq ready"

# Create agent context
echo ""
echo "2. Creating agent context..."
./handshake.sh

# Setup permissions from config
echo ""
echo "3. Setting permissions..."

# Agent A permission
mkdir -p shared/state
jq '{auto_approve: .agents.A.permission.auto_approve, auto_deny: .agents.A.permission.auto_deny}' "$CONFIG" > shared/state/policy_agent_A.json
echo "   ✓ Agent A: $AGENT_A_PERM_MODE"

# Agent B permission (controlled by A)
jq '{auto_approve: .agents.B.permission.auto_approve, auto_deny: .agents.B.permission.auto_deny}' "$CONFIG" > shared/state/policy_agent_B.json
echo "   ✓ Agent B: controlled by Agent A"

# Start tmux
echo ""
echo "4. Starting agent system..."
./start.sh

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         READY!                                         ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Connect: tmux attach -t agent-session                  ║"
echo "║                                                         ║"
echo "║  Permission:                                            ║"
echo "║    Agent A: tự quyết định (auto)                       ║"
echo "║    Agent B: do A quyết định                             ║"
echo "║      ./agent_perm.sh allow <file>                       ║"
echo "║      ./agent_perm.sh deny <file>                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
