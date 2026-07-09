#!/bin/bash
# Serve Controller - opencode serve workers via REST + SSE
# Token-optimized: mọi output tối giản, bot log ghi file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"
STATE_DIR="$PROJECT_DIR/.worker"
WK="${AGENT_TEAMWORK_HOME:-$SCRIPT_DIR}/worker.json"
PORT_BASE=$(jq -r '.port_base // 4091' "$WK" 2>/dev/null)
DEFAULT_TIMEOUT=$(jq -r '.timeout // 300' "$WK" 2>/dev/null)
DEFAULT_MODEL=$(jq -r '.model // "opencode/deepseek-v4-flash-free"' "$WK" 2>/dev/null)
BOT_LOG="$STATE_DIR/bot.log"

# ── Helpers ──────────────────────────────────────────────

die() { echo "err: $*" >&2; exit 1; }
log()  { echo "$(date +%H:%M:%S) $*" >> "$BOT_LOG"; }

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
worker_sid()   { worker_info "$1" | jq -r .session_id; }

alive() { kill -0 "$(worker_pid "$1" 2>/dev/null)" 2>/dev/null; }

check_worker() {
    worker_exists "$1" || die "worker '$1' not found"
    alive "$1" || die "worker '$1' dead"
}

wait_serve_ready() {
    local port=$1 i=0
    while [ $i -lt 30 ]; do
        curl -s --max-time 2 "http://127.0.0.1:$port/session/status" >/dev/null 2>&1 && return 0
        sleep 1; i=$((i + 1))
    done
    die "serve not ready on port $port"
}

parse_model() {
    local m="$1"
    [[ "$m" == */* ]] && echo "${m%%/*}|${m#*/}" || echo "opencode|$m"
}

write_worker_config() {
    local name="$1" conf="$STATE_DIR/configs/${name}.json"
    mkdir -p "$STATE_DIR/configs"
    local perm=$(jq -c '.permission' "$WK" 2>/dev/null)
    perm="${perm//__PROJECT_DIR__/$PROJECT_DIR}"
    perm=$(echo "$perm" | jq --arg d "$STATE_DIR" '.external_directory[$d + "/*"] = "allow"')
    jq -n --argjson p "$perm" '{"$schema":"https://opencode.ai/config.json",permission:$p}' > "$conf"
    echo "$conf"
}

# ── SSE Monitor (per worker) ─────────────────────────────

monitor_worker() {
    local name="$1" port="$2"
    local sf="$STATE_DIR/${name}.status" pf="$STATE_DIR/${name}.permission"

    curl -s -N --no-buffer "http://127.0.0.1:$port/event" 2>/dev/null | while IFS= read -r line; do

        # Format: data: {"type":"...","properties":{...}}
        local json=""
        if [[ "$line" == data:* ]]; then
            json="${line#data: }"
        elif echo "$line" | jq -e '.type' >/dev/null 2>&1; then
            json="$line"
        else
            continue
        fi

        local et
        et=$(echo "$json" | jq -r '.type // empty' 2>/dev/null)
        [ -z "$et" ] && continue

        case "$et" in
            "session.idle")
                echo "idle" > "$sf"; log "event $name idle" ;;
            "session.error")
                echo "error" > "$sf"; echo "$json" > "$STATE_DIR/${name}.error"
                log "event $name error" ;;
            "permission.asked")
                echo "permission" > "$sf"
                echo "$json" > "$pf"
                local pid=$(echo "$json" | jq -r '.properties.id // "?"' 2>/dev/null)
                echo "$pid" > "$STATE_DIR/${name}.permission_id"
                local ptype=$(echo "$json" | jq -r '.properties.permission // "?"' 2>/dev/null)
                log "event $name permission type=$ptype id=$pid" ;;
            "permission.replied")
                echo "running" > "$sf"; rm -f "$pf" "$STATE_DIR/${name}.permission_id"
                log "event $name perm_resolved" ;;
            "session.status")
                local st=$(echo "$json" | jq -r '.properties.status.type // ""' 2>/dev/null)
                case "$st" in
                    "idle") echo "idle" > "$sf" ;;
                    "busy") echo "running" > "$sf" ;;
                esac ;;
            "session.created")
                echo "running" > "$sf"; log "event $name created" ;;
        esac
    done
}

