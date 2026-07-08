#!/bin/bash
# Tmux Controller - Core commands for Agent A to control Agent B

set -e

SESSION="agent-session"

# Send keystrokes
send() {
    local target="$1"
    local keys="$2"
    local enter="${3:-true}"
    
    if [ "$enter" = "true" ]; then
        tmux send-keys -t "$SESSION:$target" "$keys" Enter
    else
        tmux send-keys -t "$SESSION:$target" "$keys"
    fi
}

# Read screen
read_screen() {
    local target="$1"
    tmux capture-pane -t "$SESSION:$target" -p 2>/dev/null
}

# Wait for prompt
wait_prompt() {
    local target="$1"
    local timeout="${2:-60}"
    local start=$(date +%s)
    
    while true; do
        local screen=$(read_screen "$target")
        if echo "$screen" | grep -qE '[\$≥]\s*$'; then
            return 0
        fi
        
        local now=$(date +%s)
        if [ $((now - start)) -ge $timeout ]; then
            return 1
        fi
        
        sleep 0.5
    done
}

# Smart send - send and wait for completion
smart() {
    local target="$1"
    local cmd="$2"
    local timeout="${3:-60}"
    
    send "$target" "$cmd"
    wait_prompt "$target" "$timeout"
}

# Create worker
create_worker() {
    local name="$1"
    local model="${2:-opencode/deepseek-v4-flash-free}"
    
    tmux new-window -t "$SESSION" -n "$name"
    send "$name" "opencode --model $model"
    echo "✓ Worker $name created ($model)"
}

# Kill worker
kill_worker() {
    local name="$1"
    tmux kill-window -t "$SESSION:$name" 2>/dev/null
    echo "✓ Worker $name killed"
}

# Dashboard
dashboard() {
    echo "=== AGENTS ==="
    tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null
}

case "${1:-}" in
    send)
        shift
        send "$@"
        ;;
    read)
        shift
        read_screen "$@"
        ;;
    wait)
        shift
        wait_prompt "$@"
        ;;
    smart)
        shift
        smart "$@"
        ;;
    create)
        shift
        create_worker "$@"
        ;;
    kill)
        shift
        kill_worker "$@"
        ;;
    dashboard)
        dashboard
        ;;
    *)
        cat <<EOF
Tmux Controller

USAGE:
  $0 send <target> <keys>        Send keystrokes
  $0 read <target>               Read screen
  $0 wait <target> [timeout]     Wait for prompt
  $0 smart <target> <cmd>        Send + wait
  $0 create <name> [model]       Create worker
  $0 kill <name>                 Kill worker
  $0 dashboard                   List all agents

EXAMPLES:
  $0 send Worker-1 "ls -la"
  $0 read Worker-1
  $0 smart Worker-1 "npm install" 60
  $0 create Worker-2
  $0 dashboard
EOF
        ;;
esac
