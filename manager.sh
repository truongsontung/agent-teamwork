#!/bin/bash
# Manager Agent - Control multiple workers

SESSION="${SESSION_NAME:-$(tmux display-message -p '#{session_name}' 2>/dev/null)}"
CONFIG="config.json"
MAX_WORKERS=$(jq -r '.max_workers // 5' "$CONFIG" 2>/dev/null)
DEFAULT_MODEL=$(jq -r '.workers.default_model // "opencode/deepseek-v4-flash-free"' "$CONFIG" 2>/dev/null)
DEFAULT_TOOL=$(jq -r '.workers.tool // "opencode"' "$CONFIG" 2>/dev/null)

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
    tmux send-keys -t "$SESSION:$name" "$DEFAULT_TOOL --model $model" Enter
    echo "✓ $name created ($model)"
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
