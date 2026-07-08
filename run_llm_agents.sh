#!/bin/bash
# Example: Run Agent A and B with actual LLM API
# This demonstrates how to connect real AI agents via tmux
# Usage: ./run_llm_agents.sh

set -e

MSG_DIR="shared/messages"
A_TO_B="$MSG_DIR/a_to_b.txt"
B_TO_A="$MSG_DIR/b_to_a.txt"
STATUS="$MSG_DIR/status.txt"

# Configuration - Set your API keys
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

# Choose provider: "openai" or "anthropic"
PROVIDER="${LLM_PROVIDER:-openai}"
MODEL="${LLM_MODEL:-gpt-4}"

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

call_llm() {
    local system_prompt="$1"
    local user_message="$2"
    
    if [ "$PROVIDER" = "openai" ]; then
        curl -s https://api.openai.com/v1/chat/completions \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $OPENAI_API_KEY" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [
                    {\"role\": \"system\", \"content\": \"$system_prompt\"},
                    {\"role\": \"user\", \"content\": \"$user_message\"}
                ],
                \"temperature\": 0.7
            }" | jq -r '.choices[0].message.content'
    
    elif [ "$PROVIDER" = "anthropic" ]; then
        curl -s https://api.anthropic.com/v1/messages \
            -H "Content-Type: application/json" \
            -H "x-api-key: $ANTHROPIC_API_KEY" \
            -H "anthropic-version: 2023-06-01" \
            -d "{
                \"model\": \"$MODEL\",
                \"max_tokens\": 2000,
                \"system\": \"$system_prompt\",
                \"messages\": [
                    {\"role\": \"user\", \"content\": \"$user_message\"}
                ]
            }" | jq -r '.content[0].text'
    fi
}

# Agent A - Supervisor
run_agent_a() {
    local SUPERVISOR_PROMPT=$(cat prompts/agent_a_supervisor.md)
    
    log "Agent A (Supervisor) started"
    
    while true; do
        # Check for responses from Agent B
        if [ -s "$B_TO_A" ]; then
            local response=$(cat "$B_TO_A")
            echo "" > "$B_TO_A"
            
            log "Received response from Agent B"
            
            # Ask LLM to evaluate
            local evaluation=$(call_llm "$SUPERVISOR_PROMPT" "
Agent B sent this response:
$response

Evaluate and decide:
1. If APPROVED: Send feedback and mark complete
2. If NEEDS_REVISION: Send specific instructions
3. If BLOCKED: Help resolve the blocker

Format your response exactly as a message to Agent B.")
            
            echo "$evaluation" > "$A_TO_B"
            log "Sent evaluation to Agent B"
        fi
        
        sleep 20
    done
}

# Agent B - Worker
run_agent_b() {
    local WORKER_PROMPT=$(cat prompts/agent_b_worker.md)
    
    log "Agent B (Worker) started"
    
    while true; do
        # Check for tasks from Agent A
        if [ -s "$A_TO_B" ]; then
            local task=$(cat "$A_TO_B")
            echo "" > "$A_TO_B"
            
            log "Received task from Agent A"
            
            # Ask LLM to execute
            local result=$(call_llm "$WORKER_PROMPT" "
Execute this task:
$task

Provide your response in the exact format specified in your instructions.")
            
            echo "$result" > "$B_TO_A"
            log "Sent result to Agent A"
        fi
        
        sleep 10
    done
}

# Main
if [ -z "$OPENAI_API_KEY" ] && [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "Error: Set OPENAI_API_KEY or ANTHROPIC_API_KEY"
    echo "Example: export OPENAI_API_KEY=sk-..."
    exit 1
fi

echo "Starting LLM Agent System..."
echo "Provider: $PROVIDER"
echo "Model: $MODEL"
echo ""

# Start both agents in background
run_agent_a &
PID_A=$!

run_agent_b &
PID_B=$!

echo "Agents started!"
echo "  Agent A PID: $PID_A"
echo "  Agent B PID: $PID_B"
echo ""
echo "Press Ctrl+C to stop"

# Trap to cleanup
trap "kill $PID_A $PID_B 2>/dev/null; exit" INT TERM

wait
