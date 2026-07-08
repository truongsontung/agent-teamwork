#!/bin/bash
CONFIG="config.json"
SESSION=$(tmux display-message -p '#{session_name}')
MODEL=$(jq -r '.manager.model // "mimo/mimo-auto"' "$CONFIG")
TOOL=$(jq -r '.manager.tool // "opencode"' "$CONFIG")

export SESSION_NAME="$SESSION"

for d in .opencode .mimocode; do
    mkdir -p "$d/agents"

    # Project-level: auto-approve for ALL agents (Manager + Workers)
    cat > "$d/opencode.json" << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "bash": "allow",
    "read": "allow",
    "glob": "allow",
    "grep": "allow",
    "task": "allow",
    "question": "allow",
    "websearch": "allow"
  }
}
EOF

    # Agent-specific: Manager (edit:deny vì chỉ dùng tmux điều khiển)
    {
        echo "---"
        echo "description: Manager agent điều khiển Worker agents qua tmux"
        echo "mode: primary"
        echo "permission:"
        jq -r '.manager.permission // {} | to_entries[] | "  \(.key): \(.value)"' "$CONFIG"
        echo "---"
        echo ""
        cat prompts/manager_prompt.md
    } > "$d/agents/manager.md"
done

tmux kill-window -t "Manager" 2>/dev/null
tmux new-window -n "Manager"
tmux send-keys -t "Manager" "cd $(pwd) && export SESSION_NAME=$SESSION && $TOOL --model $MODEL --agent manager" Enter
echo "✓ Manager: tab Manager, session $SESSION, tool $TOOL"
