#!/bin/bash
# Agent Reminder Script - Integrates with task_manager
# Can be run as cron job or background process

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_MANAGER="$SCRIPT_DIR/task_manager.sh"
REMINDER_LOG="$SCRIPT_DIR/shared/state/reminder.log"
REMINDER_INTERVAL="${REMINDER_INTERVAL:-300}"  # 5 minutes

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$REMINDER_LOG"
}

# Check if tmux session exists and agent is responsive
check_agent_responsive() {
    local agent="$1"
    local session_name="${2:-agent-session}"
    
    # Check tmux session
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        log "WARNING: tmux session '$session_name' not found"
        return 1
    fi
    
    # Check agent via file marker
    local marker="shared/state/agent_${agent}_alive.txt"
    if [ -f "$marker" ]; then
        local last_alive=$(cat "$marker")
        local now=$(date +%s)
        local age=$((now - last_alive))
        
        if [ $age -lt 600 ]; then  # 10 minutes
            return 0
        fi
    fi
    
    return 1
}

# Send reminder via tmux (type message to agent)
send_reminder_via_tmux() {
    local agent="$1"
    local message="$2"
    local session_name="${3:-agent-session}"
    
    local window=""
    case "$agent" in
        A) window="Manager" ;;
        B) window="Worker" ;;
    esac
    
    # Send reminder message to agent's tmux window
    tmux send-keys -t "$session_name:$window" "echo '$message'" Enter
    
    log "Sent reminder to Agent $agent via tmux"
}

# Generate and send reminder
send_task_reminder() {
    local agent="$1"
    local session_name="${2:-agent-session}"
    
    # Get reminder message
    local reminder=$("$TASK_MANAGER" reminder "$agent")
    
    # Log the reminder
    log "Sending reminder to Agent $agent"
    
    # Send via tmux
    send_reminder_via_tmux "$agent" "$reminder" "$session_name"
    
    # Also update reminder count in task manager
    "$TASK_MANAGER" pending "$agent" | while read -r task; do
        local task_id=$(echo "$task" | jq -r '.id' 2>/dev/null)
        if [ -n "$task_id" ]; then
            "$TASK_MANAGER" update "$task_id" "PENDING" "Reminder sent at $(date -Iseconds)"
        fi
    done
}

# Monitor and remind
monitor_and_remind() {
    local session_name="${1:-agent-session}"
    
    log "Starting monitor and remind loop..."
    
    while true; do
        # Check Agent B
        if ! check_agent_responsive "B" "$session_name"; then
            log "Agent B not responding, sending reminder..."
            send_task_reminder "B" "$session_name"
        fi
        
        # Check if there are pending tasks
        local pending_count=$("$TASK_MANAGER" pending B 2>/dev/null | wc -l)
        if [ "$pending_count" -gt 0 ]; then
            log "Found $pending_count pending tasks for Agent B"
            
            # Send reminder if tasks are old
            send_task_reminder "B" "$session_name"
        fi
        
        sleep "$REMINDER_INTERVAL"
    done
}

# Quick reminder - one time
quick_reminder() {
    local agent="${1:-B}"
    local session_name="${2:-agent-session}"
    
    echo "Sending quick reminder to Agent $agent..."
    send_task_reminder "$agent" "$session_name"
}

# Show reminder status
show_status() {
    echo "=== Reminder System Status ==="
    echo ""
    echo "Task Manager: $TASK_MANAGER"
    echo "Log File: $REMINDER_LOG"
    echo "Interval: ${REMINDER_INTERVAL}s"
    echo ""
    
    if [ -f "$REMINDER_LOG" ]; then
        echo "Recent reminders:"
        tail -10 "$REMINDER_LOG"
    fi
}

case "${1:-}" in
    start)
        shift
        monitor_and_remind "$@"
        ;;
    remind)
        shift
        quick_reminder "$@"
        ;;
    status)
        show_status
        ;;
    *)
        cat <<EOF
Agent Reminder System

USAGE:
  $0 start [session_name] [interval]     Start monitoring loop
  $0 remind [agent] [session_name]       Send one-time reminder
  $0 status                              Show reminder status

ENVIRONMENT:
  REMINDER_INTERVAL   Seconds between reminders (default: 300)

EXAMPLES:
  $0 start agent-session 60
  $0 remind B agent-session
  $0 status
EOF
        ;;
esac
