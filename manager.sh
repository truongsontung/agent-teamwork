#!/bin/bash
# Manager Agent - Control multiple workers

SESSION="${SESSION_NAME:-$(tmux display-message -p '#{session_name}' 2>/dev/null)}"
WK="worker.json"
MAX_WORKERS=$(jq -r '.max_workers // 5' "$WK" 2>/dev/null)
DEFAULT_MODEL=$(jq -r '.model // "opencode/deepseek-v4-flash-free"' "$WK" 2>/dev/null)
DEFAULT_TOOL=$(jq -r '.tool // "opencode"' "$WK" 2>/dev/null)

# Ghi config worker vào tool config dir TƯƠNG ỨNG, ngay trước khi launch.
# Tool chỉ đọc config 1 lần lúc khởi động nên ghi đè này không ảnh hưởng
# process Manager (nếu cùng tool) đang chạy.
write_worker_config() {
    local tool="$1"
    local dir=$([ "$tool" = "opencode" ] && echo .opencode || echo .mimocode)
    mkdir -p "$dir"
    local perm=$(jq -c '.permission' worker.json 2>/dev/null)
    perm="${perm//__PROJECT_DIR__/$PWD}"
    jq -n --argjson p "$perm" '{ "$schema": "https://opencode.ai/config.json", permission: $p }' > "$dir/opencode.json"
    # Sinh worker.md (agent definition) từ worker.json
    local desc=$(jq -r '.description' worker.json 2>/dev/null)
    local mode=$(jq -r '.mode' worker.json 2>/dev/null)
    local prompt=$(jq -r '.prompt' worker.json 2>/dev/null)
    mkdir -p "$dir/agents"
    printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$desc" "$mode" "$prompt" > "$dir/agents/worker.md"
}

# Check session
check_session() {
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "Error: Session '$SESSION' not found. Run ./setup.sh first"
        return 1
    fi
}

# Check if worker exists
worker_exists() {
    tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -q "^${1}$"
}

# Create worker
create() {
    local name="$1"
    local model="${2:-$DEFAULT_MODEL}"
    
    check_session || return 1
    
    if worker_exists "$name"; then
        echo "Error: Worker '$name' already exists"
        return 1
    fi
    
    local current=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -v "Manager" | wc -l | tr -d ' ')
    if [ "$current" -ge "$MAX_WORKERS" ]; then
        echo "Error: Max workers ($MAX_WORKERS) reached"
        return 1
    fi
    
    tmux new-window -t "$SESSION:" -n "$name"
    tmux set-window-option -t "$SESSION:$name" allow-rename off
    write_worker_config "$DEFAULT_TOOL"
    tmux send-keys -t "$SESSION:$name" "$DEFAULT_TOOL --model $model --agent worker" Enter
    echo "✓ $name created ($model, agent: worker)"
}

# Send command
send() {
    local worker="$1"
    shift
    
    check_session || return 1
    
    if ! worker_exists "$worker"; then
        echo "Error: Worker '$worker' not found"
        return 1
    fi
    
    tmux send-keys -t "$SESSION:$worker" "$*" Enter
}

# Send to all workers
send_all() {
    check_session || return 1
    
    local workers=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep "Worker")
    for w in $workers; do
        tmux send-keys -t "$SESSION:$w" "$*" Enter
    done
}

# Read worker screen
read_screen() {
    check_session || return 1
    
    if ! worker_exists "$1"; then
        echo "Error: Worker '$1' not found"
        return 1
    fi
    
    tmux capture-pane -t "$SESSION:$1" -p 2>/dev/null
}

# Dashboard
dashboard() {
    check_session || return 1
    
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         MANAGER DASHBOARD                              ║"
    echo "║         $(date '+%Y-%m-%d %H:%M:%S')                            ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    
    tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | while read -r name; do
        local pid=$(tmux list-panes -t "$SESSION:$name" -F '#{pane_pid}' 2>/dev/null | head -1)
        local uptime=""
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            uptime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs)
        fi
        echo "║  $name (uptime: ${uptime:-N/A})"
    done
    
    echo "╚══════════════════════════════════════════════════════════╝"
}

case "${1:-}" in
    create)
        shift
        create "$@"
        ;;
    send)
        shift
        send "$@"
        ;;
    send-all)
        shift
        send_all "$@"
        ;;
    read)
        shift
        read_screen "$@"
        ;;
    dashboard)
        dashboard
        ;;
    *)
        cat <<EOF
Manager Agent

USAGE:
  $0 create <name> [model]     Create worker
  $0 send <worker> <cmd>       Send command
  $0 send-all <cmd>            Send to all workers
  $0 read <worker>             Read screen
  $0 dashboard                 Show all agents

Config: $CONFIG
Max Workers: $MAX_WORKERS
Default Model: $DEFAULT_MODEL
EOF
        ;;
esac
