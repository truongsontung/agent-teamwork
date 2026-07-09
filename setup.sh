#!/bin/bash
# Agent Teamwork — Manager TUI trong tmux, bot bắn sự kiện qua tmux send-keys
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

export AGENT_TEAMWORK_HOME="$SCRIPT_DIR"
export PROJECT_DIR

MGR="$SCRIPT_DIR/manager.json"
WK="$SCRIPT_DIR/worker.json"
STATE_DIR="$PROJECT_DIR/.worker"
SESSION="${SESSION_NAME:-agent-teamwork}"

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

mkdir -p "$PROJECT_DIR/$mgr_dir/agents"

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

# Worker.md stub
wk_desc=$(jq -r '.description' "$WK"); wk_mode=$(jq -r '.mode' "$WK"); wk_prompt=$(jq -r '.prompt' "$WK")
cat > "$PROJECT_DIR/$mgr_dir/agents/worker.md" <<AGENTEOF
---
description: $wk_desc
mode: $wk_mode
---

$wk_prompt
AGENTEOF

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
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM EXIT

# ── Launch Manager trong tmux ────────────────────────────

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n "Manager"
tmux send-keys -t "$SESSION:Manager" \
    "cd '$PROJECT_DIR' && export PROJECT_DIR='$PROJECT_DIR' && $mgr_tool --model $mgr_model --agent manager" Enter

sleep 5
# Auto-confirm trust folder
if tmux capture-pane -t "$SESSION:Manager" -p 2>/dev/null | grep -q "I trust this folder"; then
    tmux send-keys -t "$SESSION:Manager" Enter
fi

# ── Bot daemon: SSE monitor workers + bắn sự kiện vào Manager ──

(
    # Start worker SSE bot
    bash "$SCRIPT_DIR/serve_controller.sh" bot &
    WBOT_PID=$!

    # Track last known states để chỉ bắn khi thay đổi
    declare -A LAST_STATE

    while true; do
        # Manager còn sống?
        tmux has-session -t "$SESSION" 2>/dev/null || break
        tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -q "^Manager$" || break

        # Kiểm tra worker events → bắn vào Manager qua tmux
        for f in "$STATE_DIR"/*.json; do
            [ -f "$f" ] || continue
            local n=$(jq -r .name "$f")
            local cur=""
            [ -f "$STATE_DIR/${n}.status" ] && cur=$(cat "$STATE_DIR/${n}.status")

            [ -z "$cur" ] && continue
            [ "$cur" = "${LAST_STATE[$n]:-}" ] && continue  # không đổi → skip

            LAST_STATE[$n]="$cur"

            # Bắn sự kiện ngắn gọn vào Manager TUI
            case "$cur" in
                idle)       tmux send-keys -t "$SESSION:Manager" "!ev $n done" Enter ;;
                permission) tmux send-keys -t "$SESSION:Manager" "!ev $n permission" Enter ;;
                error)      tmux send-keys -t "$SESSION:Manager" "!ev $n error" Enter ;;
            esac
        done

        # Manager permission auto-allow (nếu có)
        screen=$(tmux capture-pane -t "$SESSION:Manager" -p 2>/dev/null)
        if echo "$screen" | grep -qE "Permission required|Always allow"; then
            tmux send-keys -t "$SESSION:Manager" Enter
        fi
        if echo "$screen" | grep -q "I trust this folder"; then
            tmux send-keys -t "$SESSION:Manager" Enter
        fi

        # Restart worker bot nếu chết
        kill -0 "$WBOT_PID" 2>/dev/null || { bash "$SCRIPT_DIR/serve_controller.sh" bot & WBOT_PID=$!; }

        sleep 2
    done

    kill "$WBOT_PID" 2>/dev/null; wait "$WBOT_PID" 2>/dev/null
    bash "$SCRIPT_DIR/serve_controller.sh" killall 2>/dev/null
    rm -rf "$STATE_DIR" "$PROJECT_DIR/agent"
) &
BOT_PID=$!

echo "Manager: tmux attach -t $SESSION   (hoặc Ctrl+B D để detach)"
echo "Bot PID: $BOT_PID"
echo ""

# Auto-attach — user thấy Manager ngay
tmux attach -t "$SESSION"
