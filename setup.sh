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
mgr_perm=$(jq -c '.permission' "$MGR")
mgr_desc=$(jq -r '.description' "$MGR")
mgr_mode=$(jq -r '.mode' "$MGR")
mgr_prompt=$(jq -r '.prompt' "$MGR")

mgr_perm="${mgr_perm//__PROJECT_DIR__/$PROJECT_DIR}"
mgr_perm="${mgr_perm//__AGENT_HOME__/$SCRIPT_DIR}"

# ── Tạo wrapper ./agent ──────────────────────────────────

cat > "$PROJECT_DIR/agent" <<WRAPPER
#!/bin/bash
export PROJECT_DIR="$PROJECT_DIR"
exec bash "$SCRIPT_DIR/serve_controller.sh" "\$@"
WRAPPER
chmod +x "$PROJECT_DIR/agent"

# ── Cho phép Manager truy cập agent-teamwork (để gọi script) ──

mgr_perm=$(echo "$mgr_perm" | jq --arg d "$SCRIPT_DIR" '.external_directory[$d + "/*"] = "allow"')

dir_for() { [ "$1" = "opencode" ] && echo .opencode || echo .mimocode; }
mgr_dir=$(dir_for "$mgr_tool")

# ── Ghi config Manager ───────────────────────────────────

mkdir -p "$PROJECT_DIR/$mgr_dir"
jq -n --argjson p "$mgr_perm" '{"$schema":"https://opencode.ai/config.json",permission:$p}' \
    > "$PROJECT_DIR/$mgr_dir/opencode.json"

mkdir -p "$PROJECT_DIR/$mgr_dir/agents"
printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$mgr_desc" "$mgr_mode" "$mgr_prompt" \
    > "$PROJECT_DIR/$mgr_dir/agents/manager.md"

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
