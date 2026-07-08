#!/bin/bash
# Auto-worker script for Agent B
# Listens for tasks from Agent A and processes them
# Usage: ./worker.sh [--once] [--task-id <id>]

set -e

MSG_DIR="shared/messages"
A_TO_B="$MSG_DIR/a_to_b.txt"
B_TO_A="$MSG_DIR/b_to_a.txt"
STATUS="$MSG_DIR/status.txt"
LOG="$MSG_DIR/worker.log"
ONCE_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --once)
            ONCE_MODE=true
            shift
            ;;
        --task-id)
            TASK_ID="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

send_to_supervisor() {
    local message="$1"
    echo "$message" > "$B_TO_A"
    log "SENT to Supervisor: $(echo "$message" | head -1)"
    echo "RESPONDED" > "$STATUS"
}

listen_for_tasks() {
    log "Worker started. Listening for tasks..."
    
    while true; do
        # Check for new task
        if [ -s "$A_TO_B" ]; then
            local task=$(cat "$A_TO_B")
            echo "" > "$A_TO_B"  # Clear
            
            # Extract task ID if present
            local task_id=$(echo "$task" | grep -oP 'task_id[:\s]+\K\S+' | head -1)
            if [ -z "$task_id" ]; then
                task_id="T$(date +%s)"
            fi
            
            log "Received task: $task_id"
            echo "WORKING" > "$STATUS"
            
            # Process task (this is where Agent B's logic goes)
            process_task "$task_id" "$task"
            
            if [ "$ONCE_MODE" = true ]; then
                exit 0
            fi
        fi
        
        sleep 5
    done
}

process_task() {
    local task_id="$1"
    local task_content="$2"
    
    log "Processing task $task_id..."
    
    # Send acknowledgment
    send_to_supervisor "
[TASK_RESULT] $task_id | PARTIAL
---
Status: RECEIVED
Progress: Task received and processing started
Blockers: None
Next Steps: Will send complete results shortly
---
"
    
    # Simulate processing (replace with actual task execution)
    # This is where you'd add your actual task processing logic
    
    sleep 2
    
    # Parse task type and execute accordingly
    if echo "$task_content" | grep -q "ANALYZE"; then
        execute_analysis "$task_id" "$task_content"
    elif echo "$task_content" | grep -q "EXECUTE"; then
        execute_action "$task_id" "$task_content"
    elif echo "$task_content" | grep -q "CREATE"; then
        execute_creation "$task_id" "$task_content"
    else
        execute_generic "$task_id" "$task_content"
    fi
}

execute_analysis() {
    local task_id="$1"
    local task_content="$2"
    
    # Example: Analysis task
    local result="
[TASK_RESULT] $task_id | SUCCESS
---
Status: SUCCESS
Progress: Analysis complete
Blockers: None
Next Steps: Ready for next task
---
Detailed Output:
## Analysis Results

### Summary
Completed analysis as requested.

### Findings
1. Finding 1: <details>
2. Finding 2: <details>

### Recommendations
- Recommendation A
- Recommendation B
---
"
    send_to_supervisor "$result"
}

execute_action() {
    local task_id="$1"
    local task_content="$2"
    
    # Example: Action task
    send_to_supervisor "
[TASK_RESULT] $task_id | SUCCESS
---
Status: SUCCESS
Progress: Action completed successfully
Blockers: None
Next Steps: None
---
Detailed Output:
Action executed as requested.
---
"
}

execute_creation() {
    local task_id="$1"
    local task_content="$2"
    
    # Example: Creation task
    send_to_supervisor "
[TASK_RESULT] $task_id | SUCCESS
---
Status: SUCCESS
Progress: Creation complete
Blockers: None
Next Steps: Ready for review
---
Detailed Output:
Created requested artifact.

[File content or description here]
---
"
}

execute_generic() {
    local task_id="$1"
    local task_content="$2"
    
    send_to_supervisor "
[TASK_RESULT] $task_id | SUCCESS
---
Status: SUCCESS
Progress: Task completed
Blockers: None
Next Steps: None
---
Detailed Output:
Generic task execution complete.

Input received and processed.
---
"
}

# Main
listen_for_tasks
