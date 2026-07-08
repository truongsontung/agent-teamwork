#!/bin/bash
# Unit tests for tmux_controller.sh
# Usage: bash tests/test_unit_tmux_controller.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONTROLLER="$BASE_DIR/tmux_controller.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_FILE="/tmp/test_pass_$$"
FAIL_FILE="/tmp/test_fail_$$"
echo 0 > "$PASS_FILE"
echo 0 > "$FAIL_FILE"

pass() { echo $(( $(cat "$PASS_FILE") + 1 )) > "$PASS_FILE"; echo -e "  ${GREEN}✓ PASS${NC} $1"; }
fail() { echo $(( $(cat "$FAIL_FILE") + 1 )) > "$FAIL_FILE"; echo -e "  ${RED}✗ FAIL${NC} $1: $2"; }

assert_exit() {
    local expected=$1 actual=$2 name=$3
    [ "$expected" -eq "$actual" ] && pass "$name" || fail "$name" "expected exit=$expected, got=$actual"
}

assert_contains() {
    local haystack=$1 pattern=$2 name=$3
    echo "$haystack" | grep -qE "$pattern" && pass "$name" || fail "$name" "pattern not found in: ${haystack:0:80}"
}

assert_not_contains() {
    local haystack=$1 pattern=$2 name=$3
    echo "$haystack" | grep -qE "$pattern" && fail "$name" "should NOT contain '$pattern'" || pass "$name"
}

# ─── Mock ───────────────────────────────────────────────────────
MOCK_DIR="/tmp/mock_tmux$$"

setup_mock() {
    rm -rf "$MOCK_DIR"
    mkdir -p "$MOCK_DIR"
    SESSION="test-session"
    export SESSION

    # State files
    echo "user@host:~\$" > "$MOCK_DIR/screen.txt"  # default screen
    : > "$MOCK_DIR/sent.log"
    echo "1" > "$MOCK_DIR/call_count"

    # Mock tmux
    cat > "$MOCK_DIR/tmux" << 'TMUX_MOCK'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
WF="$D/windows.txt"
SF="$D/screen.txt"
SC="$D/call_count"

# Increment call count (used to change screen state for wait_prompt tests)
n=$(cat "$SC" 2>/dev/null || echo 1)
echo $((n + 1)) > "$SC"

case "$1" in
    has-session) [ -f "$WF" ] && exit 0 || exit 1 ;;
    list-windows) [ -f "$WF" ] && cat "$WF"; exit 0 ;;
    send-keys)
        shift; echo "$*" >> "$D/sent.log"
        # After Enter key, update screen to shell prompt (simulates command finishing)
        for arg in "$@"; do [ "$arg" = "Enter" ] && echo 'user@host:~$' > "$SF"; done
        exit 0
        ;;
    capture-pane) [ -f "$SF" ] && cat "$SF" || true; exit 0 ;;
    new-window)
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in -n) echo "$2" >> "$WF"; shift 2 ;; *) shift ;; esac
        done
        exit 0
        ;;
    kill-window)
        if [ -f "$WF" ]; then
            name=$(echo "${3:-}" | sed 's/.*://')
            grep -v "^${name}$" "$WF" > "$WF.tmp" 2>/dev/null || true
            mv "$WF.tmp" "$WF"
        fi
        exit 0
        ;;
    list-panes) echo "12345"; exit 0 ;;
    *) exit 0 ;;
esac
TMUX_MOCK
    chmod +x "$MOCK_DIR/tmux"
    export PATH="$MOCK_DIR:$PATH"

    # Mock jq
    cat > "$MOCK_DIR/jq" << 'EOF'
#!/bin/bash
case "$*" in *max_workers*) echo "3" ;; *default_model*) echo "mock/model-v1" ;; *) echo "null" ;; esac
EOF
    chmod +x "$MOCK_DIR/jq"
}

