#!/bin/bash
# Khởi tạo tmux session + Manager. Có thể chạy từ BẤT KỲ thư mục dự án nào.
# setup.sh nằm trong agent-teamwork/ — đọc manager.json từ thư mục của chính nó.
# PROJECT_DIR là nơi người dùng chạy script (thư mục dự án cần agent làm việc).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$PWD"
SESSION=$(tmux display-message -p '#{session_name}')

export AGENT_TEAMWORK_HOME="$SCRIPT_DIR"
export SESSION_NAME="$SESSION"

MGR="$SCRIPT_DIR/manager.json"

mgr_tool=$(jq -r '.tool' "$MGR")
mgr_model=$(jq -r '.model' "$MGR")
mgr_perm=$(jq -c '.permission' "$MGR")
mgr_desc=$(jq -r '.description' "$MGR")
mgr_mode=$(jq -r '.mode' "$MGR")
mgr_prompt=$(jq -r '.prompt' "$MGR")

# Thay placeholder bằng đường dẫn thực tế
mgr_perm="${mgr_perm//__PROJECT_DIR__/$PROJECT_DIR}"
mgr_prompt="${mgr_prompt//__AGENT_HOME__/$SCRIPT_DIR}"

dir_for() { [ "$1" = "opencode" ] && echo .opencode || echo .mimocode; }
mgr_dir=$(dir_for "$mgr_tool")

# Ghi tool config + agent definition cho Manager vào PROJECT_DIR
mkdir -p "$PROJECT_DIR/$mgr_dir"
jq -n --argjson p "$mgr_perm" '{ "$schema": "https://opencode.ai/config.json", permission: $p }' > "$PROJECT_DIR/$mgr_dir/opencode.json"
mkdir -p "$PROJECT_DIR/$mgr_dir/agents"
printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$mgr_desc" "$mgr_mode" "$mgr_prompt" > "$PROJECT_DIR/$mgr_dir/agents/manager.md"
echo "✓ manager -> $PROJECT_DIR/$mgr_dir/ (opencode.json + agents/manager.md)"

# Launch Manager
cd "$PROJECT_DIR"
tmux kill-window -t "Manager" 2>/dev/null
tmux new-window -n "Manager"
tmux send-keys -t "Manager" "cd '$PROJECT_DIR' && export AGENT_TEAMWORK_HOME='$SCRIPT_DIR' && export SESSION_NAME=$SESSION && $mgr_tool --model $mgr_model --agent manager" Enter
echo "✓ Manager: tool $mgr_tool, model $mgr_model, project $PROJECT_DIR"
