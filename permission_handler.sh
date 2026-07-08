#!/bin/bash
# Permission Handler for Agent A
# Auto-approve safe reads, require approval for sensitive files

set -e

PERM_FILE="shared/messages/permissions.json"
LOG_FILE="shared/state/permission.log"
AUTO_APPROVE=true  # Set false để cần human approve

mkdir -p shared/state

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if file is safe to auto-approve
is_safe_file() {
    local file="$1"
    
    # Safe patterns (auto-approve)
    local safe_patterns=(
        "*.md"
        "*.txt"
        "*.json"
        "*.yaml"
        "*.yml"
        "*.toml"
        "src/*"
        "lib/*"
        "app/*"
        "components/*"
        "package.json"
        "tsconfig.json"
        "README*"
    )
    
    # Sensitive patterns (require approval)
    local sensitive_patterns=(
        "*.env"
        ".env*"
        "*.key"
        "*.pem"
        "*.secret"
        "*credentials*"
        "*password*"
        "*token*"
        "*api_key*"
        "id_rsa*"
    )
    
    # Check sensitive first
    for pattern in "${sensitive_patterns[@]}"; do
        if [[ "$file" == $pattern ]]; then
            return 1  # Not safe
        fi
    done
    
    # Check safe patterns
    for pattern in "${safe_patterns[@]}"; do
        if [[ "$file" == $pattern ]]; then
            return 0  # Safe
        fi
    done
    
    # Default: not safe
    return 1
}

# Request permission
request_permission() {
    local agent="$1"
    local file="$2"
    local action="$3"
    local reason="${4:-}"
    
    local request_id="PERM_$(date +%s)"
    
    cat > "$PERM_FILE" <<EOF
{
    "id": "$request_id",
    "agent": "$agent",
    "file": "$file",
    "action": "$action",
    "reason": "$reason",
    "status": "PENDING",
    "timestamp": "$(date -Iseconds)"
}
EOF
    
    log "Permission requested: Agent $agent wants to $action $file"
    
    # Check if safe
    if is_safe_file "$file"; then
        if [ "$AUTO_APPROVE" = true ]; then
            approve_permission "$request_id" "Auto-approved (safe file)"
            return 0
        fi
    fi
    
    # Need human approval
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  PERMISSION REQUEST                                    ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  Agent: $agent                                          ║"
    echo "║  Action: $action                                        ║"
    echo "║  File: $file                                            ║"
    echo "║  Reason: $reason                                        ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  Approve? (y/n/e=edit)                                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    read -p "> " response
    
    case "$response" in
        y|Y|yes)
            approve_permission "$request_id" "Human approved"
            return 0
            ;;
        n|N|no)
            deny_permission "$request_id" "Human denied"
            return 1
            ;;
        e|E|edit)
            echo "Enter new file path:"
            read -p "> " new_file
            # Update request
            approve_permission "$request_id" "Approved with new path: $new_file"
            return 0
            ;;
        *)
            deny_permission "$request_id" "Invalid response"
            return 1
            ;;
    esac
}

# Approve permission
approve_permission() {
    local request_id="$1"
    local note="${2:-}"
    
    cat > "$PERM_FILE" <<EOF
{
    "id": "$request_id",
    "status": "APPROVED",
    "note": "$note",
    "timestamp": "$(date -Iseconds)"
}
EOF
    
    log "Permission APPROVED: $request_id - $note"
}

# Deny permission
deny_permission() {
    local request_id="$1"
    local reason="${2:-}"
    
    cat > "$PERM_FILE" <<EOF
{
    "id": "$request_id",
    "status": "DENIED",
    "reason": "$reason",
    "timestamp": "$(date -Iseconds)"
}
EOF
    
    log "Permission DENIED: $request_id - $reason"
}

# Wait for permission response
wait_permission() {
    local timeout="${1:-60}"
    local start=$(date +%s)
    
    while true; do
        if [ -f "$PERM_FILE" ]; then
            local status=$(jq -r '.status' "$PERM_FILE" 2>/dev/null)
            
            if [ "$status" = "APPROVED" ]; then
                rm "$PERM_FILE"
                return 0
            elif [ "$status" = "DENIED" ]; then
                rm "$PERM_FILE"
                return 1
            fi
        fi
        
        local now=$(date +%s)
        local elapsed=$((now - start))
        
        if [ $elapsed -ge $timeout ]; then
            log "Permission timeout"
            return 1
        fi
        
        sleep 2
    done
}

# Auto-read with permission check
safe_read() {
    local file="$1"
    local agent="${2:-A}"
    
    log "Agent $agent requests read: $file"
    
    if request_permission "$agent" "$file" "READ" "Reading file"; then
        if [ -f "$file" ]; then
            cat "$file"
            return 0
        else
            log "File not found: $file"
            return 1
        fi
    else
        log "Permission denied for: $file"
        return 1
    fi
}

# Create permission policy file
create_policy() {
    cat > shared/messages/permission_policy.json <<'EOF'
{
    "auto_approve": [
        "*.md",
        "*.txt",
        "*.json",
        "*.yaml",
        "src/**",
        "lib/**",
        "package.json",
        "tsconfig.json"
    ],
    "require_approval": [
        "*.env",
        ".env*",
        "*.key",
        "*.pem",
        "*credentials*",
        "*password*",
        "*token*",
        "*secret*"
    ],
    "always_deny": [
        "*.key",
        "id_rsa*"
    ]
}
EOF
    
    log "Permission policy created"
}

case "${1:-}" in
    read)
        shift
        safe_read "$@"
        ;;
    approve)
        shift
        approve_permission "$@"
        ;;
    deny)
        shift
        deny_permission "$@"
        ;;
    wait)
        shift
        wait_permission "$@"
        ;;
    policy)
        create_policy
        ;;
    *)
        cat <<EOF
Permission Handler

USAGE:
  $0 read <file> [agent]        Read file with permission check
  $0 approve <request_id> [note] Approve permission
  $0 deny <request_id> [reason]  Deny permission
  $0 wait [timeout]             Wait for permission response
  $0 policy                     Create permission policy

AUTO-APPROVE SAFE FILES:
  *.md, *.txt, *.json, src/*, lib/*

REQUIRE APPROVAL:
  *.env, *.key, *.pem, *credentials*, *token*
EOF
        ;;
esac