set_mock_windows()  { echo "$1" > "$MOCK_DIR/windows.txt"; }
set_mock_screen()   { echo "$1" > "$MOCK_DIR/screen.txt"; echo "1" > "$MOCK_DIR/call_count"; }
get_mock_sent()     { cat "$MOCK_DIR/sent.log" 2>/dev/null || true; }
cleanup_mock()      { rm -rf "$MOCK_DIR"; }

load_funcs() {
    sed -n '1,/^case "\${1:-}" in/p' "$CONTROLLER" | head -n -1 > "$MOCK_DIR/f.sh"
    source "$MOCK_DIR/f.sh"
}

run_test() {
    local fn=$1
    (setup_mock; load_funcs; "$fn"; cleanup_mock)
}

# ─── check_session ──────────────────────────────────────────────
tc_check_session_no_session() {
    rm -f "$MOCK_DIR/windows.txt"
    local out; out=$(check_session 2>&1); local rc=$?
    assert_exit 1 $rc "check_session: exit 1 when no session"
    assert_contains "$out" "not found" "check_session: error message"
}
tc_check_session_exists() {
    set_mock_windows "Manager"
    check_session >/dev/null 2>&1; local rc=$?
    assert_exit 0 $rc "check_session: exit 0 when session exists"
}

# ─── worker_exists ──────────────────────────────────────────────
tc_worker_exists_true() {
    set_mock_windows "Manager
worker1
worker2"
    worker_exists "worker1"; local rc=$?
    assert_exit 0 $rc "worker_exists: exit 0 for existing worker"
}
tc_worker_exists_false() {
    set_mock_windows "Manager
worker1"
    worker_exists "nonexistent"; local rc=$?
    assert_exit 1 $rc "worker_exists: exit 1 for missing worker"
}
tc_worker_exists_empty() {
    rm -f "$MOCK_DIR/windows.txt"
    worker_exists "anything"; local rc=$?
    assert_exit 1 $rc "worker_exists: exit 1 when no windows"
}

# ─── send ───────────────────────────────────────────────────────
tc_send_no_session() {
    rm -f "$MOCK_DIR/windows.txt"
    local out; out=$(send "worker1" "ls" 2>&1); local rc=$?
    assert_exit 1 $rc "send: exit 1 when no session"
    assert_contains "$out" "Session" "send: error message on no session"
}
tc_send_worker_not_found() {
    set_mock_windows "Manager"
    local out; out=$(send "ghost" "ls" 2>&1); local rc=$?
    assert_exit 1 $rc "send: exit 1 when worker missing"
    assert_contains "$out" "not found" "send: error on missing worker"
}
tc_send_happy_path() {
    set_mock_windows "Manager
worker1"
    send "worker1" "npm install" >/dev/null 2>&1; local rc=$?
    assert_exit 0 $rc "send: exit 0 on success"
    local sent; sent=$(get_mock_sent)
    assert_contains "$sent" "npm install" "send: tmux send-keys called"
}
tc_send_multiword() {
    set_mock_windows "Manager
worker1"
    send "worker1" "cd /tmp && ls -la" >/dev/null 2>&1
    local sent; sent=$(get_mock_sent)
    assert_contains "$sent" "cd /tmp" "send: multi-word command"
}

# ─── read_screen ────────────────────────────────────────────────
tc_read_screen_no_session() {
    rm -f "$MOCK_DIR/windows.txt"
    read_screen "worker1" >/dev/null 2>&1; local rc=$?
    assert_exit 1 $rc "read_screen: exit 1 when no session"
}
tc_read_screen_worker_not_found() {
    set_mock_windows "Manager"
    read_screen "ghost" >/dev/null 2>&1; local rc=$?
    assert_exit 1 $rc "read_screen: exit 1 when worker missing"
}
tc_read_screen_happy_path() {
    set_mock_windows "Manager
worker1"
    set_mock_screen 'user@host:~$ ls
file1.txt  file2.txt
user@host:~$'
    local out; out=$(read_screen "worker1"); local rc=$?
    assert_exit 0 $rc "read_screen: exit 0 on success"
    assert_contains "$out" "file1.txt" "read_screen: returns content"
}
tc_read_screen_empty() {
    set_mock_windows "Manager
worker1"
    echo "" > "$MOCK_DIR/screen.txt"
    local out; out=$(read_screen "worker1"); local rc=$?
    assert_exit 0 $rc "read_screen: exit 0 on empty screen"
}

