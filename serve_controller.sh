#!/bin/bash
# Serve Controller - Quản lý opencode serve workers thay vì tmux TUI
# API: REST HTTP + SSE event monitor giữa Manager và Worker
# Bot: bắt sự kiện SSE từ worker → báo Manager biết permission/idle/error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$SCRIPT_DIR/.worker"
WK="$SCRIPT_DIR/worker.json"
PORT_BASE=$(jq -r '.port_base // 4091' "$WK" 2>/dev/null)
DEFAULT_TIMEOUT=$(jq -r '.timeout // 300' "$WK" 2>/dev/null)
DEFAULT_MODEL=$(jq -r '.model // "opencode/deepseek-v4-flash-free"' "$WK" 2>/dev/null)
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

# ── Helpers ──────────────────────────────────────────────

die() { echo "Error: $*" >&2; exit 1; }

next_port() {
    local port=$PORT_BASE
    while :; do
        if ! ss -tln 2>/dev/null | grep -q ":$port " && \
           ! lsof -i ":$port" >/dev/null 2>&1; then
            echo $port; return
        fi
        port=$((port + 1))
    done
}

worker_info()  { cat "$STATE_DIR/$1.json" 2>/dev/null; }
worker_exists() { [ -f "$STATE_DIR/$1.json" ]; }
worker_pid()   { worker_info "$1" | jq -r .pid; }
worker_port()  { worker_info "$1" | jq -r .port; }
worker_model() { worker_info "$1" | jq -r .model; }

alive() {
    local pid
    pid=$(worker_pid "$1" 2>/dev/null) || return 1
    kill -0 "$pid" 2>/dev/null
}

check_worker() {
    worker_exists "$1" || die "Worker '$1' not found"
    alive "$1" || die "Worker '$1' process dead (pid $(worker_pid "$1" 2>/dev/null || echo N/A))"
}

wait_serve_ready() {
    local port=$1 name=$2 max=30 i=0
    while [ $i -lt $max ]; do
        if curl -s --max-time 2 "http://127.0.0.1:$port/session/status" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1; i=$((i + 1))
    done
    die "Worker '$name' serve not ready on port $port after ${max}s"
}

