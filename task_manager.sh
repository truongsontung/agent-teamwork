#!/bin/bash
# Task State Manager - Persists all tasks and prevents forgetting
# Agents can query current state anytime

set -e

STATE_DIR="shared/state"
TASKS_FILE="$STATE_DIR/tasks.json"
LOG_FILE="$STATE_DIR/task_manager.log"
HEARTBEAT_FILE="$STATE_DIR/heartbeat.txt"

mkdir -p "$STATE_DIR"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Initialize tasks file if not exists
init_tasks() {
    if [ ! -f "$TASKS_FILE" ]; then
        echo '{"tasks":[],"metadata":{"created":"'"$(date -Iseconds)"'","version":"1.0"}}' > "$TASKS_FILE"
        log "Initialized tasks file"
    fi
}

# Add new task
add_task() {
    local task_id="$1"
    local title="$2"
    local assigned_to="${3:-B}"  # A or B
    local priority="${4:-MEDIUM}"
    local description="${5:-}"
    
    init_tasks
    
    local task_json=$(cat <<EOF
{
    "id": "$task_id",
    "title": "$title",
    "assigned_to": "$assigned_to",
    "priority": "$priority",
    "description": "$description",
    "status": "PENDING",
    "created_at": "$(date -Iseconds)",
    "updated_at": "$(date -Iseconds)",
    "deadline": null,
    "dependencies": [],
    "notes": [],
    "reminder_count": 0,
    "last_reminder": null
}
EOF
)
    
    # Add task to JSON (using jq if available, else simple append)
    if command -v jq &> /dev/null; then
        local tmp=$(mktemp)
        jq --argjson task "$task_json" '.tasks += [$task]' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"
    else
        # Fallback: append to array (simple, not proper JSON)
        sed -i '$ s/}$/},/' "$TASKS_FILE"
        echo "$task_json" >> "$TASKS_FILE"
        echo ']}' >> "$TASKS_FILE"
    fi
    
    log "Added task: $task_id - $title (assigned to Agent $assigned_to)"
}

# Update task status
update_task() {
    local task_id="$1"
    local status="$2"
    local note="${3:-}"
    
    init_tasks
    
    if command -v jq &> /dev/null; then
        local tmp=$(mktemp)
        jq --arg id "$task_id" --arg status "$status" --arg note "$note" --arg time "$(date -Iseconds)" '
            .tasks |= map(
                if .id == $id then
                    .status = $status |
                    .updated_at = $time |
                    if $note != "" then .notes += [{"time": $time, "note": $note}] else . end
                else . end
            )
        ' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"
    fi
    
    log "Updated task $task_id: status=$status"
}

# Get tasks for specific agent
get_agent_tasks() {
    local agent="${1:-B}"
    local status_filter="${2:-}"  # Optional: PENDING, IN_PROGRESS, etc.
    
    init_tasks
    
    if command -v jq &> /dev/null; then
        if [ -n "$status_filter" ]; then
            jq --arg agent "$agent" --arg status "$status_filter" '
                .tasks[] | select(.assigned_to == $agent and .status == $status)
            ' "$TASKS_FILE"
        else
            jq --arg agent "$agent" '
                .tasks[] | select(.assigned_to == $agent)
            ' "$TASKS_FILE"
        fi
    else
        echo "(Requires jq for proper JSON parsing)"
        cat "$TASKS_FILE"
    fi
}

# Get pending tasks (for reminder)
get_pending_tasks() {
    local agent="${1:-}"
    
    init_tasks
    
    if command -v jq &> /dev/null; then
        if [ -n "$agent" ]; then
            jq --arg agent "$agent" '
                .tasks[] | select(.assigned_to == $agent and (.status == "PENDING" or .status == "IN_PROGRESS"))
            ' "$TASKS_FILE"
        else
            jq '
                .tasks[] | select(.status == "PENDING" or .status == "IN_PROGRESS")
            ' "$TASKS_FILE"
        fi
    fi
}

# Send reminder (updates reminder count)
send_reminder() {
    local task_id="$1"
    
    init_tasks
    
    if command -v jq &> /dev/null; then
        local tmp=$(mktemp)
        jq --arg id "$task_id" --arg time "$(date -Iseconds)" '
            .tasks |= map(
                if .id == $id then
                    .reminder_count += 1 |
                    .last_reminder = $time
                else . end
            )
        ' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"
    fi
    
    log "Reminder sent for task $task_id"
}

# Heartbeat - agents call this periodically
heartbeat() {
    local agent_id="$1"
    local status="${2:-alive}"
    
    echo "$agent_id:$status:$(date -Iseconds)" > "$HEARTBEAT_FILE"
    log "Heartbeat from Agent $agent_id: $status"
}

# Check if agent is alive
check_agent_alive() {
    local agent_id="$1"
    local max_age_seconds="${2:-300}"  # 5 minutes default
    
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        return 1
    fi
    
    local last_heartbeat=$(cat "$HEARTBEAT_FILE" | grep "^$agent_id:" | cut -d: -f3)
    
    if [ -z "$last_heartbeat" ]; then
        return 1
    fi
    
    local last_epoch=$(date -d "$last_heartbeat" +%s 2>/dev/null || echo 0)
    local now_epoch=$(date +%s)
    local age=$((now_epoch - last_epoch))
    
    if [ $age -lt $max_age_seconds ]; then
        return 0
    else
        return 1
    fi
}

