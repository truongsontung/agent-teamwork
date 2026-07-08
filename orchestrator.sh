#!/bin/bash
# Advanced Orchestrator - Multi-step workflow with Agent A and B
# Demonstrates a complete task lifecycle

set -e

MSG_DIR="shared/messages"
A_TO_B="$MSG_DIR/a_to_b.txt"
B_TO_A="$MSG_DIR/b_to_a.txt"
STATUS="$MSG_DIR/status.txt"
WORKFLOW_LOG="$MSG_DIR/workflow.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$WORKFLOW_LOG"
}

# Workflow: Deploy Application
workflow_deploy() {
    local APP_NAME="${1:-myapp}"
    local ENV="${2:-staging}"
    
    log "${YELLOW}=== Starting Deploy Workflow: $APP_NAME -> $ENV ===${NC}"
    
    # Step 1: Analysis
    log "Step 1: Analysis Phase"
    cat > "$A_TO_B" <<EOF
[TASK_TYPE] T-DEPLOY-001 | HIGH
---
Goal: Analyze deployment readiness for $APP_NAME
Context: Pre-deployment check for $ENV environment
Constraints: Read-only, no changes
Expected Output: 
1. Code quality check results
2. Test coverage summary  
3. Dependency audit
4. Environment compatibility report
---
EOF
    
    wait_for_response "T-DEPLOY-001" 120
    local analysis_result=$(cat "$B_TO_A")
    echo "" > "$B_TO_A"
    
    if echo "$analysis_result" | grep -q "BLOCKED"; then
        log "${RED}Deployment blocked: $analysis_result${NC}"
        return 1
    fi
    
    log "${GREEN}Analysis complete${NC}"
    
    # Step 2: Build
    log "Step 2: Build Phase"
    cat > "$A_TO_B" <<EOF
[TASK_TYPE] T-DEPLOY-002 | HIGH
---
Goal: Build $APP_NAME for $ENV
Context: Creating deployment artifacts
Constraints: Use production optimizations
Expected Output: 
1. Build success confirmation
2. Artifact locations
3. Build time metrics
---
EOF
    
    wait_for_response "T-DEPLOY-002" 180
    local build_result=$(cat "$B_TO_A")
    echo "" > "$B_TO_A"
    
    if ! echo "$build_result" | grep -q "SUCCESS"; then
        log "${RED}Build failed: $build_result${NC}"
        return 1
    fi
    
    log "${GREEN}Build complete${NC}"
    
    # Step 3: Deploy
    log "Step 3: Deploy Phase"
    cat > "$A_TO_B" <<EOF
[TASK_TYPE] T-DEPLOY-003 | CRITICAL
---
Goal: Deploy $APP_NAME to $ENV
Context: Production deployment
Constraints: Zero-downtime, rollback capability
Expected Output:
1. Deployment status
2. Health check results
3. Monitoring endpoints
---
EOF
    
    wait_for_response "T-DEPLOY-003" 300
    local deploy_result=$(cat "$B_TO_A")
    echo "" > "$B_TO_A"
    
    if echo "$deploy_result" | grep -q "SUCCESS"; then
        log "${GREEN}=== Deployment Complete ===${NC}"
        log "App: $APP_NAME"
        log "Environment: $ENV"
        log "Status: SUCCESS"
        return 0
    else
        log "${RED}Deployment failed: $deploy_result${NC}"
        return 1
    fi
}

# Workflow: Code Review
workflow_review() {
    local PR_NUMBER="${1:-123}"
    local REPO="${2:-myorg/myrepo}"
    
    log "${YELLOW}=== Starting Code Review: PR #$PR_NUMBER ===${NC}"
    
    # Step 1: Fetch PR details
    cat > "$A_TO_B" <<EOF
[TASK_TYPE] T-REVIEW-001 | MEDIUM
---
Goal: Review PR #$PR_NUMBER in $REPO
Context: Code review request
Constraints: Focus on security, performance, and best practices
Expected Output:
1. Summary of changes
2. Security concerns (if any)
3. Performance implications
4. Code quality assessment
5. Approval status: APPROVED / CHANGES_REQUESTED
---
EOF
    
    wait_for_response "T-REVIEW-001" 120
    local review_result=$(cat "$B_TO_A")
    echo "" > "$B_TO_A"
    
    log "${GREEN}Review complete${NC}"
    echo "$review_result"
}

wait_for_response() {
    local task_id="$1"
    local timeout="$2"
    local start=$(date +%s)
    
    log "Waiting for response (task: $task_id, timeout: ${timeout}s)..."
    
    while true; do
        if [ -s "$B_TO_A" ]; then
            return 0
        fi
        
        local now=$(date +%s)
        local elapsed=$((now - start))
        
        if [ $elapsed -ge $timeout ]; then
            log "${RED}Timeout waiting for response${NC}"
            return 1
        fi
        
        sleep 5
    done
}

# Usage
show_usage() {
    cat <<EOF
Advanced Orchestrator for Agent Communication

Usage:
    $0 deploy <app_name> <environment>
    $0 review <pr_number> <repo>

Examples:
    $0 deploy myapp staging
    $0 deploy webapp production
    $0 review 456 myorg/webapp

Environment Variables:
    OPENAI_API_KEY    - OpenAI API key (if using OpenAI)
    ANTHROPIC_API_KEY - Anthropic API key (if using Anthropic)
    LLM_PROVIDER      - "openai" or "anthropic" (default: openai)
EOF
}

# Main
case "${1:-}" in
    deploy)
        workflow_deploy "$2" "$3"
        ;;
    review)
        workflow_review "$2" "$3"
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