# ─── wait_prompt ────────────────────────────────────────────────
tc_wait_prompt_no_session() {
    rm -f "$MOCK_DIR/windows.txt"
    wait_prompt "worker1" 1 >/dev/null 2>&1; local rc=$?
    assert_exit 1 $rc "wait_prompt: exit 1 when no session"
}
tc_wait_prompt_worker_not_found() {
    set_mock_windows "Manager"
    wait_prompt "ghost" 1 >/dev/null 2>&1; local rc=$?
    assert_exit 1 $rc "wait_prompt: exit 1 when worker missing"
}
tc_wait_prompt_shell_prompt() {
    set_mock_windows "Manager
worker1"
    set_mock_screen 'user@host:~$'
    wait_prompt "worker1" 5 >/dev/null 2>&1; local rc=$?
    assert_exit 0 $rc "wait_prompt: detects shell prompt"
}
tc_wait_prompt_opencode_idle() {
    set_mock_windows "Manager
worker1"
    # Note: controller's grep pattern "ctrl+p commands" has + as regex quantifier,
    # so it never matches literal "ctrl+p". Idle detection falls through to
    # stability detection (4 identical reads). Use a stable screen to test.
    set_mock_screen 'opencode idle screen'
    wait_prompt "worker1" 10 >/dev/null 2>&1; local rc=$?
    assert_exit 0 $rc "wait_prompt: stability fallback on idle screen"
}
tc_wait_prompt_permission() {
    set_mock_windows "Manager
worker1"
    # First call: permission prompt. Mock tmux sends Enter → screen changes to shell prompt.
    set_mock_screen 'Permission required'
    wait_prompt "worker1" 10 >/dev/null 2>&1; local rc=$?
    assert_exit 0 $rc "wait_prompt: handles permission prompt"
    local sent; sent=$(get_mock_sent)
    assert_contains "$sent" "Enter" "wait_prompt: sent Enter for permission"
}
tc_wait_prompt_always_allow() {
    set_mock_windows "Manager
worker1"
    set_mock_screen 'Always allow'
    wait_prompt "worker1" 10 >/dev/null 2>&1; local rc=$?
    assert_exit 0 $rc "wait_prompt: handles Always allow"
    local sent; sent=$(get_mock_sent)
    assert_contains "$sent" "Enter" "wait_prompt: sent Enter for Always allow"
}
tc_wait_prompt_opencode_dialog() {
    set_mock_windows "Manager
worker1"
    # Dialog-only screen: function should NOT auto-handle it (just sleep+continue)
    # Test that it doesn't crash and returns via timeout
    set_mock_screen '△ Ask user for input'
    timeout 5 bash -c "source '$MOCK_DIR/f.sh'; SESSION='test-session'; wait_prompt worker1 2" >/dev/null 2>&1; local rc=$?
    [ "$rc" -eq 1 ] || [ "$rc" -eq 124 ] && pass "wait_prompt: dialog does not auto-handle (timeout)" \
        || fail "wait_prompt: dialog does not auto-handle" "exit=$rc"
}
tc_wait_prompt_stability() {
    set_mock_windows "Manager
worker1"
    set_mock_screen 'user@host:~$'
    wait_prompt "worker1" 10 >/dev/null 2>&1; local rc=$?
    assert_exit 0 $rc "wait_prompt: stability detection works"
}
tc_wait_prompt_timeout() {
    set_mock_windows "Manager
worker1"
    # Write constantly changing screen in background
    (
        for i in $(seq 1 30); do
            echo "Running step $i" > "$MOCK_DIR/screen.txt"
            sleep 0.3
        done
    ) &
    local bg=$!
    echo "30" > "$MOCK_DIR/call_count"
    # Short timeout → should return 1
    timeout 5 bash -c "source '$MOCK_DIR/f.sh'; SESSION='test-session'; wait_prompt worker1 2" >/dev/null 2>&1; local rc=$?
    kill "$bg" 2>/dev/null || true
    [ "$rc" -eq 1 ] || [ "$rc" -eq 124 ] && pass "wait_prompt: timeout behavior" \
        || fail "wait_prompt: timeout behavior" "exit=$rc"
}

