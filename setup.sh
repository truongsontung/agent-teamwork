#!/bin/bash
# Khởi tạo tmux session + Manager theo nội dung trong manager.json / worker.json.
# manager.json là NGUỒN DUY NHẤT cho Manager (tool, model, permission, prompt, ...).
# worker.json là NGUỒN DUY NHẤT cho Worker (tool, model, max_workers, permission, prompt, ...).
# setup.sh đọc JSON, sinh tool config + agent definition, launch Manager.
# Worker config được ghi khi Manager tạo worker (tmux_controller.sh / manager.sh).

MGR="manager.json"
WK="worker.json"
SESSION=$(tmux display-message -p '#{session_name}')

export SESSION_NAME="$SESSION"

# Đọc manager.json
mgr_tool=$(jq -r '.tool' "$MGR")
mgr_model=$(jq -r '.model' "$MGR")
mgr_perm=$(jq -c '.permission' "$MGR")
mgr_desc=$(jq -r '.description' "$MGR")
mgr_mode=$(jq -r '.mode' "$MGR")
mgr_prompt=$(jq -r '.prompt' "$MGR")

# Đọc worker.json (agent info để sinh worker.md, quyền ghi khi tạo worker)
wk_desc=$(jq -r '.description' "$WK")
wk_mode=$(jq -r '.mode' "$WK")
wk_prompt=$(jq -r '.prompt' "$WK")

# Map tool -> thư mục config của tool đó
dir_for() { [ "$1" = "opencode" ] && echo .opencode || echo .mimocode; }
mgr_dir=$(dir_for "$mgr_tool")

write_perm() { # $1=dir  $2=perm_json
  mkdir -p "$1"
  jq -n --argjson p "$2" '{ "$schema": "https://opencode.ai/config.json", permission: $p }' > "$1/opencode.json"
}

# Ghi quyền Manager vào tool config.
# Worker CHƯA được ghi ở đây — nó được ghi ngay trước khi launch worker
# (xem tmux_controller.sh / manager.sh). Vì tool chỉ đọc config 1 lần
# lúc khởi động, ghi đè này không ảnh hưởng Manager đang chạy.
write_perm "$mgr_dir" "$mgr_perm"
echo "✓ manager -> $mgr_dir/opencode.json"

# Helper: ghi agent definition ra file md từ JSON fields
write_agent() { # $1=dir $2=name $3=desc $4=mode $5=prompt
  mkdir -p "$1/agents"
  printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$3" "$4" "$5" > "$1/agents/$2.md"
}

# Sinh agent definition cho Manager & Worker vào CẢ 2 tool dir
for d in .opencode .mimocode; do
  write_agent "$d" "manager" "$mgr_desc" "$mgr_mode" "$mgr_prompt"
  write_agent "$d" "worker"  "$wk_desc"  "$wk_mode"  "$wk_prompt"
done
echo "✓ agent def: manager.md + worker.md (cả 2 tool dir, từ JSON prompt)"

# Launch Manager
tmux kill-window -t "Manager" 2>/dev/null
tmux new-window -n "Manager"
tmux send-keys -t "Manager" "cd $(pwd) && export SESSION_NAME=$SESSION && $mgr_tool --model $mgr_model --agent manager" Enter
echo "✓ Manager: tab Manager, tool $mgr_tool, model $mgr_model, session $SESSION"
