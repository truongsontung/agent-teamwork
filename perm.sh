#!/bin/bash
# Permission Handler - Auto Mode
# No human intervention needed

set -e

LOG_FILE="shared/state/permission.log"
POLICY_FILE="shared/messages/permission_policy.json"

mkdir -p shared/state

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if filename ends with suffix
ends_with() {
    local filename="$1"
    local suffix="$2"
    [[ "$filename" == *"$suffix" ]]
}

# Check permission based on policy
check_permission() {
    local file="$1"
    
    # Get base filename
    local basename=$(basename "$file")
    
    # Check auto_deny
    while IFS= read -r pattern; do
        if [[ "$basename" == *"$pattern"* ]] || [[ "$file" == *"$pattern"* ]]; then
            log "DENIED: $file (matches deny pattern: $pattern)"
            return 1
        fi
    done < <(jq -r '.auto_deny[]' "$POLICY_FILE" 2>/dev/null)
    
    # Check auto_approve
    while IFS= read -r pattern; do
        if [[ "$basename" == *"$pattern"* ]] || [[ "$file" == *"$pattern"* ]]; then
            log "APPROVED: $file (matches approve pattern: $pattern)"
            return 0
        fi
    done < <(jq -r '.auto_approve[]' "$POLICY_FILE" 2>/dev/null)
    
    # Default: approve
    log "APPROVED: $file (default)"
    return 0
}

# Read file with auto-permission
auto_read() {
    local file="$1"
    
    if check_permission "$file"; then
        if [ -f "$file" ]; then
            cat "$file"
            return 0
        else
            log "File not found: $file"
            return 1
        fi
    else
        log "Permission denied: $file"
        return 1
    fi
}

# Set FULL_AUTO mode
set_auto_mode() {
    cat > "$POLICY_FILE" <<'EOF'
{
    "mode": "FULL_AUTO",
    "auto_approve": [
        ".md",
        ".txt",
        ".json",
        ".yaml",
        ".yml",
        ".toml",
        ".env",
        "src/",
        "lib/",
        "app/",
        "components/",
        "package.json",
        "tsconfig.json",
        "README"
    ],
    "auto_deny": [
        ".key",
        ".pem",
        "id_rsa",
        ".p12",
        ".pfx"
    ],
    "require_approval": []
}
EOF
    
    log "Policy set to FULL_AUTO mode"
    echo "✓ Permission mode: FULL_AUTO"
}

# Set SECURE mode
set_secure_mode() {
    cat > "$POLICY_FILE" <<'EOF'
{
    "mode": "SECURE",
    "auto_approve": [
        ".md",
        ".txt",
        ".json",
        ".yaml",
        "src/",
        "lib/",
        "package.json"
    ],
    "auto_deny": [
        ".key",
        ".pem",
        "id_rsa"
    ],
    "require_approval": [
        ".env",
        "credentials",
        "token",
        "secret"
    ]
}
EOF
    
    log "Policy set to SECURE mode"
    echo "✓ Permission mode: SECURE"
}

case "${1:-}" in
    read)
        shift
        auto_read "$@"
        ;;
    auto)
        set_auto_mode
        ;;
    secure)
        set_secure_mode
        ;;
    check)
        shift
        check_permission "$@"
        echo $?
        ;;
    *)
        cat <<EOF
Permission Handler

USAGE:
  $0 read <file>         Read file with auto-permission
  $0 check <file>        Check permission (0=allow, 1=deny)
  $0 auto                Set FULL_AUTO mode (no human)
  $0 secure              Set SECURE mode (human for sensitive)
EOF
        ;;
esac