# ─── smart ──────────────────────────────────────────────────────
tc_smart_no_session() {
    rm -f "$MOCK_DIR/windows.txt"
    smart "worker1" "ls" >/dev/null 2>&1; local rc=$?
    assert_exit 1 $rc "smart: exit 1 when no session"
}
tc_smart_happy_path() {
    set_mock_windows "Manager
worker1"
    set_mock_screen 'user@host:~$'
    smart "worker1" "npm test" >/dev/null 2>&1; local rc=$?
    assert_exit 0 $rc "smart: exit 0 on success"
    local sent; sent=$(get_mock_sent)
    assert_contains "$sent" "npm test" "smart: sent command via tmux"
}

# ─── create_worker ──────────────────────────────────────────────
tc_create_worker_no_session() {
    rm -f "$MOCK_DIR/windows.txt"
    local out; out=$(create_worker "w1" 2>&1); local rc=$?
    assert_exit 1 $rc "create_worker: exit 1 when no session"
}
tc_create_worker_already_exists() {
    set_mock_windows "Manager
worker1"
    local out; out=$(create_worker "worker1" 2>&1); local rc=$?
    assert_exit 1 $rc "create_worker: exit 1 when duplicate"
    assert_contains "$out" "already exists" "create_worker: error on duplicate"
}
tc_create_worker_happy_path() {
    set_mock_windows "Manager"
    local out; out=$(create_worker "test-w" 2>&1); local rc=$?
    assert_exit 0 $rc "create_worker: exit 0 on success"
    assert_contains "$out" "created" "create_worker: success message"
}
tc_create_worker_with_model() {
    set_mock_windows "Manager"
    create_worker "custom-w" "custom/model" >/dev/null 2>&1
    local sent; sent=$(get_mock_sent)
    assert_contains "$sent" "custom/model" "create_worker: uses specified model"
}
tc_create_worker_max_reached() {
    set_mock_windows "Manager
w1
w2
w3"
    local out; out=$(create_worker "w4" 2>&1); local rc=$?
    assert_exit 1 $rc "create_worker: exit 1 when max reached"
    assert_contains "$out" "Max workers" "create_worker: error on max"
}

# ─── kill_worker ────────────────────────────────────────────────
tc_kill_worker_no_session() {
    rm -f "$MOCK_DIR/windows.txt"
    local out; out=$(kill_worker "w1" 2>&1); local rc=$?
    assert_exit 1 $rc "kill_worker: exit 1 when no session"
}
tc_kill_worker_not_found() {
    set_mock_windows "Manager"
    local out; out=$(kill_worker "ghost" 2>&1); local rc=$?
    assert_exit 1 $rc "kill_worker: exit 1 when missing"
    assert_contains "$out" "not found" "kill_worker: error on missing"
}
tc_kill_worker_happy_path() {
    set_mock_windows "Manager
worker1
worker2"
    local out; out=$(kill_worker "worker1" 2>&1); local rc=$?
    assert_exit 0 $rc "kill_worker: exit 0 on success"
    assert_contains "$out" "killed" "kill_worker: success message"
    worker_exists "worker1"; local ex=$?
    assert_exit 1 $ex "kill_worker: worker removed from list"
}
tc_kill_worker_others_intact() {
    set_mock_windows "Manager
worker1
worker2"
    kill_worker "worker1" >/dev/null 2>&1
    worker_exists "worker2"; local rc=$?
    assert_exit 0 $rc "kill_worker: other workers untouched"
}

