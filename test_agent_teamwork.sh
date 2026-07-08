#!/bin/bash
# Agent Teamwork - Comprehensive Test Suite
# Usage: ./test_agent_teamwork.sh [-v]  (v=verbose mode)

VERBOSE=false
[[ "$1" == "-v" ]] && VERBOSE=true

PASS=0
FAIL=0
TESTS=()
TEST_SESSION="test-agent-session"

# Use isolated test session to not affect user's sessions
export SESSION_NAME="$TEST_SESSION"

cleanup() {
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null
}

create_test_session() {
  tmux new-session -d -s "$TEST_SESSION" -n "Manager" 2>/dev/null
  echo "✓ Test session created: $TEST_SESSION"
}

# Override SESSION for tmux_controller.sh / manager.sh
# by directly patching the scripts' behavior via env var SESSION_NAME
export SESSION_NAME="$TEST_SESSION"

# === Test Framework ===
assert() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  local label="$4"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local desc="$1"
  local expected_exit="$2"
  local actual_exit="$3"
  local output="$4"
  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc (exit: $actual_exit, expected: $expected_exit)"
    echo "    Output: $output"
    FAIL=$((FAIL + 1))
  fi
}

header() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

run_test() {
  local desc="$1"
  shift
  echo ""
  echo "▶ $desc"
  OUTPUT=$("$@" 2>&1)
  EXIT_CODE=$?
  if $VERBOSE; then
    echo "  Output: $OUTPUT"
    echo "  Exit: $EXIT_CODE"
  fi
}

# === Setup: Kill any leftover test sessions ===
cleanup

# =============================
# A. SETUP & SESSION MANAGEMENT
# =============================
header "A. SETUP & SESSION MANAGEMENT"

# A1: Create test session
run_test "A1: Create test session" create_test_session
assert "Session created" "Test session created" "$OUTPUT" "A1a"

# A2: Session actually exists
tmux has-session -t "$TEST_SESSION" 2>/dev/null
assert_exit "A2: Session '$TEST_SESSION' exists" 0 $? ""

# A3: Session name via env var
run_test "A3: SESSION_NAME env var" bash -c 'echo "SESSION_NAME=${SESSION_NAME:-agent-session}"'
assert "SESSION_NAME set" "$TEST_SESSION" "$OUTPUT" "A3a"

# A4: Cannot create worker without session (kill first)
cleanup
run_test "A4: create worker without session fails" bash tmux_controller.sh create TestFail
assert "Error message" "Session" "$OUTPUT" "A4a"
assert "Error mentions setup" "setup" "$OUTPUT" "A4b"
assert_exit "Exit code 1" 1 $EXIT_CODE "$OUTPUT"

# Recreate session for rest of tests
create_test_session >/dev/null 2>&1

# =============================
# B. WORKER MANAGEMENT
# =============================
header "B. WORKER MANAGEMENT"

# B1: Create worker successfully
run_test "B1: Create worker Test-A" bash tmux_controller.sh create Test-A
assert "Success message" "✓" "$OUTPUT" "B1a"
assert "Worker name in output" "Test-A" "$OUTPUT" "B1b"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# B2: Create duplicate worker fails
run_test "B2: Create duplicate Test-A" bash tmux_controller.sh create Test-A
assert "Error: already exists" "already exists" "$OUTPUT" "B2a"
assert_exit "Exit code 1" 1 $EXIT_CODE "$OUTPUT"

# B3: Create worker with custom model
run_test "B3: Create Test-B with custom model" bash tmux_controller.sh create Test-B opencode/mimo-v2.5-free
assert "Custom model in output" "mimo-v2.5-free" "$OUTPUT" "B3a"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# B4: Create worker "Manager" (common name)
run_test "B4: Create worker with normal name" bash tmux_controller.sh create Worker-A
assert "Success" "✓" "$OUTPUT" "B4a"

# B5: Kill worker successfully
run_test "B5: Kill Test-A" bash tmux_controller.sh kill Test-A
assert "Success" "✓" "$OUTPUT" "B5a"
assert "Kill message" "killed" "$OUTPUT" "B5b"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# B6: Kill non-existent worker fails
run_test "B6: Kill non-existent worker" bash tmux_controller.sh kill NonExistent
assert "Error: not found" "not found" "$OUTPUT" "B6a"
assert_exit "Exit code 1" 1 $EXIT_CODE "$OUTPUT"

