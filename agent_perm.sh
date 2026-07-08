#!/bin/bash
# Permission per Agent - Agent A controls Agent B's permissions

set -e

POLICY_DIR="shared/state"
LOG_FILE="$POLICY_DIR/permission.log"

mkdir -p "$POLICY_DIR"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Get policy file path
get_policy() {
    local agent="$1"
    echo "$POLICY_DIR/policy_agent_$agent.json"
}

# Check permission for specific agent
check_agent_permission() {
    local agent="$1"
    local file="$2"
    
    local policy_file=$(get_policy "$agent")
    
    if [ ! -f "$policy_file" ]; then
        log "Agent $agent: No policy, using default DENY"
        return 1
    fi
    
    local basename=$(basename "$file")
    
    # Check auto_deny (but allow can override)
    while IFS= read -r pattern; do
        if [[ "$basename" == *"$pattern"* ]]; then
            # Check if there's an allow override
            while IFS= read -r allow_pattern; do
                if [[ "$basename" == *"$allow_pattern"* ]]; then
                    log "Agent $agent APPROVED: $file (override: $allow_pattern)"
                    return 0
                fi
            done < <(jq -r '.auto_approve[]' "$policy_file" 2>/dev/null)
            
            log "Agent $agent DENIED: $file (deny: $pattern)"
            return 1
        fi
    done < <(jq -r '.auto_deny[]' "$policy_file" 2>/dev/null)
    
    # Check auto_approve
    while IFS= read -r pattern; do
        if [[ "$basename" == *"$pattern"* ]]; then
            log "Agent $agent APPROVED: $file (approve: $pattern)"
            return 0
        fi
    done < <(jq -r '.auto_approve[]' "$policy_file" 2>/dev/null)
    
    # Default
    log "Agent $agent: $file - default APPROVE"
    return 0
}

# Set permission for agent
set_permission() {
    local agent="$1"
    local file_pattern="$2"
    local action="$3"  # approve or deny
    
    local policy_file=$(get_policy "$agent")
    
    if [ ! -f "$policy_file" ]; then
        echo '{"auto_approve":[],"auto_deny":[]}' > "$policy_file"
    fi
    
    if [ "$action" = "approve" ]; then
        jq --arg p "$file_pattern" '.auto_approve += [$p] | .auto_approve |= unique' "$policy_file" > tmp.json && mv tmp.json "$policy_file"
        log "Agent A: Agent $agent CAN read $file_pattern"
    else
        jq --arg p "$file_pattern" '.auto_deny += [$p] | .auto_deny |= unique' "$policy_file" > tmp.json && mv tmp.json "$policy_file"
        log "Agent A: Agent $agent CANNOT read $file_pattern"
    fi
}

# Show permissions
show_permissions() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         AGENT PERMISSIONS                              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    
    for agent in A B; do
        local policy_file=$(get_policy "$agent")
        echo ""
        echo "Agent $agent:"
        if [ -f "$policy_file" ]; then
            echo "  Can read: $(jq -r '.auto_approve | join(", ")' "$policy_file")"
            echo "  Cannot read: $(jq -r '.auto_deny | join(", ")' "$policy_file")"
        else
            echo "  (no policy)"
        fi
    done
}

# Initialize default policies
init_policies() {
    cat > "$(get_policy A)" <<'EOF'
{
    "auto_approve": [".md", ".txt", ".json", ".yaml", "src/", "lib/", "package.json"],
    "auto_deny": [".key", ".pem", "id_rsa"]
}
EOF

    cat > "$(get_policy B)" <<'EOF'
{
    "auto_approve": [".md", ".txt", ".json"],
    "auto_deny": [".key", ".pem"]
}
EOF

    log "Default policies initialized"
    echo "✓ Default policies created"
}

case "${1:-}" in
    check)
        shift
        check_agent_permission "$@"
        result=$?
        echo $result
        exit $result
        ;;
    allow)
        shift
        set_permission "B" "$1" "approve"
        ;;
    deny)
        shift
        set_permission "B" "$1" "deny"
        ;;
    show)
        show_permissions
        ;;
    init)
        init_policies
        ;;
    *)
        cat <<EOF
Permission per Agent - Agent A controls Agent B

USAGE:
  $0 check <agent> <file>     Check if agent can read file
  $0 allow <file>             Agent A allows Agent B to read
  $0 deny <file>              Agent A denies Agent B from reading
  $0 show                     Show all permissions
  $0 init                     Initialize defaults

EXAMPLES:
  $0 init                     # Create default policies
  $0 allow .env               # Agent A allows B to read .env
  $0 deny .env                # Agent A denies B from reading .env
  $0 check B .env             # Check if B can read .env
  $0 show                     # Show all permissions
EOF
        ;;
esac