parse_model() {
    local m="$1"
    if [[ "$m" == */* ]]; then
        echo "${m%%/*}|${m#*/}"
    else
        echo "opencode|$m"
    fi
}

write_worker_config() {
    local name="$1"
    local conf="$STATE_DIR/configs/${name}.json"
    mkdir -p "$STATE_DIR/configs"

    local perm
    perm=$(jq -c '.permission' "$WK" 2>/dev/null)
    perm="${perm//__PROJECT_DIR__/$PROJECT_DIR}"
    perm=$(echo "$perm" | jq --arg d "$STATE_DIR" '.external_directory[$d + "/*"] = "allow"')

    jq -n --argjson p "$perm" \
        '{"$schema":"https://opencode.ai/config.json", permission:$p}' \
        > "$conf"
    echo "$conf"
}

# ── SSE Event Monitor (chạy nền, 1 tiến trình/worker) ──

monitor_worker() {
    local name="$1" port="$2"
    local status_file="$STATE_DIR/${name}.status"
    local perm_file="$STATE_DIR/${name}.permission"
    local prev=""

    # Dùng curl stream (--no-buffer) đọc SSE events từ serve
    curl -s -N --no-buffer --max-time 0 \
        "http://127.0.0.1:$port/event" 2>/dev/null | while IFS= read -r line; do

        # ── Format A: SSE chuẩn (event: / data:) ──
        if [[ "$line" == event:* ]]; then
            local event_type="${line#event: }"
            read -r data_line
            local data=""
            if [[ "$data_line" == data:* ]]; then
                data="${data_line#data: }"
            fi
            process_event "$name" "$event_type" "$data" "$status_file" "$perm_file"
            continue
        fi

        # ── Format B: nd-JSON (mỗi dòng 1 event) ──
        if echo "$line" | jq -e '.type' >/dev/null 2>&1; then
            local event_type data
            event_type=$(echo "$line" | jq -r '.type')
            data="$line"
            process_event "$name" "$event_type" "$data" "$status_file" "$perm_file"
        fi
    done
}

process_event() {
    local name="$1" event_type="$2" data="$3" status_file="$4" perm_file="$5"

    case "$event_type" in
        "session.idle")
            echo "idle" > "$status_file"
            echo "done" > "$STATE_DIR/${name}.status.prev"  # reset chờ
            echo "bot:event worker=$name status=idle"
            ;;

        "session.error")
            echo "error" > "$status_file"
            echo "$data" > "$STATE_DIR/${name}.error"
            echo "bot:event worker=$name status=error data=$data"
            ;;

        "permission.asked")
            echo "permission" > "$status_file"
            echo "$data" > "$perm_file"
            # Trích permissionID để Manager gọi allow/deny
            local perm_id
            perm_id=$(echo "$data" | jq -r '.permissionID // .id // "unknown"' 2>/dev/null)
            echo "$perm_id" > "$STATE_DIR/${name}.permission_id"
            echo "bot:event worker=$name status=permission permID=$perm_id tool=$(echo "$data" | jq -r '.tool // "?"' 2>/dev/null)"
            ;;

        "permission.replied")
            echo "running" > "$status_file"
            rm -f "$perm_file" "$STATE_DIR/${name}.permission_id"
            echo "bot:event worker=$name status=running (permission resolved)"
            ;;

        "session.status")
            local s
            s=$(echo "$data" | jq -r '.status // .sessionStatus // "running"' 2>/dev/null)
            [ -n "$s" ] && [ "$s" != "null" ] && echo "$s" > "$status_file"
            ;;

        "session.created")
            echo "running" > "$status_file"
            echo "bot:event worker=$name status=running (session created)"
            ;;

        "tool.execute.before")
            # Cập nhật last activity time để detect stuck
            date +%s > "$STATE_DIR/${name}.last_activity"
            ;;

        "tool.execute.after")
            date +%s > "$STATE_DIR/${name}.last_activity"
            ;;
    esac
}

# ── Permission handling ──────────────────────────────────

cmd_allow() {
    local name="$1"
    check_worker "$name"

    local port perm_id
    port=$(worker_port "$name")
    perm_id=$(cat "$STATE_DIR/${name}.permission_id" 2>/dev/null || echo "")

    if [ -z "$perm_id" ] || [ "$perm_id" = "unknown" ]; then
        die "No pending permission for '$name'"
    fi

    local resp
    resp=$(curl -s --max-time 10 \
        -X POST "http://127.0.0.1:$port/session/$name/permissions/$perm_id" \
        -H "Content-Type: application/json" \
        -d '{"action":"allow"}' 2>&1)

    rm -f "$STATE_DIR/${name}.permission" "$STATE_DIR/${name}.permission_id"
    echo "running" > "$STATE_DIR/${name}.status"
    echo "✓ Permission $perm_id allowed on $name"
}

cmd_deny() {
    local name="$1"
    check_worker "$name"

    local port perm_id
    port=$(worker_port "$name")
    perm_id=$(cat "$STATE_DIR/${name}.permission_id" 2>/dev/null || echo "")

    if [ -z "$perm_id" ] || [ "$perm_id" = "unknown" ]; then
        die "No pending permission for '$name'"
    fi

    local resp
    resp=$(curl -s --max-time 10 \
        -X POST "http://127.0.0.1:$port/session/$name/permissions/$perm_id" \
        -H "Content-Type: application/json" \
        -d '{"action":"deny"}' 2>&1)

    rm -f "$STATE_DIR/${name}.permission" "$STATE_DIR/${name}.permission_id"
    echo "running" > "$STATE_DIR/${name}.status"
    echo "✗ Permission $perm_id denied on $name"
}