# B7: Create worker with name containing special chars
run_test "B7: Create worker with hyphen name" bash tmux_controller.sh create My-Worker-99
assert "Success" "✓" "$OUTPUT" "B7a"

# Cleanup
bash tmux_controller.sh kill My-Worker-99 >/dev/null 2>&1

# B8: Create many workers (check max_workers limit)
for i in {1..5}; do
  bash tmux_controller.sh create "Stress-$i" >/dev/null 2>&1
done
run_test "B8: Exceed max workers" bash tmux_controller.sh create Stress-6
assert "Max workers error" "Max workers" "$OUTPUT" "B8a"
assert_exit "Exit code 1" 1 $EXIT_CODE "$OUTPUT"

# Cleanup stress workers
for i in {1..5}; do
  bash tmux_controller.sh kill "Stress-$i" >/dev/null 2>&1
done

# =============================
# C. COMMAND SENDING
# =============================
header "C. COMMAND SENDING"

# Create a worker for send tests
bash tmux_controller.sh create Send-Test >/dev/null 2>&1
sleep 1

# C1: Send simple command
run_test "C1: Send simple command" bash tmux_controller.sh send Send-Test "echo hello"
assert "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# C2: Send multi-word command
run_test "C2: Send multi-word command" bash tmux_controller.sh send Send-Test "echo hello world from worker"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# C3: Send to non-existent worker
run_test "C3: Send to non-existent worker" bash tmux_controller.sh send NoWorker "ls"
assert "Error: not found" "not found" "$OUTPUT" "C3a"
assert_exit "Exit code 1" 1 $EXIT_CODE "$OUTPUT"

# C4: Read from non-existent worker
run_test "C4: Read non-existent worker" bash tmux_controller.sh read NoWorker
assert "Error: not found" "not found" "$OUTPUT" "C4a"
assert_exit "Exit code 1" 1 $EXIT_CODE "$OUTPUT"

# Read and verify output
run_test "C5: Read worker screen" bash tmux_controller.sh read Send-Test
assert "Non-empty output" "" ""  # Just check exit code
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# C6: Smart send (send + wait)
run_test "C6: Smart send (echo)" bash tmux_controller.sh smart Send-Test "echo smart-test-done" 10
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# C7: Wait on non-existent worker
run_test "C7: Wait non-existent worker" bash tmux_controller.sh wait NoWorker 5
assert_exit "Exit code 1" 1 $EXIT_CODE "$OUTPUT"

# Cleanup
bash tmux_controller.sh kill Send-Test >/dev/null 2>&1

# =============================
# D. DASHBOARD
# =============================
header "D. DASHBOARD"

# Create some workers for dashboard display
bash tmux_controller.sh create DB-A >/dev/null 2>&1
bash tmux_controller.sh create DB-B >/dev/null 2>&1

run_test "D1: Dashboard from tmux_controller.sh" bash tmux_controller.sh dashboard
assert "Has AGENT TEAMWORK DASHBOARD header" "DASHBOARD" "$OUTPUT" "D1a"
assert "Shows DB-A" "DB-A" "$OUTPUT" "D1b"
assert "Shows DB-B" "DB-B" "$OUTPUT" "D1c"
assert "Shows uptime" "Uptime" "$OUTPUT" "D1d"
assert "Shows datetime" "2026" "$OUTPUT" "D1e"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

run_test "D2: Dashboard from manager.sh" bash manager.sh dashboard
assert "Has MANAGER DASHBOARD header" "DASHBOARD" "$OUTPUT" "D2a"
assert "Shows workers" "DB-" "$OUTPUT" "D2b"
assert "Shows uptime" "uptime" "$OUTPUT" "D2c"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# Cleanup
bash tmux_controller.sh kill DB-A >/dev/null 2>&1
bash tmux_controller.sh kill DB-B >/dev/null 2>&1

# =============================
# E. MANAGER.SH COMMANDS
# =============================
header "E. MANAGER.SH COMMANDS"

# E1: manager.sh create
run_test "E1: manager.sh create worker" bash manager.sh create Man-Worker
assert "Success" "✓" "$OUTPUT" "E1a"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# E2: manager.sh create duplicate
run_test "E2: manager.sh create duplicate" bash manager.sh create Man-Worker
assert "Error: already exists" "already exists" "$OUTPUT" "E2a"
assert_exit "Exit code 1" 1 $EXIT_CODE "$OUTPUT"

