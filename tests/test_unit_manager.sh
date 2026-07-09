#!/bin/bash
# Unit tests for manager.sh functions

set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

# Setup mock variables
MOCK_SESSION_EXISTS=true
MOCK_WORKER_EXISTS=""
MOCK_WINDOWS_LIST=""
MOCK_WORKER_COUNT=0
MOCK_MAX_WORKERS=5
MOCK_DEFAULT_MODEL="test/model"
TMUX_CAPTURE_OUTPUT=""

# Assert functions
assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}  ✓ $msg${NC}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}  ✗ $msg${NC}"
        echo -e "${RED}    Expected: '$expected'${NC}"
        echo -e "${RED}    Actual:   '$actual'${NC}"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}  ✓ $msg${NC}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}  ✗ $msg${NC}"
        echo -e "${RED}    Expected to contain: '$needle'${NC}"
        echo -e "${RED}    Actual: '$haystack'${NC}"
    fi
}

assert_not_eq() {
    local not_expected="$1"
    local actual="$2"
    local msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$not_expected" != "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}  ✓ $msg${NC}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}  ✗ $msg${NC}"
        echo -e "${RED}    Should not be: '$not_expected'${NC}"
    fi
}

assert_exit_code() {
    local expected_code="$1"
    local actual_code="$2"
    local msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected_code" = "$actual_code" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}  ✓ $msg${NC}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}  ✗ $msg${NC}"
        echo -e "${RED}    Expected exit code: $expected_code${NC}"
        echo -e "${RED}    Actual exit code:   $actual_code${NC}"
    fi
}

# Mock tmux functions
tmux() {
    case "$1" in
        has-session)
            if [ "$MOCK_SESSION_EXISTS" = true ]; then
                return 0
            fi
            return 1
            ;;
        list-windows)
            echo "$MOCK_WINDOWS_LIST"
            ;;
        list-panes)
            echo "12345"
            ;;
        send-keys)
            return 0
            ;;
        new-window)
            return 0
            ;;
        capture-pane)
            echo "$TMUX_CAPTURE_OUTPUT"
            ;;
    esac
}

# Mock jq
jq() {
    case "$2" in
        worker.json)
            case "$1" in
                *max_workers*)
                    echo "$MOCK_MAX_WORKERS"
                    ;;
                *default_model*)
                    echo "$MOCK_DEFAULT_MODEL"
                    ;;
            esac
            ;;
    esac
}

# Source manager functions
source_manager() {
    SESSION="test-session"
    CONFIG="worker.json"
    MAX_WORKERS=$MOCK_MAX_WORKERS
    DEFAULT_MODEL=$MOCK_DEFAULT_MODEL

    check_session() {
        if [ "$MOCK_SESSION_EXISTS" = false ]; then
            echo "Error: Session '$SESSION' not found. Run ./setup.sh first"
            return 1
        fi
    }

    worker_exists() {
        local name="$1"
        for w in $MOCK_WORKER_EXISTS; do
            if [ "$w" = "$name" ]; then
                return 0
            fi
        done
        return 1
    }

    create() {
        local name="$1"
        local model="${2:-$DEFAULT_MODEL}"

        check_session || return 1

        if worker_exists "$name"; then
            echo "Error: Worker '$name' already exists"
            return 1
        fi

        local current=$(echo "$MOCK_WINDOWS_LIST" | grep -v "Manager" | wc -l | tr -d ' ')
        if [ "$current" -ge "$MAX_WORKERS" ]; then
            echo "Error: Max workers ($MAX_WORKERS) reached"
            return 1
        fi

        echo "✓ $name created ($model)"
    }

    send() {
        local worker="$1"
        shift

        check_session || return 1

        if ! worker_exists "$worker"; then
            echo "Error: Worker '$worker' not found"
            return 1
        fi

        echo "Command sent to $worker: $*"
    }

    send_all() {
        check_session || return 1

        local workers=$(echo "$MOCK_WINDOWS_LIST" | grep "Worker")
        for w in $workers; do
            echo "Command sent to $w: $*"
        done
    }

    read_screen() {
        check_session || return 1

        if ! worker_exists "$1"; then
            echo "Error: Worker '$1' not found"
            return 1
        fi

        echo "$TMUX_CAPTURE_OUTPUT"
    }

    dashboard() {
        check_session || return 1

        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║         MANAGER DASHBOARD                              ║"
        echo "║         $(date '+%Y-%m-%d %H:%M:%S')                            ║"
        echo "╠══════════════════════════════════════════════════════════╣"

        for name in $MOCK_WINDOWS_LIST; do
            echo "║  $name (uptime: 00:01:00)"
        done

        echo "╚══════════════════════════════════════════════════════════╝"
    }
}

