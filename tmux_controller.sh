#!/bin/bash
# Tmux Controller - Core commands for Agent A to control Agent B

SESSION="${SESSION_NAME:-$(tmux display-message -p '#{session_name}' 2>/dev/null)}"

# Check session exists
check_session() {
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "Error: Session '$SESSION' not found. Run ./setup.sh first"
        return 1
    fi
}

# Send keystrokes - handles multi-word commands
send() {
    local target="$1"
    shift
    local keys="$*"
    
    check_session || return 1
    if ! worker_exists "$target"; then
        echo "Error: Target '$target' not found"
        return 1
    fi
    tmux send-keys -t "$SESSION:$target" "$keys" Enter
}

# Read screen
read_screen() {
    local target="$1"
    check_session || return 1
    if ! worker_exists "$target"; then
        echo "Error: Target '$target' not found"
        return 1
    fi
    tmux capture-pane -t "$SESSION:$target" -p 2>/dev/null
}

# Wait for command completion (shell + opencode TUI)
wait_prompt() {
    local target="$1"
    local timeout="${2:-60}"
    
    check_session || return 1
    if ! worker_exists "$target"; then
        echo "Error: Target '$target' not found"
        return 1
    fi
    
    local start=$(date +%s)
    local last_screen=""
    local stable_count=0
    
    while true; do
        local screen=$(read_screen "$target")
        
        # Auto-handle permission prompts
        if echo "$screen" | grep -q "Permission required"; then
            tmux send-keys -t "$SESSION:$target" Enter
            sleep 1; continue
        fi
        
        # Auto-confirm "Always allow"
        if echo "$screen" | grep -q "Always allow"; then
            tmux send-keys -t "$SESSION:$target" Enter
            sleep 0.5; continue
        fi
        
        # Opencode dialog detection — Manager agent tự xử lý
        if echo "$screen" | grep -qE '△\s*(Ask|Confirm|Question)'; then
            sleep 0.5; continue
        fi
        
        # Check for opencode idle state (ctrl+p hint = idle)
        if echo "$screen" | grep -qi "ctrl+p commands"; then
            return 0
        fi
        
        # Check for shell prompt
        if echo "$screen" | grep -qE '[\$≥]\s*$'; then
            return 0
        fi
        
        # Stability detection (fallback)
        if [ "$screen" = "$last_screen" ]; then
            stable_count=$((stable_count + 1))
            if [ "$stable_count" -ge 4 ]; then
                return 0
            fi
        else
            stable_count=0
            last_screen="$screen"
        fi
        
        local now=$(date +%s)
        if [ $((now - start)) -ge $timeout ]; then
            echo "! Timeout waiting for '$target'"
            return 1
        fi
        
        sleep 0.5
    done
}

# Smart send - send and wait for completion
smart() {
    local target="$1"
    shift
    local cmd="$*"
    
    send "$target" "$cmd"
    wait_prompt "$target" 60
}

# Check if worker exists
worker_exists() {
    local name="$1"
    tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -q "^${name}$"
}

# Create worker with validation
create_worker() {
    local name="$1"
    local model="${2:-$(jq -r '.workers.default_model' config.json 2>/dev/null || echo 'opencode/deepseek-v4-flash-free')}"
    
    check_session || return 1
    
    # Check if name already exists
    if worker_exists "$name"; then
        echo "Error: Worker '$name' already exists"
        return 1
    fi
    
    # Check max workers (count all windows except Manager)
    local max=$(jq -r '.max_workers' config.json 2>/dev/null || echo 5)
    local current=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -v "Manager" | wc -l | tr -d ' ')
    if [ "$current" -ge "$max" ]; then
        echo "Error: Max workers ($max) reached"
        return 1
    fi
    
    tmux new-window -t "$SESSION" -n "$name"
    send "$name" "opencode --model $model"
    echo "✓ Worker $name created ($model)"
}

# Kill worker with validation
kill_worker() {
    local name="$1"
    
    check_session || return 1
    
    if ! worker_exists "$name"; then
        echo "Error: Worker '$name' not found"
        return 1
    fi
    
    tmux kill-window -t "$SESSION:$name" 2>/dev/null
    echo "✓ Worker $name killed"
}

# Dashboard with full info
dashboard() {
    check_session || return 1
    
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         AGENT TEAMWORK DASHBOARD                       ║"
    echo "║         $(date '+%Y-%m-%d %H:%M:%S')                            ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    
    tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | while read -r name; do
        # Get pane PID for uptime
        local pid=$(tmux list-panes -t "$SESSION:$name" -F '#{pane_pid}' 2>/dev/null | head -1)
        local uptime=""
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            uptime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs)
        fi
        
        # Get last command from screen
        local last_cmd=$(tmux capture-pane -t "$SESSION:$name" -p 2>/dev/null | grep -E '[\$≥]' | tail -1 | sed 's/.*[\$≥] //' | tr -d '\n' | head -c 50)
        
        echo "║  $name"
        echo "║    Uptime: ${uptime:-N/A}"
        echo "║    Last: ${last_cmd:-N/A}"
        echo "║"
    done
    
    echo "╚══════════════════════════════════════════════════════════╝"
}

# Interactive mode
interactive() {
    check_session || return 1
    
    echo "=== TMUX CONTROLLER - Interactive Mode ==="
    echo "Commands: send, read, wait, smart, create, kill, dashboard, quit"
    
    while true; do
        read -p "Controller> " cmd args
        
        case "$cmd" in
            send)
                send $args
                ;;
            read)
                read_screen $args
                ;;
            wait)
                wait_prompt $args
                ;;
            smart)
                smart $args
                ;;
            create)
                create_worker $args
                ;;
            kill)
                kill_worker $args
                ;;
            dashboard)
                dashboard
                ;;
            quit|exit)
                break
                ;;
            *)
                echo "Unknown: $cmd"
                ;;
        esac
    done
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
    interactive)
        interactive
        ;;
    *)
        cat <<EOF
Tmux Controller

USAGE:
  $0 send <target> <command>     Send command (multi-word)
  $0 read <target>               Read screen
  $0 wait <target> [timeout]     Wait for completion (0=done, 1=timeout)
  $0 smart <target> <command>    Send + wait (auto-handles permission/allow dialogs)
  $0 create <name> [model]       Create worker
  $0 kill <name>                 Kill worker
  $0 dashboard                   Show all agents
  $0 interactive                 Interactive mode

EXIT CODES (wait/smart):
  0 = Worker finished (idle)
  1 = Timeout — Manager tự read panel và xử lý

AUTO-HANDLED EVENTS:
  - Permission required → auto-allow once
  - Always allow → auto-confirm

EXAMPLES:
  $0 send Worker-1 npm install
  $0 smart Worker-1 npm run build 120
  $0 dashboard
EOF
        ;;
esac