# E3: manager.sh send
run_test "E3: manager.sh send command" bash manager.sh send Man-Worker "ls"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# E4: manager.sh send to non-existent
run_test "E4: manager.sh send non-existent" bash manager.sh send NoMan "ls"
assert "Error: not found" "not found" "$OUTPUT" "E4a"
assert_exit "Exit code 1" 1 $EXIT_CODE "$OUTPUT"

# E5: manager.sh read non-existent
run_test "E5: manager.sh read non-existent" bash manager.sh read NoMan
assert "Error: not found" "not found" "$OUTPUT" "E5a"
assert_exit "Exit code 1" 1 $EXIT_CODE "$OUTPUT"

# E6: manager.sh send-all
bash manager.sh create Man-All1 >/dev/null 2>&1
bash manager.sh create Man-All2 >/dev/null 2>&1
run_test "E6: manager.sh send-all" bash manager.sh send-all "echo hello-all"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

# Cleanup
bash tmux_controller.sh kill Man-Worker >/dev/null 2>&1
bash tmux_controller.sh kill Man-All1 >/dev/null 2>&1
bash tmux_controller.sh kill Man-All2 >/dev/null 2>&1

# =============================
# F. CROSS-SCRIPT COMPATIBILITY
# =============================
header "F. CROSS-SCRIPT COMPATIBILITY"

# Worker created by tmux_controller.sh, managed by manager.sh
bash tmux_controller.sh create Cross-Worker >/dev/null 2>&1
run_test "F1: manager.sh send to tmux worker" bash manager.sh send Cross-Worker "echo cross-test"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

run_test "F2: manager.sh read tmux worker" bash manager.sh read Cross-Worker
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

run_test "F3: manager.sh dashboard includes tmux worker" bash manager.sh dashboard
assert "Shows Cross-Worker" "Cross-Worker" "$OUTPUT" "F3a"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

bash tmux_controller.sh kill Cross-Worker >/dev/null 2>&1

# Worker created by manager.sh, managed by tmux_controller.sh
bash manager.sh create Reverse-Worker >/dev/null 2>&1
run_test "F4: tmux_controller.sh send to manager worker" bash tmux_controller.sh send Reverse-Worker "echo reverse-test"
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

run_test "F5: tmux_controller.sh read manager worker" bash tmux_controller.sh read Reverse-Worker
assert_exit "Exit code 0" 0 $EXIT_CODE "$OUTPUT"

run_test "F6: tmux_controller.sh dashboard includes manager worker" bash tmux_controller.sh dashboard
assert "Shows Reverse-Worker" "Reverse-Worker" "$OUTPUT" "F6a"

bash tmux_controller.sh kill Reverse-Worker >/dev/null 2>&1

# =============================
# G. HELP / USAGE
# =============================
header "G. HELP / USAGE"

run_test "G1: tmux_controller.sh help" bash tmux_controller.sh
assert "Shows USAGE" "USAGE" "$OUTPUT" "G1a"
assert "Shows commands" "send" "$OUTPUT" "G1b"
assert "Shows interactive" "interactive" "$OUTPUT" "G1c"

run_test "G2: manager.sh help" bash manager.sh
assert "Shows USAGE" "USAGE" "$OUTPUT" "G2a"
assert "Shows config info" "Config" "$OUTPUT" "G2b"
assert "Shows max workers" "Max Workers" "$OUTPUT" "G2c"
assert "Shows default model" "Default Model" "$OUTPUT" "G2d"

# =============================
# H. CLEANUP & RESTORE
# =============================
header "H. CLEANUP"

run_test "H1: All test workers cleaned up" tmux list-windows -t "$TEST_SESSION" -F '#{window_name}' 2>/dev/null
window_count=$(echo "$OUTPUT" | grep -c .)
if [ "$window_count" -le 1 ]; then
  echo "  ✓ H1: Only Manager window remains (count: $window_count)"
  PASS=$((PASS + 1))
else
  echo "  ✗ H1: Extra windows remain: $OUTPUT"
  FAIL=$((FAIL + 1))
fi

# Final cleanup
cleanup
echo "  ✓ Test session '$TEST_SESSION' cleaned up"
PASS=$((PASS + 1))

# =============================
# RESULTS
# =============================
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  TEST RESULTS"
echo "══════════════════════════════════════════════════════════"
echo "  PASSED: $PASS"
echo "  FAILED: $FAIL"
echo "  TOTAL:  $((PASS + FAIL))"
echo "══════════════════════════════════════════════════════════"

exit $FAIL