cmd_permission_info() {
    local name="$1"
    [ -f "$STATE_DIR/${name}.permission" ] || die "No pending permission for '$name'"

    echo "Permission pending on $name:"
    echo "──────────────────────────────────────"
    jq '.' "$STATE_DIR/${name}.permission" 2>/dev/null || cat "$STATE_DIR/${name}.permission"
    echo ""
    local perm_id
    perm_id=$(cat "$STATE_DIR/${name}.permission_id" 2>/dev/null || echo "?")
    echo "permissionID: $perm_id"
    echo ""
    echo "Manager: ./serve_controller.sh allow $name   (chấp nhận)"
    echo "Manager: ./serve_controller.sh deny $name     (từ chối)"
}

# ── Core Commands ────────────────────────────────────────

cmd_create() {
    local name="$1"
    local model="${2:-$DEFAULT_MODEL}"

    worker_exists "$name" && die "Worker '$name' already exists"

    local max
    max=$(jq -r '.max_workers // 5' "$WK")
    local current
    current=$(ls "$STATE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$current" -ge "$max" ] && die "Max workers ($max) reached"

    local port
    port=$(next_port)

    local config_file
    config_file=$(write_worker_config "$name")

    local logfile="$STATE_DIR/${name}.log"
    OPENCODE_CONFIG="$config_file" \
        nohup opencode serve --port "$port" --hostname 127.0.0.1 \
        > "$logfile" 2>&1 &
    local pid=$!

    mkdir -p "$STATE_DIR"
    jq -n \
        --arg name "$name" \
        --arg port "$port" \
        --arg pid "$pid" \
        --arg model "$model" \
        --arg config "$config_file" \
        '{name:$name,port:($port|tonumber),pid:($pid|tonumber),model:$model,config:$config,status:"starting"}' \
        > "$STATE_DIR/$name.json"

    wait_serve_ready "$port" "$name"

    # Khởi động SSE monitor cho worker này
    monitor_worker "$name" "$port" &
    local mon_pid=$!
    echo "$mon_pid" > "$STATE_DIR/${name}.sse_pid"

    echo "running" > "$STATE_DIR/${name}.status"
    date +%s > "$STATE_DIR/${name}.last_activity"

    echo "✓ $name created (port:$port pid:$pid mon_pid:$mon_pid model:$model)"
}

