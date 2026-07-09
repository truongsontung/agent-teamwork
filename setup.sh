#!/bin/bash
# Agent Teamwork — setup Manager + Bot Daemon
# Manager: opencode TUI (tmux window)
# Workers: opencode serve processes (HTTP API + SSE events)
# Daemon: 1 process quản lý tất cả — permission auto-allow Manager,
#          SSE monitor workers, dọn dẹp khi Manager tắt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

export AGENT_TEAMWORK_HOME="$SCRIPT_DIR"
export PROJECT_DIR

MGR="$SCRIPT_DIR/manager.json"
WK="$SCRIPT_DIR/worker.json"
STATE_DIR="$SCRIPT_DIR/.worker"

mgr_tool=$(jq -r '.tool' "$MGR")
mgr_model=$(jq -r '.model' "$MGR")
mgr_perm=$(jq -c '.permission' "$MGR")
mgr_desc=$(jq -r '.description' "$MGR")
mgr_mode=$(jq -r '.mode' "$MGR")
mgr_prompt=$(jq -r '.prompt' "$MGR")

# Replace placeholders
mgr_perm="${mgr_perm//__PROJECT_DIR__/$PROJECT_DIR}"
mgr_perm=$(echo "$mgr_perm" | jq --arg d "$SCRIPT_DIR" '.external_directory[$d + "/*"] = "allow"')
mgr_prompt="${mgr_prompt//__AGENT_HOME__/$SCRIPT_DIR}"

dir_for() { [ "$1" = "opencode" ] && echo .opencode || echo .mimocode; }
mgr_dir=$(dir_for "$mgr_tool")

# ── Ghi config Manager ──────────────────────────────────

mkdir -p "$PROJECT_DIR/$mgr_dir"
jq -n --argjson p "$mgr_perm" \
    '{"$schema":"https://opencode.ai/config.json", permission:$p}' \
    > "$PROJECT_DIR/$mgr_dir/opencode.json"

mkdir -p "$PROJECT_DIR/$mgr_dir/agents"
printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' \
    "$mgr_desc" "$mgr_mode" "$mgr_prompt" \
    > "$PROJECT_DIR/$mgr_dir/agents/manager.md"

# Worker.md stub
wk_desc=$(jq -r '.description' "$WK")
wk_mode=$(jq -r '.mode' "$WK")
wk_prompt=$(jq -r '.prompt' "$WK")
printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' \
    "$wk_desc" "$wk_mode" "$wk_prompt" \
    > "$PROJECT_DIR/$mgr_dir/agents/worker.md"

echo "✓ Manager config → $PROJECT_DIR/$mgr_dir/"

# ── Dọn dẹp worker + temp cũ ────────────────────────────

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"

# ── Cleanup function (gọi khi Ctrl+C hoặc Manager tắt) ──

cleanup() {
    echo ""
    echo "→ Cleaning up..."

    # 1. Kill all serve workers + SSE monitors
    bash "$SCRIPT_DIR/serve_controller.sh" killall 2>/dev/null || true

    # 2. Kill all child processes of this script
    pkill -P $$ 2>/dev/null || true

    # 3. Remove state directory (.worker/)
    rm -rf "$STATE_DIR"

    # 4. Remove agent files created by setup (giữ lại opencode.json của project)
    rm -f "$PROJECT_DIR/$mgr_dir/agents/manager.md" \
          "$PROJECT_DIR/$mgr_dir/agents/worker.md"

    echo "✓ Cleanup complete"
    exit 0
}
trap cleanup INT TERM

# ── Launch Manager (tmux TUI) ───────────────────────────

SESSION="${SESSION_NAME:-agent-teamwork}"

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n "Manager"
else
    tmux kill-window -t "$SESSION:Manager" 2>/dev/null || true
fi

tmux new-window -t "$SESSION:" -n "Manager"
tmux send-keys -t "$SESSION:Manager" \
    "cd '$PROJECT_DIR' && export AGENT_TEAMWORK_HOME='$SCRIPT_DIR' && export PROJECT_DIR='$PROJECT_DIR' && $mgr_tool --model $mgr_model --agent manager" Enter

sleep 5

# Auto-confirm trust folder dialog (xuất hiện lần đầu mở thư mục)
if tmux capture-pane -t "$SESSION:Manager" -p 2>/dev/null | grep -q "I trust this folder"; then
    tmux send-keys -t "$SESSION:Manager" Enter
    echo "→ Trust folder confirmed"
