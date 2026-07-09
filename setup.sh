#!/bin/bash
# Khởi tạo tmux session + Manager theo manager.json (NGUỒN DUY NHẤT).
# setup.sh CHỈ lo cho Manager. Worker được thiết lập bởi tmux_controller.sh
# NGAY TRƯỚC KHI launch worker (tool config + agent worker.md từ worker.json).

MGR="manager.json"
SESSION=$(tmux display-message -p '#{session_name}')

export SESSION_NAME="$SESSION"

mgr_tool=$(jq -r '.tool' "$MGR")
mgr_model=$(jq -r '.model' "$MGR")
mgr_perm=$(jq -c '.permission' "$MGR")
mgr_desc=$(jq -r '.description' "$MGR")
mgr_mode=$(jq -r '.mode' "$MGR")
mgr_prompt=$(jq -r '.prompt' "$MGR")

dir_for() { [ "$1" = "opencode" ] && echo .opencode || echo .mimocode; }
mgr_dir=$(dir_for "$mgr_tool")

# Ghi tool config (permission) + agent definition (manager.md) cho Manager
mkdir -p "$mgr_dir"
mgr_perm="${mgr_perm//__PROJECT_DIR__/$PWD}"
jq -n --argjson p "$mgr_perm" '{ "$schema": "https://opencode.ai/config.json", permission: $p }' > "$mgr_dir/opencode.json"
mkdir -p "$mgr_dir/agents"
printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$mgr_desc" "$mgr_mode" "$mgr_prompt" > "$mgr_dir/agents/manager.md"
echo "✓ manager -> $mgr_dir/ (opencode.json + agents/manager.md)"

# Launch Manager
tmux kill-window -t "Manager" 2>/dev/null
tmux new-window -n "Manager"
tmux send-keys -t "Manager" "cd $(pwd) && export SESSION_NAME=$SESSION && $mgr_tool --model $mgr_model --agent manager" Enter
echo "✓ Manager: tab Manager, tool $mgr_tool, model $mgr_model, session $SESSION"