# Test setup and teardown
setup() {
    MOCK_SESSION_EXISTS=true
    MOCK_WORKER_EXISTS=""
    MOCK_WINDOWS_LIST=""
    MOCK_WORKER_COUNT=0
    MOCK_MAX_WORKERS=5
    MOCK_DEFAULT_MODEL="test/model"
    TMUX_CAPTURE_OUTPUT=""
    source_manager
}

# ============================================================
# TEST: check_session
# ============================================================
test_check_session_found() {
    setup
    MOCK_SESSION_EXISTS=true
    local output
    output=$(check_session 2>&1)
    assert_exit_code "0" "$?" "check_session returns 0 when session exists"
}

test_check_session_not_found() {
    setup
    MOCK_SESSION_EXISTS=false
    local output
    output=$(check_session 2>&1)
    assert_exit_code "1" "$?" "check_session returns 1 when session not found"
    assert_contains "$output" "Error: Session" "check_session shows error message"
}

# ============================================================
# TEST: create
# ============================================================
test_create_success() {
    setup
    MOCK_WORKER_EXISTS=""
    MOCK_WINDOWS_LIST="Manager"
    local output
    output=$(create "Worker1" "test/model")
    assert_exit_code "0" "$?" "create returns 0 on success"
    assert_contains "$output" "✓ Worker1 created" "create shows success message"
}

test_create_default_model() {
    setup
    MOCK_WORKER_EXISTS=""
    MOCK_WINDOWS_LIST="Manager"
    local output
    output=$(create "Worker1")
    assert_exit_code "0" "$?" "create with default model returns 0"
    assert_contains "$output" "$MOCK_DEFAULT_MODEL" "create uses default model"
}

test_create_duplicate_worker() {
    setup
    MOCK_WORKER_EXISTS="Worker1"
    MOCK_WINDOWS_LIST="Manager Worker1"
    local output
    output=$(create "Worker1")
    assert_exit_code "1" "$?" "create returns 1 for duplicate worker"
    assert_contains "$output" "Error: Worker 'Worker1' already exists" "create shows duplicate error"
}

test_create_max_workers() {
    setup
    MOCK_WORKER_EXISTS="W1 W2 W3 W4 W5"
    MOCK_WINDOWS_LIST=$'Manager\nW1\nW2\nW3\nW4\nW5'
    MOCK_MAX_WORKERS=5
    local output
    output=$(create "Worker6")
    assert_exit_code "1" "$?" "create returns 1 when max workers reached"
    assert_contains "$output" "Error: Max workers (5) reached" "create shows max workers error"
}

test_create_no_session() {
    setup
    MOCK_SESSION_EXISTS=false
    local output
    output=$(create "Worker1")
    assert_exit_code "1" "$?" "create returns 1 when session not found"
    assert_contains "$output" "Error: Session" "create shows session error"
}

# ============================================================
# TEST: send
# ============================================================
test_send_success() {
    setup
    MOCK_WORKER_EXISTS="Worker1"
    local output
    output=$(send "Worker1" "hello" "world")
    assert_exit_code "0" "$?" "send returns 0 on success"
    assert_contains "$output" "Command sent to Worker1" "send shows command sent"
}

test_send_nonexistent_worker() {
    setup
    MOCK_WORKER_EXISTS=""
    local output
    output=$(send "Worker99" "hello")
    assert_exit_code "1" "$?" "send returns 1 for nonexistent worker"
    assert_contains "$output" "Error: Worker 'Worker99' not found" "send shows worker not found error"
}

test_send_no_session() {
    setup
    MOCK_SESSION_EXISTS=false
    local output
    output=$(send "Worker1" "hello")
    assert_exit_code "1" "$?" "send returns 1 when session not found"
    assert_contains "$output" "Error: Session" "send shows session error"
}

test_send_multiple_args() {
    setup
    MOCK_WORKER_EXISTS="Worker1"
    local output
    output=$(send "Worker1" "task1" "task2" "task3")
    assert_contains "$output" "task1 task2 task3" "send passes all arguments"
}

