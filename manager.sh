#!/bin/bash
# Manager Agent - Control multiple workers

set -e

SESSION="agent-session"
CONFIG="config.json"
MAX_WORKERS=$(jq -r '.max_workers' "$CONFIG" 2>/dev/null || echo 5)

# Create worker
create() {
    local name="$1"
    local model="${2:-$(jq -r '.workers.default_model' "$CONFIG")}"
    
    # Check max workers
    local current=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -c "Worker" || echo 0)
    if [ "$current" -ge "$MAX_WORKERS" ]; then
        echo "Max workers ($MAX_WORKERS) reached!"
        return 1
    fi
    
    tmux new-window -t "$SESSION" -n "$name"
    tmux send-keys -t "$SESSION:$name" "opencode --model $model" Enter
    echo "✓ $name created ($model)"
}

# Send command
send() {
    local worker="$1"
    shift
    tmux send-keys -t "$SESSION:$worker" "$*" Enter
}

# Send to all workers
send_all() {
    local workers=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep "Worker")
    for w in $workers; do
        tmux send-keys -t "$SESSION:$w" "$*" Enter
    done
}

# Read worker screen
read_screen() {
    tmux capture-pane -t "$SESSION:$1" -p 2>/dev/null
}

# Dashboard
dashboard() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         MANAGER DASHBOARD                              ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    tmux list-windows -t "$SESSION" -F '║  #{window_name}' 2>/dev/null
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

MAX WORKERS: $MAX_WORKERS
EOF
        ;;
esac