cmd_send() {
    local name="$1"; shift
    local prompt="$*"

    check_worker "$name"
    local port model_str provider model_id timeout
    port=$(worker_port "$name")
    model_str=$(worker_model "$name")
    IFS='|' read -r provider model_id <<< "$(parse_model "$model_str")"
    timeout=$(jq -r ".timeout // $DEFAULT_TIMEOUT" "$STATE_DIR/$name.json")

    # Reset permission state
    rm -f "$STATE_DIR/${name}.permission" "$STATE_DIR/${name}.permission_id"

    local payload
    payload=$(jq -n \
        --arg text "$prompt" \
        --arg provider "$provider" \
        --arg model_id "$model_id" \
        '{
            parts: [{type:"text",text:$text}],
            model: {providerID:$provider, modelID:$model_id}
        }')

    echo "$payload" > "$STATE_DIR/${name}.last_request"

    local result http_code
    result=$(curl -s -w '\n%{http_code}' --max-time "$timeout" \
        -X POST "http://127.0.0.1:$port/session/$name/message" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)

    http_code=$(echo "$result" | tail -1)
    local body
    body=$(echo "$result" | sed '$d')

    echo "$body" > "$STATE_DIR/${name}.last_result"

    if [ "$http_code" != "200" ]; then
        echo "[HTTP $http_code] $body" >&2
        return 1
    fi

    echo "$body" | jq -r '
        [.parts[]? | select(.type == "text") | .text // empty] | join("\n")
    ' 2>/dev/null || echo "$body"
}

cmd_send_async() {
    local name="$1"; shift
    local prompt="$*"

    check_worker "$name"
    local port model_str provider model_id
    port=$(worker_port "$name")
    model_str=$(worker_model "$name")
    IFS='|' read -r provider model_id <<< "$(parse_model "$model_str")"

    rm -f "$STATE_DIR/${name}.permission" "$STATE_DIR/${name}.permission_id"

    local payload
    payload=$(jq -n \
        --arg text "$prompt" \
        --arg provider "$provider" \
        --arg model_id "$model_id" \
        '{
            parts: [{type:"text",text:$text}],
            model: {providerID:$provider, modelID:$model_id}
        }')

    echo "$payload" > "$STATE_DIR/${name}.last_request"

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "http://127.0.0.1:$port/session/$name/prompt_async" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        echo "✓ Sent to $name (async)"
    else
        echo "! Send failed (HTTP $http_code)"
        return 1
    fi
}

cmd_status() {
    local name="$1"

    # Ưu tiên: file bot ghi (SSE real-time) > poll API
    if [ -f "$STATE_DIR/${name}.status" ]; then
        local bot_status
        bot_status=$(cat "$STATE_DIR/${name}.status")
        echo "$bot_status"
        return
    fi

    if ! alive "$name" 2>/dev/null; then
        echo "dead"; return
    fi

    local port
    port=$(worker_port "$name" 2>/dev/null)
    [ -z "$port" ] && { echo "unknown"; return; }

    curl -s --max-time 5 "http://127.0.0.1:$port/session/status" \
        | jq -r ".[\"$name\"] // \"running\"" 2>/dev/null \
        || echo "unknown"
}

cmd_status_all() {
    for f in "$STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        local name st extra
        name=$(jq -r .name "$f")

        st=$(cmd_status "$name" 2>/dev/null || echo "dead")

        extra=""
        [ "$st" = "permission" ] && extra=" → ./serve_controller.sh allow $name"
        echo "$name: $st$extra"
    done
}

cmd_result() {
    local name="$1"
    [ -f "$STATE_DIR/${name}.last_result" ] || die "No result for '$name'"

    jq -r '[.parts[]? | select(.type == "text") | .text // empty] | join("\n")' \
        "$STATE_DIR/${name}.last_result" 2>/dev/null \
        || cat "$STATE_DIR/${name}.last_result"
}

cmd_result_full() {
    local name="$1"
    local port
    port=$(worker_port "$name" 2>/dev/null)

    if [ -n "${port:-}" ] && alive "$name" 2>/dev/null; then
        curl -s --max-time 10 "http://127.0.0.1:$port/session/$name/message" 2>/dev/null
    elif [ -f "$STATE_DIR/${name}.last_result" ]; then
        cat "$STATE_DIR/${name}.last_result"
    else
        die "No result for '$name'"
    fi
}

cmd_kill() {
    local name="$1"
    worker_exists "$name" || die "Worker '$name' not found"

    local port pid
    port=$(worker_port "$name" 2>/dev/null || echo "")
    pid=$(worker_pid "$name" 2>/dev/null || echo "")

    # Kill SSE monitor trước
    if [ -f "$STATE_DIR/${name}.sse_pid" ]; then
        kill "$(cat "$STATE_DIR/${name}.sse_pid")" 2>/dev/null || true
    fi

    # Abort session
    if [ -n "$port" ] && curl -s --max-time 3 "http://127.0.0.1:$port/session/status" >/dev/null 2>&1; then
        curl -s -X POST "http://127.0.0.1:$port/session/$name/abort" >/dev/null 2>&1 || true
    fi

    # Kill process
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    sleep 1
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true

    # Cleanup
    rm -f "$STATE_DIR/$name.json" \
          "$STATE_DIR/${name}.log" \
          "$STATE_DIR/${name}.last_request" \
          "$STATE_DIR/${name}.last_result" \
          "$STATE_DIR/${name}.status" \
          "$STATE_DIR/${name}.status.prev" \
          "$STATE_DIR/${name}.permission" \
          "$STATE_DIR/${name}.permission_id" \
          "$STATE_DIR/${name}.sse_pid" \
          "$STATE_DIR/${name}.error" \
          "$STATE_DIR/${name}.last_activity" \
          "$STATE_DIR/configs/${name}.json"

    echo "✓ $name killed"
}

cmd_killall() {
    local count=0
    for f in "$STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        local name
        name=$(jq -r .name "$f")
        cmd_kill "$name"
        count=$((count + 1))
    done
    rm -rf "$STATE_DIR/configs"
    echo "✓ $count workers killed"
}

cmd_dashboard() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         SERVE CONTROLLER DASHBOARD                     ║"
    echo "║         $(date '+%Y-%m-%d %H:%M:%S')                            ║"
    echo "╠══════════════════════════════════════════════════════════╣"

    local has=false
    for f in "$STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        has=true
        local name port pid model status uptime
        name=$(jq -r .name "$f")
        port=$(jq -r .port "$f")
        pid=$(jq -r .pid "$f")
        model=$(jq -r .model "$f")

        # Status từ bot (real-time SSE) hoặc poll API
        if [ -f "$STATE_DIR/${name}.status" ]; then
            status=$(cat "$STATE_DIR/${name}.status")
        elif alive "$name" 2>/dev/null; then
            status=$(curl -s --max-time 3 "http://127.0.0.1:$port/session/status" 2>/dev/null \
                | jq -r ".[\"$name\"] // \"running\"" 2>/dev/null)
        else
            status="dead"
        fi

        if [ -d "/proc/$pid" ]; then
            uptime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs)
        else
            uptime="N/A"
        fi

        # Highlight permission
        local flag=""
        [ "$status" = "permission" ] && flag=" ⚠ PERMISSION PENDING"

        echo "║  $name$flag"
        echo "║    port:$port  pid:$pid  status:${status:-unknown}"
        echo "║    model:$model  uptime:${uptime:-N/A}"

        # Nếu permission pending, hiển thị thêm
        if [ "$status" = "permission" ] && [ -f "$STATE_DIR/${name}.permission" ]; then
            local tool perm_id
            tool=$(jq -r '.tool // "?"' "$STATE_DIR/${name}.permission" 2>/dev/null)
            perm_id=$(cat "$STATE_DIR/${name}.permission_id" 2>/dev/null || echo "?")
            echo "║    perm: tool=$tool  id=$perm_id"
            echo "║    → ./serve_controller.sh allow $name"
        fi
        echo "║"
    done

    [ "$has" = false ] && echo "║  (no workers running)                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
}