# ── Permission ───────────────────────────────────────────

cmd_allow() {
    check_worker "$1"
    local port=$(worker_port "$1") sid=$(worker_sid "$1")
    local pid=$(cat "$STATE_DIR/${1}.permission_id" 2>/dev/null || echo "")
    [ -z "$pid" ] || [ "$pid" = "?" ] && die "no pending permission"
    curl -s --max-time 10 -X POST \
        "http://127.0.0.1:$port/session/$sid/permissions/$pid" \
        -H "Content-Type: application/json" -d '{"action":"allow"}' >/dev/null 2>&1
    rm -f "$STATE_DIR/${1}.permission" "$STATE_DIR/${1}.permission_id"
    echo "running" > "$STATE_DIR/${1}.status"
    echo "ok"
}

cmd_deny() {
    check_worker "$1"
    local port=$(worker_port "$1") sid=$(worker_sid "$1")
    local pid=$(cat "$STATE_DIR/${1}.permission_id" 2>/dev/null || echo "")
    [ -z "$pid" ] || [ "$pid" = "?" ] && die "no pending permission"
    curl -s --max-time 10 -X POST \
        "http://127.0.0.1:$port/session/$sid/permissions/$pid" \
        -H "Content-Type: application/json" -d '{"action":"deny"}' >/dev/null 2>&1
    rm -f "$STATE_DIR/${1}.permission" "$STATE_DIR/${1}.permission_id"
    echo "running" > "$STATE_DIR/${1}.status"
    echo "ok"
}

cmd_permission_info() {
    [ -f "$STATE_DIR/${1}.permission" ] || die "no pending permission"
    local pt=$(jq -r '.properties.permission // "?"' "$STATE_DIR/${1}.permission" 2>/dev/null)
    local pid=$(cat "$STATE_DIR/${1}.permission_id" 2>/dev/null || echo "?")
    local pat=$(jq -r '.properties.patterns // [] | join(", ")' "$STATE_DIR/${1}.permission" 2>/dev/null)
    echo "type=$pt id=$pid"
    echo "patterns=$pat"
}

# ── Core Commands ────────────────────────────────────────

cmd_create() {
    local name="$1" model="${2:-$DEFAULT_MODEL}"
    worker_exists "$name" && die "exists"
    local max=$(jq -r '.max_workers // 5' "$WK")
    local cur=$(ls "$STATE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$cur" -ge "$max" ] && die "max $max"

    local port=$(next_port)
    local cf=$(write_worker_config "$name")
    OPENCODE_CONFIG="$cf" nohup opencode serve --port "$port" --hostname 127.0.0.1 \
        > "$STATE_DIR/${name}.log" 2>&1 &
    local pid=$!

    wait_serve_ready "$port"

    # Tạo session trong serve → lấy session_id (prefix ses_)
    local sid
    sid=$(curl -s --max-time 10 -X POST "http://127.0.0.1:$port/session" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"$name\"}" | jq -r '.id // empty' 2>/dev/null)
    [ -z "$sid" ] && { kill "$pid" 2>/dev/null; die "session create failed"; }

    mkdir -p "$STATE_DIR"
    jq -n --arg n "$name" --arg p "$port" --arg i "$pid" --arg m "$model" --arg s "$sid" \
        '{name:$n,port:($p|tonumber),pid:($i|tonumber),model:$m,session_id:$s}' > "$STATE_DIR/$name.json"

    monitor_worker "$name" "$port" &
    echo $! > "$STATE_DIR/${name}.sse_pid"
    echo "running" > "$STATE_DIR/${name}.status"
    date +%s > "$STATE_DIR/${name}.last_activity"
    echo "+$name"
}