# ============================================================
# TEST: send_all
# ============================================================
test_send_all_success() {
    setup
    MOCK_WINDOWS_LIST="Manager Worker1 Worker2 Worker3"
    local output
    output=$(send_all "hello")
    assert_exit_code "0" "$?" "send_all returns 0 on success"
    assert_contains "$output" "Worker1" "send_all sends to Worker1"
    assert_contains "$output" "Worker2" "send_all sends to Worker2"
    assert_contains "$output" "Worker3" "send_all sends to Worker3"
}

test_send_all_no_workers() {
    setup
    MOCK_WINDOWS_LIST="Manager"
    local output
    output=$(send_all "hello")
    assert_exit_code "0" "$?" "send_all returns 0 when no workers"
    assert_not_eq "Worker1" "$output" "send_all sends to no workers"
}

test_send_all_no_session() {
    setup
    MOCK_SESSION_EXISTS=false
    local output
    output=$(send_all "hello")
    assert_exit_code "1" "$?" "send_all returns 1 when session not found"
    assert_contains "$output" "Error: Session" "send_all shows session error"
}

# ============================================================
# TEST: read_screen
# ============================================================
test_read_screen_success() {
    setup
    MOCK_WORKER_EXISTS="Worker1"
    TMUX_CAPTURE_OUTPUT="screen content here"
    local output
    output=$(read_screen "Worker1")
    assert_exit_code "0" "$?" "read_screen returns 0 on success"
    assert_contains "$output" "screen content here" "read_screen returns screen content"
}

test_read_screen_nonexistent_worker() {
    setup
    MOCK_WORKER_EXISTS=""
    local output
    output=$(read_screen "Worker99")
    assert_exit_code "1" "$?" "read_screen returns 1 for nonexistent worker"
    assert_contains "$output" "Error: Worker 'Worker99' not found" "read_screen shows worker not found error"
}

test_read_screen_no_session() {
    setup
    MOCK_SESSION_EXISTS=false
    local output
    output=$(read_screen "Worker1")
    assert_exit_code "1" "$?" "read_screen returns 1 when session not found"
    assert_contains "$output" "Error: Session" "read_screen shows session error"
}

# ============================================================
# TEST: dashboard
# ============================================================
test_dashboard_success() {
    setup
    MOCK_WINDOWS_LIST="Manager Worker1 Worker2"
    local output
    output=$(dashboard)
    assert_exit_code "0" "$?" "dashboard returns 0 on success"
    assert_contains "$output" "MANAGER DASHBOARD" "dashboard shows header"
    assert_contains "$output" "Worker1" "dashboard shows Worker1"
    assert_contains "$output" "Worker2" "dashboard shows Worker2"
}

test_dashboard_empty() {
    setup
    MOCK_WINDOWS_LIST="Manager"
    local output
    output=$(dashboard)
    assert_exit_code "0" "$?" "dashboard returns 0 with no workers"
    assert_contains "$output" "MANAGER DASHBOARD" "dashboard shows header"
}

test_dashboard_no_session() {
    setup
    MOCK_SESSION_EXISTS=false
    local output
    output=$(dashboard)
    assert_exit_code "1" "$?" "dashboard returns 1 when session not found"
    assert_contains "$output" "Error: Session" "dashboard shows session error"
}

# ============================================================
# Run all tests
# ============================================================
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW} Unit Tests for manager.sh${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

echo -e "${YELLOW}--- check_session tests ---${NC}"
test_check_session_found
test_check_session_not_found
echo ""

echo -e "${YELLOW}--- create tests ---${NC}"
test_create_success
test_create_default_model
test_create_duplicate_worker
test_create_max_workers
test_create_no_session
echo ""

echo -e "${YELLOW}--- send tests ---${NC}"
test_send_success
test_send_nonexistent_worker
test_send_no_session
test_send_multiple_args
echo ""

echo -e "${YELLOW}--- send_all tests ---${NC}"
test_send_all_success
test_send_all_no_workers
test_send_all_no_session
echo ""

echo -e "${YELLOW}--- read_screen tests ---${NC}"
test_read_screen_success
test_read_screen_nonexistent_worker
test_read_screen_no_session
echo ""

echo -e "${YELLOW}--- dashboard tests ---${NC}"
test_dashboard_success
test_dashboard_empty
test_dashboard_no_session
echo ""

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW} Test Results: $TESTS_RUN total, ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
echo -e "${YELLOW}========================================${NC}"

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
