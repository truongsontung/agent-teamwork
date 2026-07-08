#!/bin/bash
CONFIG="config.json"
SESSION=$(tmux display-message -p '#{session_name}')
MODEL=$(jq -r '.manager.model // "mimo/mimo-auto"' "$CONFIG")
TOOL=$(jq -r '.manager.tool // "opencode"' "$CONFIG")
TRUST=$(jq -r '.manager.auto_trust // false' "$CONFIG")

export SESSION_NAME="$SESSION"

# Generate agent file from config.json + prompt
generate_agent() {
    local out="$1/agents/manager.md"
    mkdir -p "$(dirname "$out")"

    # Build YAML frontmatter from config
    {
        echo "---"
        echo "description: Manager agent điều khiển Worker agents qua tmux"
        echo "mode: primary"
        echo "permission:"
        jq -r '.manager.permission // {} | to_entries[] | "  \(.key): \(.value)"' "$CONFIG"
        echo "---"
        echo ""
        cat prompts/manager_prompt.md
    } > "$out"
}

generate_agent ".opencode"
generate_agent ".mimocode"

TRUST_FLAG=""
[ "$TRUST" = "true" ] && TRUST_FLAG="--trust"

tmux kill-window -t "Manager" 2>/dev/null
tmux new-window -n "Manager"
tmux send-keys -t "Manager" "cd $(pwd) && export SESSION_NAME=$SESSION && $TOOL --model $MODEL --agent manager $TRUST_FLAG" Enter
echo "✓ Manager: tab Manager, session $SESSION, tool $TOOL, trust=$TRUST"
