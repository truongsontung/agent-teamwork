#!/bin/bash
# Agent Teamwork — 1 lệnh duy nhất, không tmux
# cd ~/my-project && ~/agent-teamwork/setup.sh
# → Manager TUI mở ngay terminal này
# → Bot chạy ngầm giám sát worker
# → Thoát TUI → dọn sạch → exit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

export AGENT_TEAMWORK_HOME="$SCRIPT_DIR"
export PROJECT_DIR

MGR="$SCRIPT_DIR/manager.json"
WK="$SCRIPT_DIR/worker.json"
STATE_DIR="$PROJECT_DIR/.worker"

mgr_tool=$(jq -r '.tool' "$MGR")
mgr_model=$(jq -r '.model' "$MGR")
mgr_desc=$(jq -r '.description' "$MGR")
mgr_mode=$(jq -r '.mode' "$MGR")
mgr_prompt=$(jq -r '.prompt' "$MGR")

# ── Tạo wrapper ./agent ──────────────────────────────────

cat > "$PROJECT_DIR/agent" <<WRAPPER
#!/bin/bash
export PROJECT_DIR="$PROJECT_DIR"
exec bash "$SCRIPT_DIR/serve_controller.sh" "\$@"
WRAPPER
chmod +x "$PROJECT_DIR/agent"

dir_for() { [ "$1" = "opencode" ] && echo .opencode || echo .mimocode; }
mgr_dir=$(dir_for "$mgr_tool")
# ── Ghi config Manager ───────────────────────────────────

mkdir -p "$PROJECT_DIR/$mgr_dir"

# opencode.json: chỉ external_directory (security), không permission
jq -n --arg d "$SCRIPT_DIR" '{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "external_directory": {
      ($d + "/.worker/*"): "deny",
      ($d + "/*.sh"): "deny",
      ($d + "/*.json"): "deny"
    }
  }
}' > "$PROJECT_DIR/$mgr_dir/opencode.json"

mkdir -p "$PROJECT_DIR/$mgr_dir/agents"

# manager.md: permission trong frontmatter → deny hết tool trừ bash
# model sẽ KHÔNG THẤY read/edit/write trong system prompt
cat > "$PROJECT_DIR/$mgr_dir/agents/manager.md" <<AGENTEOF
---
description: $mgr_desc
mode: $mgr_mode
permission:
  read: deny
  edit: deny
  write: deny
  glob: deny
  grep: deny
  task: deny
  webfetch: deny
  websearch: deny
  question: deny
  bash: allow
---

$mgr_prompt
AGENTEOF

wk_desc=$(jq -r '.description' "$WK"); wk_mode=$(jq -r '.mode' "$WK"); wk_prompt=$(jq -r '.prompt' "$WK")
printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$wk_desc" "$wk_mode" "$wk_prompt" \
    > "$PROJECT_DIR/$mgr_dir/agents/worker.md"

# ── Dọn state cũ ─────────────────────────────────────────

rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"

# ── Cleanup ──────────────────────────────────────────────

cleanup() {
    echo ""
    bash "$SCRIPT_DIR/serve_controller.sh" killall 2>/dev/null || true
    [ -n "${BOT_PID:-}" ] && kill "$BOT_PID" 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    rm -rf "$STATE_DIR" "$PROJECT_DIR/agent"
    rm -f "$PROJECT_DIR/$mgr_dir/agents/manager.md" "$PROJECT_DIR/$mgr_dir/agents/worker.md"
    echo "✓ cleaned up"
    exit 0
}
trap cleanup INT TERM EXIT

# ── Khởi động bot ngầm ───────────────────────────────────

bash "$SCRIPT_DIR/serve_controller.sh" bot &
BOT_PID=$!

# ── Mở Manager TUI ngay terminal này ─────────────────────

cd "$PROJECT_DIR"
echo ""
echo "Agent Teamwork ready — giao việc cho Manager bên dưới."
echo "Bot worker đang chạy ngầm (pid $BOT_PID)."
echo "Thoát opencode (Ctrl+C) để dọn dẹp và exit."
echo "───────────────────────────────────────────────"
export PROJECT_DIR
exec $mgr_tool --model $mgr_model --agent manager
