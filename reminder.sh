#!/bin/bash
# Simple Task Reminder - Shows pending tasks for agents

TASKS_FILE="shared/state/tasks.json"

show_reminder() {
    local agent="${1:-B}"
    
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         NHẮC NHỞ NHIỆM VỤ - Agent $agent                ║"
    echo "║         $(date '+%Y-%m-%d %H:%M:%S')                            ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    
    if [ ! -f "$TASKS_FILE" ]; then
        echo "║  Chưa có task nào                                     ║"
    else
        local count=$(jq -r --arg agent "$agent" '[.tasks[] | select(.assigned_to == $agent and .status == "PENDING")] | length' "$TASKS_FILE")
        
        if [ "$count" -eq 0 ]; then
            echo "║  ✓ Không có task đang chờ                             ║"
        else
            echo "║  Có $count task đang chờ:                               ║"
            echo "║                                                        ║"
            
            jq -r --arg agent "$agent" '
                .tasks[] | select(.assigned_to == $agent and .status == "PENDING") |
                "║  [\(.id)] \(.title)\n║    Priority: \(.priority) | Created: \(.created_at[:10])\n"
            ' "$TASKS_FILE"
        fi
    fi
    
    echo "╚══════════════════════════════════════════════════════════╝"
}

show_reminder "$@"
