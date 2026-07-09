#!/bin/bash
# Khởi tạo tmux session + Manager theo cấu hình trong manager.json / worker.json.
# setup.sh đọc JSON, sinh file config tương ứng vào tool (opencode -> .opencode/,
# mimo -> .mimocode/) và launch Manager. Worker được tạo sau bởi Manager qua
# tmux_controller.sh (cũng đọc worker.json). Manager và Worker có file config
# riêng -> sửa quyền worker KHÔNG ảnh hưởng Manager.

MGR="manager.json"
WK="worker.json"
SESSION=$(tmux display-message -p '#{session_name}')

export SESSION_NAME="$SESSION"

mgr_tool=$(jq -r '.tool' "$MGR")
mgr_model=$(jq -r '.model' "$MGR")
mgr_perm=$(jq -c '.permission' "$MGR")

wk_tool=$(jq -r '.tool' "$WK")
wk_model=$(jq -r '.model' "$WK")
wk_perm=$(jq -c '.permission' "$WK")

# Map tool -> thư mục config của tool đó
dir_for() { [ "$1" = "opencode" ] && echo .opencode || echo .mimocode; }
mgr_dir=$(dir_for "$mgr_tool")
wk_dir=$(dir_for "$wk_tool")

write_perm() { # $1=dir  $2=perm_json
  mkdir -p "$1"
  jq -n --argjson p "$2" '{ "$schema": "https://opencode.ai/config.json", permission: $p }' > "$1/opencode.json"
}

# Ghi quyền của Manager vào tool config. Worker CHƯA được ghi ở đây —
# nó chỉ được ghi vào đúng file này ngay trước khi launch worker
# (xem tmux_controller.sh / manager.sh). Vì tool chỉ đọc config 1 lần
# lúc khởi động, ghi đè lúc tạo worker không ảnh hưởng Manager đang chạy.
write_perm "$mgr_dir" "$mgr_perm"
echo "✓ manager -> $mgr_dir/opencode.json (worker config được ghi khi tạo worker)"

# Sinh agent definition (frontmatter tối giản; quyền nằm ở tool config)
for d in .opencode .mimocode; do
  mkdir -p "$d/agents"
  cat > "$d/agents/manager.md" << 'EOF'
---
description: Manager agent điều khiển Worker agents qua tmux
mode: primary
---

EOF
  cat prompts/manager_prompt.md >> "$d/agents/manager.md"

  cat > "$d/agents/worker.md" << 'EOF'
---
description: Worker agent - bị Manager giao việc, quyền bị giới hạn
mode: primary
---

EOF
  cat prompts/worker_prompt.md >> "$d/agents/worker.md"
done
echo "✓ agent def: manager.md + worker.md (cả 2 tool dir)"

# Launch Manager
tmux kill-window -t "Manager" 2>/dev/null
tmux new-window -n "Manager"
tmux send-keys -t "Manager" "cd $(pwd) && export SESSION_NAME=$SESSION && $mgr_tool --model $mgr_model --agent manager" Enter
echo "✓ Manager: tab Manager, tool $mgr_tool, model $mgr_model, session $SESSION"
