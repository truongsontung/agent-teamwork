#!/bin/bash
CONFIG="config.json"
SESSION=$(tmux display-message -p '#{session_name}')
MODEL=$(jq -r '.manager.model // "mimo/mimo-auto"' "$CONFIG")
TOOL=$(jq -r '.manager.tool // "opencode"' "$CONFIG")

export SESSION_NAME="$SESSION"

# Generate agent definition for Manager
for d in .opencode .mimocode; do
    mkdir -p "$d/agents"
    cat > "$d/agents/manager.md" << EOF
---
description: Manager agent điều khiển Worker agents qua tmux
mode: primary
permission:
  bash: allow
  read: allow
  edit: allow
  write: allow
  glob: allow
  grep: allow
  task: allow
  question: allow
  websearch: allow
  webfetch: allow
  todowrite: allow
  skill: allow
---

$(cat prompts/manager_prompt.md)
EOF
done

tmux kill-window -t "Manager" 2>/dev/null
tmux new-window -n "Manager"
tmux send-keys -t "Manager" "cd $(pwd) && export SESSION_NAME=$SESSION && $TOOL --model $MODEL --agent manager" Enter
echo "✓ Manager: tab Manager, session $SESSION, tool $TOOL"
