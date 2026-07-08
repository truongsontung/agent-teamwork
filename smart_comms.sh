#!/bin/bash
# Smart Comms - Enhanced communication with special message types
# Handles: CHOICE, ALLOW, CONFIRM, PROGRESS requests

set -e

MSG_DIR="shared/messages"
A_TO_B="$MSG_DIR/a_to_b.txt"
B_TO_A="$MSG_DIR/b_to_a.txt"
STATUS="$MSG_DIR/status.txt"
CHOICES="$MSG_DIR/pending_choices.txt"
ALLOWS="$MSG_DIR/pending_allows.txt"
LOG="$MSG_DIR/smart_comms.log"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"
}

# Agent B: Send choice request
send_choice() {
    local task_id="$1"
    local question="$2"
    shift 2
    local options=("$@")
    
    local choice_msg="[CHOICE] $task_id
---
Question: $question
Options:"

    for i in "${!options[@]}"; do
        choice_msg+="
  $((i+1)). ${options[$i]}"
    done

    choice_msg+="
Required: true
Pending since: $(date -Iseconds)
---
"
    
    echo "$choice_msg" > "$B_TO_A"
    echo "$task_id:CHOICE" >> "$CHOICES"
    log "CHOICE request sent for task $task_id"
}

# Agent B: Send allow request (for .env, secrets, etc.)
send_allow() {
    local task_id="$1"
    local resource="$2"
    local action="$3"
    local reason="$4"
    local risk="${5:-MEDIUM}"
    
    local allow_msg="[ALLOW] $task_id
---
Resource: $resource
Action: $action
Reason: $reason
Risk: $risk
Requested at: $(date -Iseconds)
Timeout: 120s
---
"
    
    echo "$allow_msg" > "$B_TO_A"
    echo "$task_id:ALLOW:$resource" >> "$ALLOWS"
    log "ALLOW request sent for task $task_id (resource: $resource)"
}

# Agent B: Send confirm request (for destructive actions)
send_confirm() {
    local task_id="$1"
    local action="$2"
    local impact="$3"
    
    local confirm_msg="[CONFIRM] $task_id
---
Action: $action
Impact: $impact
Requires approval: true
Requested at: $(date -Iseconds)
---
"
    
    echo "$confirm_msg" > "$B_TO_A"
    log "CONFIRM request sent for task $task_id"
}

# Agent A: Check for pending requests
check_requests() {
    echo "=== Pending Requests ==="
    
    if [ -f "$CHOICES" ] && [ -s "$CHOICES" ]; then
        echo ""
        echo "CHOICES:"
        cat "$CHOICES"
    fi
    
    if [ -f "$ALLOWS" ] && [ -s "$ALLOWS" ]; then
        echo ""
        echo "ALLOWS:"
        cat "$ALLOWS"
    fi
    
    if [ ! -f "$CHOICES" ] || [ ! -s "$CHOICES" ] && [ ! -f "$ALLOWS" ] || [ ! -s "$ALLOWS" ]; then
        echo "(none)"
    fi
}

# Agent A: Respond to choice
respond_choice() {
    local task_id="$1"
    local selected="$2"
    local reason="${3:-}"
    
    local response="[CHOICE_RESPONSE] $task_id
---
Selected: $selected
Reason: $reason
Responded at: $(date -Iseconds)
---
"
    
    echo "$response" > "$A_TO_B"
    
    # Remove from pending
    if [ -f "$CHOICES" ]; then
        sed -i "/^$task_id:CHOICE$/d" "$CHOICES"
    fi
    
    log "CHOICE response sent for task $task_id (selected: $selected)"
}

# Agent A: Respond to allow request
respond_allow() {
    local task_id="$1"
    local decision="$2"  # GRANTED or DENIED
    local constraints="${3:-}"
    local expiry="${4:-300}"
    
    local response="[ALLOW_RESPONSE] $task_id
---
Decision: $decision
Constraints: $constraints
Expiry: ${expiry}s
Responded at: $(date -Iseconds)
---
"
    
    echo "$response" > "$A_TO_B"
    
    # Remove from pending
    if [ -f "$ALLOWS" ]; then
        sed -i "/^$task_id:ALLOW:/d" "$ALLOWS"
    fi
    
    log "ALLOW response sent for task $task_id (decision: $decision)"
}

# Agent B: Wait for specific response type
wait_for_response() {
    local task_id="$1"
    local response_type="${2:-RESULT}"  # CHOICE, ALLOW, CONFIRM, RESULT
    local timeout="${3:-60}"
    local start=$(date +%s)
    
    log "Waiting for $response_type response (task: $task_id)..."
    
    while true; do
        if [ -s "$A_TO_B" ]; then
            local content=$(cat "$A_TO_B")
            
            # Check if this is the response we're waiting for
            if echo "$content" | grep -q "^\[$response_type" && echo "$content" | grep -q "$task_id"; then
                echo "" > "$A_TO_B"
                log "Received $response_type for task $task_id"
                echo "$content"
                return 0
            fi
        fi
        
        local now=$(date +%s)
        local elapsed=$((now - start))
        
        if [ $elapsed -ge $timeout ]; then
            log "TIMEOUT waiting for $response_type"
            return 1
        fi
        
        sleep 5
    done
}