# Generate reminder message
generate_reminder() {
    local agent="${1:-B}"
    
    init_tasks
    
    echo "=========================================="
    echo "         NHẮC NHỞ NHIỆM VỤ"
    echo "         Agent: $agent"
    echo "         Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    echo ""
    
    local pending=$(get_pending_tasks "$agent")
    
    if [ -z "$pending" ]; then
        echo "✓ Không có nhiệm vụ đang chờ"
    else
        echo "$pending" | while read -r task; do
            local id=$(echo "$task" | jq -r '.id')
            local title=$(echo "$task" | jq -r '.title')
            local status=$(echo "$task" | jq -r '.status')
            local priority=$(echo "$task" | jq -r '.priority')
            local reminders=$(echo "$task" | jq -r '.reminder_count')
            
            echo "[$id] $title"
            echo "  Status: $status | Priority: $priority | Reminders sent: $reminders"
            
            if [ "$reminders" -gt 2 ]; then
                echo "  ⚠ CẢNH BÁO: Đã nhắc nhở nhiều lần!"
            fi
            echo ""
        done
    fi
    
    echo "=========================================="
}

# Reminder loop for Agent A (supervisor)
reminder_loop() {
    local interval="${1:-300}"  # Default 5 minutes
    
    log "Starting reminder loop (interval: ${interval}s)..."
    
    while true; do
        # Check Agent B heartbeat
        if check_agent_alive "B" 300; then
            log "Agent B is alive"
        else
            log "WARNING: Agent B may be offline!"
        fi
        
        # Get pending tasks
        local pending_b=$(get_pending_tasks "B")
        
        if [ -n "$pending_b" ]; then
            # Send reminders for old tasks
            echo "$pending_b" | while read -r task; do
                local id=$(echo "$task" | jq -r '.id')
                local reminders=$(echo "$task" | jq -r '.reminder_count')
                
                if [ "$reminders" -lt 3 ]; then
                    send_reminder "$id"
                    log "Sent reminder for task $id (count: $((reminders+1)))"
                fi
            done
        fi
        
        sleep "$interval"
    done
}

# Show all tasks (dashboard)
show_dashboard() {
    init_tasks
    
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                    TASK DASHBOARD                       ║"
    echo "║                    $(date '+%Y-%m-%d %H:%M:%S')                   ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    
    if command -v jq &> /dev/null; then
        echo "║  Agent A Tasks:                                         ║"
        jq -r '.tasks[] | select(.assigned_to == "A") | "    [\(.id)] \(.title) - \(.status)"' "$TASKS_FILE" 2>/dev/null || echo "    (none)"
        
        echo "║                                                         ║"
        echo "║  Agent B Tasks:                                         ║"
        jq -r '.tasks[] | select(.assigned_to == "B") | "    [\(.id)] \(.title) - \(.status)"' "$TASKS_FILE" 2>/dev/null || echo "    (none)"
    fi
    
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  Agent Status:                                          ║"
    
    if check_agent_alive "A" 300; then
        echo "║    Agent A: ✓ ALIVE                                     ║"
    else
        echo "║    Agent A: ✗ OFFLINE                                   ║"
    fi
    
    if check_agent_alive "B" 300; then
        echo "║    Agent B: ✓ ALIVE                                     ║"
    else
        echo "║    Agent B: ✗ OFFLINE                                   ║"
    fi
    
    echo "╚══════════════════════════════════════════════════════════╝"
}

# Main
case "${1:-}" in
    add)
        shift
        add_task "$@"
        ;;
    update)
        shift
        update_task "$@"
        ;;
    get)
        shift
        get_agent_tasks "$@"
        ;;
    pending)
        shift
        get_pending_tasks "$@"
        ;;
    reminder)
        shift
        generate_reminder "$@"
        ;;
    heartbeat)
        shift
        heartbeat "$@"
        ;;
    dashboard)
        show_dashboard
        ;;
    monitor)
        shift
        reminder_loop "$@"
        ;;
    *)
        cat <<EOF
Task State Manager - Prevents agents from forgetting tasks

COMMANDS:
  add <id> <title> [agent] [priority] [description]   Add new task
  update <id> <status> [note]                         Update task status
  get <agent> [status_filter]                         Get agent's tasks
  pending [agent]                                     Get pending tasks
  reminder <agent>                                    Generate reminder message
  heartbeat <agent_id> [status]                       Update agent heartbeat
  dashboard                                           Show all tasks
  monitor [interval_seconds]                          Auto reminder loop

STATUS VALUES:
  PENDING, IN_PROGRESS, COMPLETED, BLOCKED, CANCELLED

EXAMPLES:
  $0 add T001 "Deploy app" B HIGH "Deploy to production"
  $0 update T001 IN_PROGRESS "Started working"
  $0 reminder B
  $0 dashboard
  $0 monitor 60
EOF
        ;;
esac