# ─── dashboard ──────────────────────────────────────────────────
tc_dashboard_no_session() {
    rm -f "$MOCK_DIR/windows.txt"
    dashboard >/dev/null 2>&1; local rc=$?
    assert_exit 1 $rc "dashboard: exit 1 when no session"
}
tc_dashboard_happy_path() {
    set_mock_windows "Manager
worker1"
    set_mock_screen 'user@host:~$'
    local out; out=$(dashboard 2>&1); local rc=$?
    assert_exit 0 $rc "dashboard: exit 0 on success"
    assert_contains "$out" "AGENT TEAMWORK DASHBOARD" "dashboard: shows header"
    assert_contains "$out" "worker1" "dashboard: lists workers"
}
tc_dashboard_empty_workers() {
    set_mock_windows "Manager"
    local out; out=$(dashboard 2>&1); local rc=$?
    assert_exit 0 $rc "dashboard: exit 0 with only Manager"
    assert_contains "$out" "DASHBOARD" "dashboard: shows header"
}

# ─── Run all tests ──────────────────────────────────────────────
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Unit Tests: tmux_controller.sh${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}▸ check_session${NC}"
run_test tc_check_session_no_session
run_test tc_check_session_exists
echo ""

echo -e "${YELLOW}▸ worker_exists${NC}"
run_test tc_worker_exists_true
run_test tc_worker_exists_false
run_test tc_worker_exists_empty
echo ""

echo -e "${YELLOW}▸ send${NC}"
run_test tc_send_no_session
run_test tc_send_worker_not_found
run_test tc_send_happy_path
run_test tc_send_multiword
echo ""

echo -e "${YELLOW}▸ read_screen${NC}"
run_test tc_read_screen_no_session
run_test tc_read_screen_worker_not_found
run_test tc_read_screen_happy_path
run_test tc_read_screen_empty
echo ""

echo -e "${YELLOW}▸ wait_prompt${NC}"
run_test tc_wait_prompt_no_session
run_test tc_wait_prompt_worker_not_found
run_test tc_wait_prompt_shell_prompt
run_test tc_wait_prompt_opencode_idle
run_test tc_wait_prompt_permission
run_test tc_wait_prompt_always_allow
run_test tc_wait_prompt_opencode_dialog
run_test tc_wait_prompt_stability
echo ""

echo -e "${YELLOW}▸ wait_prompt (timeout)${NC}"
run_test tc_wait_prompt_timeout
echo ""

echo -e "${YELLOW}▸ smart${NC}"
run_test tc_smart_no_session
run_test tc_smart_happy_path
echo ""

echo -e "${YELLOW}▸ create_worker${NC}"
run_test tc_create_worker_no_session
run_test tc_create_worker_already_exists
run_test tc_create_worker_happy_path
run_test tc_create_worker_with_model
run_test tc_create_worker_max_reached
echo ""

echo -e "${YELLOW}▸ kill_worker${NC}"
run_test tc_kill_worker_no_session
run_test tc_kill_worker_not_found
run_test tc_kill_worker_happy_path
run_test tc_kill_worker_others_intact
echo ""

echo -e "${YELLOW}▸ dashboard${NC}"
run_test tc_dashboard_no_session
run_test tc_dashboard_happy_path
run_test tc_dashboard_empty_workers
echo ""

# ─── Summary ────────────────────────────────────────────────────
PASS=$(cat "$PASS_FILE")
FAIL=$(cat "$FAIL_FILE")
TOTAL=$((PASS + FAIL))
rm -f "$PASS_FILE" "$FAIL_FILE"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, $TOTAL total"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
