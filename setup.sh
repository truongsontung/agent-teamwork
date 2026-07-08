#!/bin/bash
CONFIG="config.json"
SESSION=$(tmux display-message -p '#{session_name}')
MODEL=$(jq -r '.manager.model // "mimo/mimo-auto"' "$CONFIG")
TOOL=$(jq -r '.manager.tool // "opencode"' "$CONFIG")

export SESSION_NAME="$SESSION"

# Generate project config with auto permissions
PERM_JSON=$(jq '.manager.permission // {}' "$CONFIG")
for d in .opencode .mimocode; do
    mkdir -p "$d/agents"
    # Project-level config: auto-approve permissions
    cat > "$d/opencode.json" << EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "permission": $PERM_JSON
}
EOF
    # Agent file: frontmatter from config + prompt body
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