# Agent A: Monitor loop with auto-response
monitor_loop() {
    local auto_approve="${1:-false}"
    
    log "Starting monitor loop (auto_approve: $auto_approve)..."
    
    while true; do
        # Check for incoming messages
        if [ -s "$B_TO_A" ]; then
            local message=$(cat "$B_TO_A")
            echo "" > "$B_TO_A"
            
            # Parse message type
            local msg_type=$(echo "$message" | grep -oP '^\[\K[^\]]+' | head -1)
            local task_id=$(echo "$message" | grep -oP 'Task[:\s]+\K\S+' || echo "unknown")
            
            case "$msg_type" in
                CHOICE)
                    log "Received CHOICE request from Agent B"
                    if [ "$auto_approve" = "true" ]; then
                        # Auto-select first option
                        respond_choice "$task_id" "1" "Auto-approved"
                    else
                        # Human needs to decide
                        echo ""
                        echo "=========================================="
                        echo "AGENT B ASKS FOR YOUR CHOICE:"
                        echo "=========================================="
                        echo "$message"
                        echo "=========================================="
                        echo "Use: ./smart_comms.sh respond-choice $task_id <number>"
                        echo ""
                    fi
                    ;;
                
                ALLOW)
                    log "Received ALLOW request from Agent B"
                    if [ "$auto_approve" = "true" ]; then
                        respond_allow "$task_id" "GRANTED" "Auto-approved" 300
                    else
                        echo ""
                        echo "=========================================="
                        echo "AGENT B REQUESTS ACCESS:"
                        echo "=========================================="
                        echo "$message"
                        echo "=========================================="
                        echo "Use: ./smart_comms.sh respond-allow $task_id GRANTED|DENIED"
                        echo ""
                    fi
                    ;;
                
                CONFIRM)
                    log "Received CONFIRM request from Agent B"
                    echo ""
                    echo "=========================================="
                    echo "AGENT B REQUESTS CONFIRMATION:"
                    echo "=========================================="
                    echo "$message"
                    echo "=========================================="
                    echo "Use: ./smart_comms.sh respond-confirm $task_id YES|NO"
                    echo ""
                    ;;
                
                RESULT|PROGRESS)
                    log "Received $msg_type from Agent B"
                    echo ""
                    echo "========== AGENT B RESPONSE =========="
                    echo "$message"
                    echo "======================================="
                    ;;
                
                *)
                    log "Unknown message type: $msg_type"
                    echo "$message"
                    ;;
            esac
        fi
        
        sleep 10
    done
}

# Main command handler
case "${1:-}" in
    send-choice)
        shift
        send_choice "$@"
        ;;
    
    send-allow)
        shift
        send_allow "$@"
        ;;
    
    send-confirm)
        shift
        send_confirm "$@"
        ;;
    
    respond-choice)
        shift
        respond_choice "$@"
        ;;
    
    respond-allow)
        shift
        respond_allow "$@"
        ;;
    
    check-requests)
        check_requests
        ;;
    
    wait)
        shift
        wait_for_response "$@"
        ;;
    
    monitor)
        shift
        monitor_loop "$@"
        ;;
    
    *)
        cat <<EOF
Smart Comms - Enhanced Agent Communication

USAGE (Agent B - Worker):
  $0 send-choice <task_id> <question> <opt1> <opt2> ...    # Ask for choice
  $0 send-allow <task_id> <resource> <action> <reason> [risk]  # Request access
  $0 send-confirm <task_id> <action> <impact>              # Request confirmation
  $0 wait <task_id> [response_type] [timeout]              # Wait for response

USAGE (Agent A - Supervisor):
  $0 respond-choice <task_id> <selected_number> [reason]   # Answer choice
  $0 respond-allow <task_id> GRANTED|DENIED [constraints] [expiry]  # Grant/deny access
  $0 check-requests                                        # View pending requests
  $0 monitor [auto_approve]                                # Auto-monitor loop

EXAMPLES:
  # Agent B: Ask which environment to deploy
  $0 send-choice T001 "Chọn environment" "staging" "production"

  # Agent B: Request access to .env
  $0 send-allow T002 ".env" "READ" "Need database URL" "LOW"

  # Agent A: Grant access
  $0 respond-allow T002 GRANTED "Read only" 300

  # Agent A: Auto-monitor with auto-approve
  $0 monitor true
EOF
        ;;
esac
