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

# Thay placeholder + thêm AGENT_HOME vào external_directory (để Manager truy cập script)
mgr_perm="${mgr_perm//__PROJECT_DIR__/$PROJECT_DIR}"
mgr_perm=$(echo "$mgr_perm" | jq --arg d "$SCRIPT_DIR" '.external_directory[$d + "/*"] = "allow"')
mgr_prompt="${mgr_prompt//__AGENT_HOME__/$SCRIPT_DIR}"

dir_for() { [ "$1" = "opencode" ] && echo .opencode || echo .mimocode; }
mgr_dir=$(dir_for "$mgr_tool")

# Ghi tool config + agent definition cho Manager vào PROJECT_DIR
mkdir -p "$PROJECT_DIR/$mgr_dir"
jq -n --argjson p "$mgr_perm" '{ "$schema": "https://opencode.ai/config.json", permission: $p }' > "$PROJECT_DIR/$mgr_dir/opencode.json"

# Sinh agent md (cả manager.md + worker.md) — mimo scan TẤT CẢ file agents lúc start,
# nếu worker.md hỏng/null thì crash. Worker.md sẽ bị ghi đè khi tạo worker thực tế.
mkdir -p "$PROJECT_DIR/$mgr_dir/agents"
printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$mgr_desc" "$mgr_mode" "$mgr_prompt" > "$PROJECT_DIR/$mgr_dir/agents/manager.md"

WK="$SCRIPT_DIR/worker.json"
wk_desc=$(jq -r '.description' "$WK"); wk_mode=$(jq -r '.mode' "$WK"); wk_prompt=$(jq -r '.prompt' "$WK")
printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$wk_desc" "$wk_mode" "$wk_prompt" > "$PROJECT_DIR/$mgr_dir/agents/worker.md"
echo "✓ manager -> $PROJECT_DIR/$mgr_dir/ (opencode.json + agents/manager.md + agents/worker.md)"

# Launch Manager
cd "$PROJECT_DIR"
tmux kill-window -t "Manager" 2>/dev/null
tmux new-window -n "Manager"
tmux send-keys -t "Manager" "cd '$PROJECT_DIR' && export AGENT_TEAMWORK_HOME='$SCRIPT_DIR' && export SESSION_NAME=$SESSION && $mgr_tool --model $mgr_model --agent manager" Enter

# Auto-confirm trust prompt ("Yes, I trust this folder") khi mở thư mục mới lần đầu
sleep 5
if tmux capture-pane -t "Manager" -p 2>/dev/null | grep -q "I trust this folder"; then
    tmux send-keys -t "Manager" Enter
fi

# Bot nền: theo dõi Manager, auto-Enter khi gặp permission prompt của chính Manager
# (Worker prompt do Manager tự xử lý qua smart + allow)
(
    while tmux has-session -t "$SESSION" 2>/dev/null; do
        screen=$(tmux capture-pane -t "$SESSION:Manager" -p 2>/dev/null)
        if echo "$screen" | grep -qE "Permission required|Allow once|Always allow|Reject"; then
            tmux send-keys -t "$SESSION:Manager" Enter
        fi
        sleep 3
    done
) &
echo "✓ Manager: tool $mgr_tool, model $mgr_model, project $PROJECT_DIR (bot permission ON)"
