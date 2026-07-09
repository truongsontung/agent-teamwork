#!/bin/bash
# Agent Teamwork — setup Manager + Daemon
# Manager sees only: ./agent command + project files
# No knowledge of agent-teamwork internals
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

# ── Create wrapper: ./agent in project dir ───────────────

cat > "$PROJECT_DIR/agent" <<WRAPPER
#!/bin/bash
export PROJECT_DIR="$PROJECT_DIR"
exec bash "$SCRIPT_DIR/serve_controller.sh" "\$@"
WRAPPER
chmod +x "$PROJECT_DIR/agent"

# Manager also allowed to run serve_controller.sh via PATH
mgr_perm=$(echo "$mgr_perm" | jq --arg d "$SCRIPT_DIR" '.external_directory[$d + "/*"] = "allow"')

dir_for() { [ "$1" = "opencode" ] && echo .opencode || echo .mimocode; }
mgr_dir=$(dir_for "$mgr_tool")

# ── Write Manager config ─────────────────────────────────

mkdir -p "$PROJECT_DIR/$mgr_dir"
jq -n --argjson p "$mgr_perm" '{"$schema":"https://opencode.ai/config.json",permission:$p}' \
    > "$PROJECT_DIR/$mgr_dir/opencode.json"

mkdir -p "$PROJECT_DIR/$mgr_dir/agents"
printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$mgr_desc" "$mgr_mode" "$mgr_prompt" \
    > "$PROJECT_DIR/$mgr_dir/agents/manager.md"

wk_desc=$(jq -r '.description' "$WK"); wk_mode=$(jq -r '.mode' "$WK"); wk_prompt=$(jq -r '.prompt' "$WK")
printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$wk_desc" "$wk_mode" "$wk_prompt" \
    > "$PROJECT_DIR/$mgr_dir/agents/worker.md"

# ── Clean old state ──────────────────────────────────────

rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"

# ── Cleanup ──────────────────────────────────────────────

cleanup() {
    bash "$SCRIPT_DIR/serve_controller.sh" killall 2>/dev/null || true
    pkill -P $$ 2>/dev/null || true
    rm -rf "$STATE_DIR" "$PROJECT_DIR/agent"
    rm -f "$PROJECT_DIR/$mgr_dir/agents/manager.md" "$PROJECT_DIR/$mgr_dir/agents/worker.md"
    exit 0
}
trap cleanup INT TERM

# ── Launch Manager TUI ───────────────────────────────────

SESSION="${SESSION_NAME:-agent-teamwork}"
tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" -n "Manager"
tmux kill-window -t "$SESSION:Manager" 2>/dev/null || true
tmux new-window -t "$SESSION:" -n "Manager"
# Manager: no AGENT_TEAMWORK_HOME, no knowledge of agent-teamwork path
# Only sees PROJECT_DIR and ./agent
tmux send-keys -t "$SESSION:Manager" \
    "cd '$PROJECT_DIR' && export PROJECT_DIR='$PROJECT_DIR' && $mgr_tool --model $mgr_model --agent manager" Enter

sleep 5
tmux capture-pane -t "$SESSION:Manager" -p 2>/dev/null | grep -q "I trust this folder" && \
    tmux send-keys -t "$SESSION:Manager" Enter

# ── Daemon (manager permission + worker bot) ─────────────

(
    bash "$SCRIPT_DIR/serve_controller.sh" bot &
    wbot_pid=$!

    last_enter=0
    while true; do
        tmux has-session -t "$SESSION" 2>/dev/null || break
        tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -q "^Manager$" || break

        screen=$(tmux capture-pane -t "$SESSION:Manager" -p 2>/dev/null)
        if echo "$screen" | grep -qE "Permission required|Always allow"; then
            now=$(date +%s)
            [ $((now - last_enter)) -gt 5 ] && { tmux send-keys -t "$SESSION:Manager" Enter; last_enter=$now; }
        fi
        if echo "$screen" | grep -q "I trust this folder"; then
            tmux send-keys -t "$SESSION:Manager" Enter; last_enter=$(date +%s)
        fi

        kill -0 "$wbot_pid" 2>/dev/null || { bash "$SCRIPT_DIR/serve_controller.sh" bot & wbot_pid=$!; }
        sleep 3
    done

    kill "$wbot_pid" 2>/dev/null; wait "$wbot_pid" 2>/dev/null
    bash "$SCRIPT_DIR/serve_controller.sh" killall 2>/dev/null
    rm -rf "$STATE_DIR" "$PROJECT_DIR/agent"
) &
DAEMON_PID=$!

echo "ready" "manager=$mgr_tool" "session=$SESSION" "project=$PROJECT_DIR"

wait "$DAEMON_PID" 2>/dev/null
cleanup