fi

# ── Bot Daemon (1 process thống nhất) ────────────────────

daemon_pid_file="$STATE_DIR/daemon.pid"

(
    echo $$ > "$daemon_pid_file"

    # Launch worker SSE event monitor (subprocess)
    bash "$SCRIPT_DIR/serve_controller.sh" bot &
    worker_bot_pid=$!
    echo "$worker_bot_pid" > "$STATE_DIR/worker_bot.pid"

    last_perm_enter=0   # timestamp lần cuối auto-Enter permission

    while true; do
        # ── 1. Check Manager còn sống không? ──
        if ! tmux has-session -t "$SESSION" 2>/dev/null; then
            echo "daemon: session_gone → cleanup"
            break
        fi
        if ! tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -q "^Manager$"; then
            echo "daemon: manager_window_gone → cleanup"
            break
        fi

        # ── 2. Manager permission auto-allow ──
        screen=$(tmux capture-pane -t "$SESSION:Manager" -p 2>/dev/null)

        # Trust folder dialog
        if echo "$screen" | grep -q "I trust this folder"; then
            tmux send-keys -t "$SESSION:Manager" Enter
            echo "daemon: manager_trust_folder"
            last_perm_enter=$(date +%s)
        fi

        # Permission dialog — chỉ auto-Enter nếu "Allow" được chọn (mặc định)
        # Kiểm tra: có "Permission required" hoặc "Always allow" nhưng KHÔNG có
        # "Reject" ở dòng được highlight (dòng có màu nền inverted)
        if echo "$screen" | grep -qE "Permission required|Always allow"; then
            # Chỉ auto-Enter nếu Reject không phải option được chọn
            # (trong opencode TUI, default luôn là Allow once)
            if ! echo "$screen" | grep -q "Reject.*once"; then
                local now=$(date +%s)
                # Cooldown 5s để tránh spam Enter liên tục
                if [ $((now - last_perm_enter)) -gt 5 ]; then
                    tmux send-keys -t "$SESSION:Manager" Enter
                    echo "daemon: manager_permission_allowed"
                    last_perm_enter=$now
                fi
            fi
        fi

        # ── 3. Kiểm tra worker bot còn sống ──
        if ! kill -0 "$worker_bot_pid" 2>/dev/null; then
            echo "daemon: worker_bot_died → restarting"
            bash "$SCRIPT_DIR/serve_controller.sh" bot &
            worker_bot_pid=$!
            echo "$worker_bot_pid" > "$STATE_DIR/worker_bot.pid"
        fi

        sleep 3
    done

    # Manager đã tắt → kill worker bot + tất cả workers + dọn
    echo "daemon: killing worker bot ($worker_bot_pid)..."
    kill "$worker_bot_pid" 2>/dev/null || true
    wait "$worker_bot_pid" 2>/dev/null || true

    echo "daemon: killing all workers..."
    bash "$SCRIPT_DIR/serve_controller.sh" killall 2>/dev/null || true

    echo "daemon: cleaning temp dirs..."
    rm -rf "$STATE_DIR"

    echo "daemon: done. Exiting."
) &
DAEMON_PID=$!

# ── Final output ────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         AGENT TEAMWORK — RUNNING                       ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Manager:    $mgr_tool TUI (tmux:$SESSION:Manager)"
echo "║  Model:      $mgr_model"
echo "║  Daemon PID: $DAEMON_PID"
echo "║"
echo "║  Bot actions:"
echo "║    Manager permission → auto-Enter (screen capture)"
echo "║    Worker events      → SSE monitor → status files"
echo "║    Worker permission  → báo Manager, Manager gọi allow"
echo "║    Manager exits      → kill workers + dọn .worker/"
echo "║    Ctrl+C             → kill all + dọn dẹp toàn bộ"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Workers: $SCRIPT_DIR/serve_controller.sh create <name>"
echo "  Status:  $SCRIPT_DIR/serve_controller.sh dashboard"
echo ""

# Giữ script sống — khi Manager tắt, daemon tự cleanup và exit
wait "$DAEMON_PID" 2>/dev/null

# Daemon đã exit (Manager tắt) → cleanup lần cuối
cleanup