# Bot: background event monitor – spawn SSE per worker
cmd_bot() {
    mkdir -p "$STATE_DIR"
    echo "bot:started pid=$$"

    # Spawn SSE monitor cho tất cả worker hiện có
    for f in "$STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        local name port
        name=$(jq -r .name "$f")
        port=$(jq -r .port "$f")

        if ! alive "$name" 2>/dev/null; then
            echo "dead" > "$STATE_DIR/${name}.status"
            continue
        fi

        # Chỉ spawn nếu chưa có monitor
        if [ -f "$STATE_DIR/${name}.sse_pid" ]; then
            local old_pid
            old_pid=$(cat "$STATE_DIR/${name}.sse_pid" 2>/dev/null)
            if kill -0 "$old_pid" 2>/dev/null; then continue; fi
        fi

        monitor_worker "$name" "$port" &
        echo $! > "$STATE_DIR/${name}.sse_pid"
        echo "bot:spawned sse_monitor $name (pid:$!)"
    done

    # Main loop: quét worker mới + kiểm tra stuck permission
    while true; do
        for f in "$STATE_DIR"/*.json; do
            [ -f "$f" ] || continue
            local name port pid
            name=$(jq -r .name "$f")
            port=$(jq -r .port "$f")
            pid=$(jq -r .pid "$f")

            if ! kill -0 "$pid" 2>/dev/null; then
                [ "$(cat "$STATE_DIR/${name}.status" 2>/dev/null)" != "dead" ] && \
                    echo "dead" > "$STATE_DIR/${name}.status"
                continue
            fi

            # Spawn SSE monitor nếu chưa có
            if [ ! -f "$STATE_DIR/${name}.sse_pid" ]; then
                monitor_worker "$name" "$port" &
                echo $! > "$STATE_DIR/${name}.sse_pid"
                echo "bot:spawned sse_monitor $name (pid:$!)"
                continue
            fi

            local old_pid
            old_pid=$(cat "$STATE_DIR/${name}.sse_pid" 2>/dev/null)
            if ! kill -0 "$old_pid" 2>/dev/null; then
                monitor_worker "$name" "$port" &
                echo $! > "$STATE_DIR/${name}.sse_pid"
                echo "bot:respawning sse_monitor $name (pid:$!)"
                continue
            fi

            # Kiểm tra stuck: status=permission nhưng không có SSE update
            local cur_status
            cur_status=$(cat "$STATE_DIR/${name}.status" 2>/dev/null || echo "unknown")

            # Nếu SSE detect permission nhưng permission file không có
            # → fallback: poll trực tiếp session để check
            if [ "$cur_status" = "permission" ] && [ ! -f "$STATE_DIR/${name}.permission" ]; then
                local resp
                resp=$(curl -s --max-time 5 "http://127.0.0.1:$port/session/status" 2>/dev/null || echo "")
                if [ -z "$resp" ]; then continue; fi
                # SSE monitor có thể đã crash, restart
                monitor_worker "$name" "$port" &
                echo $! > "$STATE_DIR/${name}.sse_pid"
                echo "bot:respawning sse_monitor $name (cur=$cur_status, no perm file)"
            fi
        done

        sleep 5
    done
}

# ── Main ────────────────────────────────────────────────

mkdir -p "$STATE_DIR" "$STATE_DIR/configs"

case "${1:-}" in
    create)
        shift; cmd_create "$@"
        ;;
    send)
        shift; cmd_send "$@"
        ;;
    send-async)
        shift; cmd_send_async "$@"
        ;;
    status)
        shift; cmd_status "$@"
        ;;
    status-all)
        cmd_status_all
        ;;
    result)
        shift; cmd_result "$@"
        ;;
    result-full)
        shift; cmd_result_full "$@"
        ;;
    allow)
        shift; cmd_allow "$@"
        ;;
    deny)
        shift; cmd_deny "$@"
        ;;
    permission-info|perminfo)
        shift; cmd_permission_info "$@"
        ;;
    kill)
        shift; cmd_kill "$@"
        ;;
    killall)
        cmd_killall
        ;;
    dashboard|dash)
        cmd_dashboard
        ;;
    bot)
        cmd_bot
        ;;
    *)
        cat <<EOF
Serve Controller — opencode serve worker management
Bot: SSE event monitor → bắt permission/idle/error → báo Manager

USAGE:
  $0 create <name> [model]       Tạo worker (serve process, auto port)
  $0 send <name> <prompt>        Gửi task — BLOCKING, trả kết quả
  $0 send-async <name> <prompt>  Gửi task — NON-BLOCKING (khuyên dùng + poll)
  $0 status <name>               Trạng thái: idle|running|permission|error|dead
  $0 status-all                  Trạng thái tất cả + hint allow
  $0 result <name>               Đọc kết quả text
  $0 result-full <name>          Đọc full JSON response

PERMISSION HANDLING:
  $0 permission-info <name>      Xem chi tiết permission đang chờ
  $0 allow <name>                Chấp nhận permission
  $0 deny <name>                 Từ chối permission

MANAGEMENT:
  $0 dashboard                   Bảng tổng quan (có highlight permission)
  $0 kill <name>                 Hủy worker
  $0 killall                     Hủy tất cả workers
  $0 bot                         Chạy background event monitor (SSE)

TYPICAL MANAGER FLOW (không bị kẹt permission):
  1. create Worker-1
  2. send-async Worker-1 "nhiệm vụ"
  3. while true; do
       s=\$(status Worker-1)
       case \$s in
         idle)       result Worker-1; break ;;
         permission) permission-info Worker-1; allow Worker-1 ;;
         error)      break ;;
       esac
       sleep 3
     done

STATE: $STATE_DIR
PORT BASE: $PORT_BASE
DEFAULT MODEL: $DEFAULT_MODEL
EOF
        ;;
esac
