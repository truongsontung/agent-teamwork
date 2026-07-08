#!/bin/bash
# Agent Communication Helper Script
# Usage: 
#   ./comms.sh send-a <message>  - Agent A sends to B
#   ./comms.sh send-b <message>  - Agent B sends to A
#   ./comms.sh check-a          - Agent A checks for messages from B
#   ./comms.sh check-b          - Agent B checks for messages from A
#   ./comms.sh status           - Show current communication status

set -e

MSG_DIR="shared/messages"
A_TO_B="$MSG_DIR/a_to_b.txt"
B_TO_A="$MSG_DIR/b_to_a.txt"
STATUS="$MSG_DIR/status.txt"

case "$1" in
    send-a)
        echo "$2" > "$A_TO_B"
        echo "Agent A -> Agent B: Message sent"
        echo "ASSIGNED" > "$STATUS"
        ;;
    
    send-b)
        echo "$2" > "$B_TO_A"
        echo "Agent B -> Agent A: Message sent"
        echo "RESPONDED" > "$STATUS"
        ;;
    
    check-a)
        if [ -s "$B_TO_A" ]; then
            echo "=== Response from Agent B ==="
            cat "$B_TO_A"
            echo "=============================="
            echo "" > "$B_TO_A"  # Clear after reading
        else
            echo "No new messages from Agent B"
        fi
        ;;
    
    check-b)
        if [ -s "$A_TO_B" ]; then
            echo "=== Message from Agent A ==="
            cat "$A_TO_B"
            echo "============================"
            echo "" > "$A_TO_B"  # Clear after reading
        else
            echo "No new messages from Agent A"
        fi
        ;;
    
    status)
        echo "=== Communication Status ==="
        echo "A -> B: $([ -s "$A_TO_B" ] && echo 'PENDING' || echo 'EMPTY')"
        echo "B -> A: $([ -s "$B_TO_A" ] && echo 'PENDING' || echo 'EMPTY')"
        echo "State: $(cat "$STATUS" 2>/dev/null || echo 'UNKNOWN')"
        echo "==========================="
        ;;
    
    *)
        echo "Usage: $0 {send-a|send-b|check-a|check-b|status} [message]"
        exit 1
        ;;
esac
