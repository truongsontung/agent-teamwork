#!/bin/bash
# Tmux Controller - Core commands for Agent A to control Agent B

SESSION="${SESSION_NAME:-$(tmux display-message -p '#{session_name}' 2>/dev/null)}"

# Ghi config của worker vào tool config dir TƯƠNG ỨNG, ngay trước khi launch.
# Tool chỉ đọc config 1 lần lúc khởi động nên ghi đè này không ảnh hưởng
# process Manager (nếu cùng tool) đang chạy.
write_worker_config() {
    local tool="$1"
    local dir=$([ "$tool" = "opencode" ] && echo .opencode || echo .mimocode)
    local wk="${AGENT_TEAMWORK_HOME:-.}/worker.json"
    mkdir -p "$dir"
    local perm=$(jq -c '.permission' "$wk" 2>/dev/null)
    perm="${perm//__PROJECT_DIR__/$PWD}"
    jq -n --argjson p "$perm" '{ "$schema": "https://opencode.ai/config.json", permission: $p }' > "$dir/opencode.json"
    # Sinh worker.md (agent definition) từ worker.json
    local desc=$(jq -r '.description' "$wk" 2>/dev/null)
    local mode=$(jq -r '.mode' "$wk" 2>/dev/null)
    local prompt=$(jq -r '.prompt' "$wk" 2>/dev/null)
    if [ "$desc" != "null" ] && [ -n "$desc" ]; then
        mkdir -p "$dir/agents"
        printf -- '---\ndescription: %s\nmode: %s\n---\n\n%s\n' "$desc" "$mode" "$prompt" > "$dir/agents/worker.md"
    fi
}

# Check session exists
check_session() {
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "Error: Session '$SESSION' not found. Run ./setup.sh first"
        return 1
    fi
}

# Send command to worker TUI. Chờ worker ready (composer focus)
# trước khi gửi để tránh mất lệnh do TUI chưa sẵn sàng.
send() {
    local target="$1"
    shift
    local cmd="$*"
    
    check_session || return 1
    if ! worker_exists "$target"; then
        echo "Error: Target '$target' not found"
        return 1
    fi
    
    # Chờ TUI worker hiện prompt "Ask anything" / "ctrl+p commands" (composer đã focus)
    local attempts=0
    while [ $attempts -lt 15 ]; do
        local screen=$(read_screen "$target" 2>/dev/null)
        if echo "$screen" | grep -qiE "Ask anything|ctrl\+p commands|Type your message"; then
            break
        fi
        sleep 1
        attempts=$((attempts + 1))
    done
    
    tmux send-keys -t "$SESSION:$target" "$cmd" Enter
}

# Gửi phím Enter trực tiếp (dùng khi worker gặp permission prompt)
# Không readiness check — prompt không có "Ask anything".
allow() {
    local target="$1"
    check_session || return 1
    if ! worker_exists "$target"; then
        echo "Error: Target '$target' not found"
        return 1
    fi
    tmux send-keys -t "$SESSION:$target" Enter
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

# Đọc output worker đã lọc sạch TUI — chỉ giữ nội dung thật (tool call, bash, kết quả)
read_summary() {
    local target="$1"
    local screen=$(read_screen "$target" 2>/dev/null)
    echo "$screen" \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | LC_ALL=C grep -vE '^[[:space:]]*$|█|▀|▄|╹|┃|║|ctrl\+p|tab agents|settings|switch mode|interrupt|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|🛸|✦|●|◀|▲|▼|subage|comma' \
        | tail -20
}

# Wait for command completion (shell + opencode TUI)
# Dùng pipe-pane để phát hiện activity qua file thay vì sleep+capture-pane liên tục.
# Chỉ gọi capture-pane khi có output mới (file size thay đổi).
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
    local outfile="/tmp/tmux-wp-$$-${target}"
    local last_size=0
    local interval=2
    
    # Pipe worker output -> file để phát hiện activity không cần capture-pane
    tmux pipe-pane -t "$SESSION:$target" "cat >> $outfile" 2>/dev/null
    cleanup_pipe() { tmux pipe-pane -t "$SESSION:$target" 2>/dev/null; rm -f "$outfile"; }
    
    # Helper: kiểm tra màn hình xem worker xong chưa
    check_screen() {
        local screen="$1"
        # Permission / Ask prompt -> trả 2 để Manager xử lý
        if echo "$screen" | grep -qE "Permission required|Always allow|△\s*(Ask|Confirm|Question)|I trust this folder|safety check"; then
            cleanup_pipe; return 2
        fi
        # opencode idle (ctrl+p hint)
        if echo "$screen" | grep -qi "ctrl+p commands"; then cleanup_pipe; return 0; fi
        # Shell prompt
        if echo "$screen" | grep -qE '[\$≥]\s*$'; then cleanup_pipe; return 0; fi
        # Stability fallback
        if [ "$screen" = "$last_screen" ]; then
            stable_count=$((stable_count + 1))
            if [ "$stable_count" -ge 3 ]; then cleanup_pipe; return 0; fi
        else
            stable_count=0
            last_screen="$screen"
        fi
        return 3  # continue waiting
    }
    
    # First check ngay lập tức (có thể worker đã xong)
    local screen=$(read_screen "$target")
    last_screen="$screen"
    check_screen "$screen"
    local rc=$?; [ "$rc" -ne 3 ] && return $rc
    
    while true; do
        sleep $interval
        
        local new_size=$(stat -c %s "$outfile" 2>/dev/null || echo 0)
        
        if [ "$new_size" -ne "$last_size" ]; then
            # Activity detected -> capture-pane để phân tích
            last_size="$new_size"
            local screen=$(read_screen "$target")
            check_screen "$screen"
            local rc=$?; [ "$rc" -ne 3 ] && return $rc
        fi
        
        # Timeout
        local now=$(date +%s)
        if [ $((now - start)) -ge $timeout ]; then
            cleanup_pipe
            echo "! Timeout waiting for '$target'"
            return 1
        fi
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
    local wk="${AGENT_TEAMWORK_HOME:-.}/worker.json"
    local model="${2:-$(jq -r '.model' "$wk" 2>/dev/null || echo 'opencode/deepseek-v4-flash-free')}"
    local tool=$(jq -r '.tool // "opencode"' "$wk" 2>/dev/null)
    
    check_session || return 1
    
    # Check if name already exists
    if worker_exists "$name"; then
        echo "Error: Worker '$name' already exists"
        return 1
    fi
    
    # Check max workers (count all windows except Manager)
    local max=$(jq -r '.max_workers' "$wk" 2>/dev/null || echo 5)
    local current=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -v "Manager" | wc -l | tr -d ' ')
    if [ "$current" -ge "$max" ]; then
        echo "Error: Max workers ($max) reached"
        return 1
    fi
    
    tmux new-window -t "$SESSION:" -n "$name"
    tmux set-window-option -t "$SESSION:$name" allow-rename off
    write_worker_config "$tool"
    mkdir -p ./.worker
    tmux send-keys -t "$SESSION:$name" "$tool --model $model --agent worker --print-logs 2>./.worker/$name.log" Enter
    echo "✓ Worker $name created ($model, agent: worker, log: ./.worker/$name.log)"
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
    rm -f "./.worker/${name}.log" "./.worker/${name}.status"
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
    summary)
        shift
        read_summary "$@"
        ;;
    wait)
        shift
        wait_prompt "$@"
        ;;
    smart)
        shift
        smart "$@"
        ;;
    allow)
        shift
        allow "$@"
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