cmd_send() {
    local name="$1"; shift; local prompt="$*"
    check_worker "$name"
    local port=$(worker_port "$name") sid=$(worker_sid "$name")
    local model_str=$(worker_model "$name")
    IFS='|' read -r provider model_id <<< "$(parse_model "$model_str")"
    local timeout=$(jq -r ".timeout // $DEFAULT_TIMEOUT" "$STATE_DIR/$name.json")
    rm -f "$STATE_DIR/${name}.permission" "$STATE_DIR/${name}.permission_id"

    local payload=$(jq -n --arg t "$prompt" --arg p "$provider" --arg m "$model_id" \
        '{parts:[{type:"text",text:$t}],model:{providerID:$p,modelID:$m}}')
    echo "$payload" > "$STATE_DIR/${name}.last_request"

    local result http_code
    result=$(curl -s -w '\n%{http_code}' --max-time "$timeout" \
        -X POST "http://127.0.0.1:$port/session/$sid/message" \
        -H "Content-Type: application/json" -d "$payload" 2>&1)
    http_code=$(echo "$result" | tail -1)
    local body=$(echo "$result" | sed '$d')
    echo "$body" > "$STATE_DIR/${name}.last_result"

    [ "$http_code" != "200" ] && { echo "$body" >&2; return 1; }
    jq -r '[.parts[]?|select(.type=="text").text//empty]|join("\n")' \
        "$STATE_DIR/${name}.last_result" 2>/dev/null || cat "$STATE_DIR/${name}.last_result"
}

cmd_send_async() {
    local name="$1"; shift; local prompt="$*"
    check_worker "$name"
    local port=$(worker_port "$name") sid=$(worker_sid "$name")
    local model_str=$(worker_model "$name")
    IFS='|' read -r provider model_id <<< "$(parse_model "$model_str")"
    rm -f "$STATE_DIR/${name}.permission" "$STATE_DIR/${name}.permission_id"

    local payload=$(jq -n --arg t "$prompt" --arg p "$provider" --arg m "$model_id" \
        '{parts:[{type:"text",text:$t}],model:{providerID:$p,modelID:$m}}')
    echo "$payload" > "$STATE_DIR/${name}.last_request"

    local hc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "http://127.0.0.1:$port/session/$sid/prompt_async" \
        -H "Content-Type: application/json" -d "$payload" 2>&1)
    [ "$hc" = "204" ] || [ "$hc" = "200" ] || { echo "err: HTTP $hc"; return 1; }
    echo "+"
}

cmd_status() {
    local name="$1"
    [ -f "$STATE_DIR/${name}.status" ] && { cat "$STATE_DIR/${name}.status"; return; }
    alive "$name" 2>/dev/null || { echo "dead"; return; }
    local port=$(worker_port "$name" 2>/dev/null) sid=$(worker_sid "$name" 2>/dev/null)
    [ -z "$port" ] && { echo "?"; return; }
    local raw
    raw=$(curl -s --max-time 5 "http://127.0.0.1:$port/session/status" 2>/dev/null)
    local st=$(echo "$raw" | jq -r ".[\"$sid\"].type // .[\"$sid\"] // \"running\"" 2>/dev/null)
    [ "$st" = "busy" ] && st="running"
    echo "${st:-running}"
}

cmd_status_all() {
    for f in "$STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        local n=$(jq -r .name "$f") s
        s=$(cmd_status "$n" 2>/dev/null || echo "dead")
        echo "$n $s"
    done
}

cmd_result() {
    local name="$1"
    [ -f "$STATE_DIR/${name}.last_result" ] || die "no result"
    jq -r '[.parts[]?|select(.type=="text").text//empty]|join("\n")' \
        "$STATE_DIR/${name}.last_result" 2>/dev/null || cat "$STATE_DIR/${name}.last_result"
}

