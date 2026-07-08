#!/bin/bash
# Auto-supervisor script for Agent A
# Automates the monitoring loop and communication with Agent B
# Usage: ./supervisor.sh <task_file>

set -e

TASK_FILE="${1:-}"
MSG_DIR="shared/messages"
A_TO_B="$MSG_DIR/a_to_b.txt"
B_TO_A="$MSG_DIR/b_to_a.txt"
STATUS="$MSG_DIR/status.txt"
LOG="$MSG_DIR/supervisor.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

send_to_worker() {
    local message="$1"
    echo "$message" > "$A_TO_B"
    log "SENT to Worker: $(echo "$message" | head -1)"
    echo "ASSIGNED" > "$STATUS"
}

wait_for_response() {
    local task_id="$1"
    local timeout="${2:-300}"  # Default 5 min timeout
    local start_time=$(date +%s)
    
    log "Waiting for Worker response (task: $task_id)..."
    
    while true; do
        # Check for response
        if [ -s "$B_TO_A" ]; then
            local response=$(cat "$B_TO_A")
            echo "" > "$B_TO_A"  # Clear
            log "Received response from Worker"
            echo "$response"
            return 0
        fi
        
        # Check timeout
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [ $elapsed -ge $timeout ]; then
            log "TIMEOUT waiting for Worker response"
            return 1
        fi
        
        # Show progress
        echo -ne "\rWaiting... ${elapsed}s/${timeout}s"
        sleep 10
    done
}

evaluate_response() {
    local response="$1"
    local task_id="$2"
    
    # Check status in response
    if echo "$response" | grep -q "Status: SUCCESS"; then
        log "Task $task_id: APPROVED"
        echo "APPROVED" > "$STATUS"
        return 0
    elif echo "$response" | grep -q "Status: BLOCKED"; then
        log "Task $task_id: BLOCKED - needs intervention"
        echo "BLOCKED" > "$STATUS"
        return 2
    elif echo "$response" | grep -q "Status: PARTIAL"; then
        log "Task $task_id: PARTIAL - may need follow-up"
        echo "PARTIAL" > "$STATUS"
        return 1
    else
        log "Task $task_id: NEEDS REVIEW"
        echo "REVIEW" > "$STATUS"
        return 1
    fi
}

# Main execution
if [ -z "$TASK_FILE" ]; then
    echo "Usage: $0 <task_file>"
    echo ""
    echo "Task file format:"
    echo "---"
    echo "TASK_ID=T001"
    echo "PRIORITY=HIGH"
    echo "TIMEOUT=300"
    echo "---"
    echo "Your task content here..."
    exit 1
fi

if [ ! -f "$TASK_FILE" ]; then
    echo "Error: Task file not found: $TASK_FILE"
    exit 1
fi

# Read task
source "$TASK_FILE"
TASK_CONTENT=$(cat "$TASK_FILE" | sed -n '/^---$/,/^---$/p' | sed '1d;$d')

log "=== Starting Task Assignment ==="
log "Task ID: $TASK_ID"
log "Priority: $PRIORITY"

# Send task
send_to_worker "$TASK_CONTENT"

# Wait for response
RESPONSE=$(wait_for_response "$TASK_ID" "${TIMEOUT:-300}")

if [ $? -eq 0 ]; then
    # Evaluate
    evaluate_response "$RESPONSE" "$TASK_ID"
    
    echo ""
    echo "=== Task Complete ==="
    echo "$RESPONSE"
else
    log "Task $task_id: TIMEOUT"
    echo "TIMEOUT" > "$STATUS"
fi