cmd_kill() {
    worker_exists "$1" || die "not found"
    local port=$(worker_port "$1" 2>/dev/null || echo "") pid=$(worker_pid "$1" 2>/dev/null || echo "")
    local sid=$(worker_sid "$1" 2>/dev/null || echo "")
    [ -f "$STATE_DIR/${1}.sse_pid" ] && kill "$(cat "$STATE_DIR/${1}.sse_pid")" 2>/dev/null || true
    [ -n "$port" ] && [ -n "$sid" ] && curl -s --max-time 3 -X POST "http://127.0.0.1:$port/session/$sid/abort" >/dev/null 2>&1 || true
    [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; sleep 1; kill -9 "$pid" 2>/dev/null || true; }
    rm -f "$STATE_DIR/$1.json" "$STATE_DIR/${1}".{log,last_request,last_result,status,status.prev,permission,permission_id,sse_pid,error,last_activity} "$STATE_DIR/configs/${1}.json"
    echo "-$1"
}

cmd_killall() {
    local c=0
    for f in "$STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        cmd_kill "$(jq -r .name "$f")" 2>/dev/null; c=$((c+1))
    done
    rm -rf "$STATE_DIR/configs"
    echo "$c"
}

cmd_dashboard() {
    local has=false
    for f in "$STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        has=true
        local n=$(jq -r .name "$f") s
        [ -f "$STATE_DIR/${n}.status" ] && s=$(cat "$STATE_DIR/${n}.status") || s="?"
        echo "$n $s"
    done
    [ "$has" = false ] && echo "(none)"
}

# Bot: background SSE monitor
cmd_bot() {
    mkdir -p "$STATE_DIR"; touch "$BOT_LOG"
    log "started"

    for f in "$STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        local n=$(jq -r .name "$f") p=$(jq -r .port "$f")
        alive "$n" 2>/dev/null || { echo "dead" > "$STATE_DIR/${n}.status"; continue; }
        [ -f "$STATE_DIR/${n}.sse_pid" ] && kill -0 "$(cat "$STATE_DIR/${n}.sse_pid")" 2>/dev/null && continue
        monitor_worker "$n" "$p" &
        echo $! > "$STATE_DIR/${n}.sse_pid"
        log "sse_monitor $n pid=$!"
    done

    while true; do
        for f in "$STATE_DIR"/*.json; do
            [ -f "$f" ] || continue
            local n=$(jq -r .name "$f") p=$(jq -r .port "$f") i=$(jq -r .pid "$f")
            if ! kill -0 "$i" 2>/dev/null; then
                [ "$(cat "$STATE_DIR/${n}.status" 2>/dev/null)" != "dead" ] && echo "dead" > "$STATE_DIR/${n}.status"
                continue
            fi
            if [ ! -f "$STATE_DIR/${n}.sse_pid" ] || ! kill -0 "$(cat "$STATE_DIR/${n}.sse_pid")" 2>/dev/null; then
                monitor_worker "$n" "$p" &
                echo $! > "$STATE_DIR/${n}.sse_pid"
                log "sse_monitor $n respawn pid=$!"
            fi
        done
        sleep 5
    done
}

# ── Main ────────────────────────────────────────────────

mkdir -p "$STATE_DIR" "$STATE_DIR/configs"

case "${1:-}" in
    create)      shift; cmd_create "$@" ;;
    send)        shift; cmd_send "$@" ;;
    send-async)  shift; cmd_send_async "$@" ;;
    status)      shift; cmd_status "$@" ;;
    status-all)  cmd_status_all ;;
    result)      shift; cmd_result "$@" ;;
    allow)       shift; cmd_allow "$@" ;;
    deny)        shift; cmd_deny "$@" ;;
    permission-info|perminfo) shift; cmd_permission_info "$@" ;;
    kill)        shift; cmd_kill "$@" ;;
    killall)     cmd_killall ;;
    dashboard|dash) cmd_dashboard ;;
    bot)         cmd_bot ;;
    *)
        cat <<EOF
USAGE: $0 <cmd>
  create <n> [m]    send <n> <task>    send-async <n> <task>
  status <n>        status-all         result <n>
  permission-info <n>  allow <n>       deny <n>
  kill <n>          killall            dashboard
  bot
EOF
        ;;
esac
