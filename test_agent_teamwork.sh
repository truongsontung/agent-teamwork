#!/bin/bash
# Agent Teamwork - Comprehensive Test Suite

VERBOSE=false; [[ "$1" == "-v" ]] && VERBOSE=true
PASS=0; FAIL=0
TEST_SESSION="test-agent-session"
export SESSION_NAME="$TEST_SESSION"

cleanup() { tmux kill-session -t "$TEST_SESSION" 2>/dev/null; }
create_session() { tmux new-session -d -s "$TEST_SESSION" -n "Manager"; }

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  ✓ $desc"; PASS=$((PASS+1))
  else
    echo "  ✗ $desc (expected: $expected, got: ${actual:0:60})"; FAIL=$((FAIL+1))
  fi
}

assert_exit() {
  local desc="$1" exp="$2" act="$3"
  if [ "$act" -eq "$exp" ]; then
    echo "  ✓ $desc"; PASS=$((PASS+1))
  else
    echo "  ✗ $desc (exit: $act, expected: $exp)"; FAIL=$((FAIL+1))
  fi
}

header() { echo -e "\n━━━ $1 ━━━"; }

run() {
  echo -e "\n▶ $1"; shift
  OUTPUT=$("$@" 2>&1); EXIT_CODE=$?
  $VERBOSE && echo "  → $OUTPUT"
}

# === SETUP ===
header "A. SETUP & SESSION"
cleanup
run "A1: Create session" create_session
assert "Session created" "Manager" "$OUTPUT"
tmux has-session -t "$TEST_SESSION" 2>/dev/null
assert_exit "A2: Session exists" 0 $?

run "A3: SESSION_NAME env" bash -c 'echo "${SESSION_NAME:-unset}"'
assert "SESSION_NAME set" "$TEST_SESSION" "$OUTPUT"

cleanup
run "A4: No session error" bash tmux_controller.sh create X
assert "Error: Session not found" "Session" "$OUTPUT"
assert_exit "Exit 1" 1 $EXIT_CODE
create_session >/dev/null

# === WORKER MANAGEMENT ===
header "B. WORKER MANAGEMENT"
run "B1: Create worker" bash tmux_controller.sh create Test-A
assert "Created ✓" "✓" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE

run "B2: Duplicate" bash tmux_controller.sh create Test-A
assert "Error: exists" "already exists" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE

run "B3: Custom model" bash tmux_controller.sh create Test-B opencode/mimo-v2.5-free
assert "Custom model" "mimo-v2.5-free" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE

run "B4: Max workers" bash -c '
  for i in $(seq 1 5); do tmux_controller.sh create "S-$i"; done >/dev/null 2>&1
  tmux_controller.sh create S-6
'
assert "Max workers error" "Max workers" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE

run "B5: Kill" bash tmux_controller.sh kill Test-A
assert "Killed ✓" "✓" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE

run "B6: Kill non-existent" bash tmux_controller.sh kill NoWorker
assert "Error: not found" "not found" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE

# Cleanup B
for w in Test-B S-1 S-2 S-3 S-4 S-5; do tmux_controller.sh kill "$w" >/dev/null 2>&1; done

# === COMMAND SENDING ===
header "C. COMMAND SENDING"
bash tmux_controller.sh create Send-Test >/dev/null 2>&1; sleep 1

run "C1: Send" bash tmux_controller.sh send Send-Test "echo hello"
assert_exit "Exit 0" 0 $EXIT_CODE

run "C2: Multi-word" bash tmux_controller.sh send Send-Test "echo hello world from worker"
assert_exit "Exit 0" 0 $EXIT_CODE

run "C3: Send non-existent" bash tmux_controller.sh send NoWorker "ls"
assert "Error: not found" "not found" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE

run "C4: Read non-existent" bash tmux_controller.sh read NoWorker
assert "Error: not found" "not found" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE

run "C5: Read screen" bash tmux_controller.sh read Send-Test
assert_exit "Exit 0" 0 $EXIT_CODE

run "C6: Smart send" bash tmux_controller.sh smart Send-Test "echo smart-test-done" 10
assert_exit "Smart OK" 0 $EXIT_CODE

run "C7: Wait non-existent" bash tmux_controller.sh wait NoWorker 5
assert_exit "Wait non-existent error" 1 $EXIT_CODE

bash tmux_controller.sh kill Send-Test >/dev/null 2>&1

# === DASHBOARD ===
header "D. DASHBOARD"
bash tmux_controller.sh create Dash-A >/dev/null 2>&1
bash tmux_controller.sh create Dash-B >/dev/null 2>&1

run "D1: Dashboard tmux_controller" bash tmux_controller.sh dashboard
assert "Has header" "DASHBOARD" "$OUTPUT"
assert "Shows Dash-A" "Dash-A" "$OUTPUT"
assert "Shows Dash-B" "Dash-B" "$OUTPUT"
assert "Shows uptime" "Uptime" "$OUTPUT"
assert "Shows year" "2026" "$OUTPUT"
assert_exit "Exit 0" 0 $EXIT_CODE

run "D2: Dashboard manager.sh" bash manager.sh dashboard
assert "Header" "DASHBOARD" "$OUTPUT"
assert "Shows workers" "Dash-" "$OUTPUT"
assert "Uptime" "uptime" "$OUTPUT"
assert_exit "Exit 0" 0 $EXIT_CODE

bash tmux_controller.sh kill Dash-A >/dev/null 2>&1
bash tmux_controller.sh kill Dash-B >/dev/null 2>&1

# === MANAGER.SH ===
header "E. MANAGER.SH"
run "E1: manager create" bash manager.sh create M-Worker
assert "Created ✓" "✓" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE

run "E2: manager duplicate" bash manager.sh create M-Worker
assert "Error: exists" "already exists" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE

run "E3: manager send" bash manager.sh send M-Worker "ls"
assert_exit "Exit 0" 0 $EXIT_CODE

run "E4: manager send non-existent" bash manager.sh send NoMan "ls"
assert "Error: not found" "not found" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE

run "E5: manager read non-existent" bash manager.sh read NoMan
assert "Error: not found" "not found" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE

bash manager.sh create M-All1 >/dev/null 2>&1; bash manager.sh create M-All2 >/dev/null 2>&1
run "E6: manager send-all" bash manager.sh send-all "echo hello-all"
assert_exit "Exit 0" 0 $EXIT_CODE

for w in M-Worker M-All1 M-All2; do tmux_controller.sh kill "$w" >/dev/null 2>&1; done

# === CROSS-SCRIPT ===
header "F. CROSS-SCRIPT"
bash tmux_controller.sh create Cross-W >/dev/null 2>&1
run "F1: manager send to tmux worker" bash manager.sh send Cross-W "echo cross"
assert_exit "Exit 0" 0 $EXIT_CODE
run "F2: manager read tmux worker" bash manager.sh read Cross-W
assert_exit "Exit 0" 0 $EXIT_CODE
run "F3: manager dash" bash manager.sh dashboard
assert "Shows Cross-W" "Cross-W" "$OUTPUT"
bash tmux_controller.sh kill Cross-W >/dev/null 2>&1

bash manager.sh create Rev-W >/dev/null 2>&1
run "F4: tmux send to manager worker" bash tmux_controller.sh send Rev-W "echo rev"
assert_exit "Exit 0" 0 $EXIT_CODE
run "F5: tmux read manager worker" bash tmux_controller.sh read Rev-W
assert_exit "Exit 0" 0 $EXIT_CODE
run "F6: tmux dash" bash tmux_controller.sh dashboard
assert "Shows Rev-W" "Rev-W" "$OUTPUT"
bash tmux_controller.sh kill Rev-W >/dev/null 2>&1

# === HELP ===
header "G. HELP"
run "G1: tmux help" bash tmux_controller.sh; assert "USAGE" "USAGE" "$OUTPUT"
run "G2: manager help" bash manager.sh; assert "USAGE" "USAGE" "$OUTPUT"

# === CLEANUP ===
header "H. CLEANUP"
run "H1: All workers cleaned" tmux list-windows -t "$TEST_SESSION" -F '#{window_name}' 2>/dev/null | grep -v "Manager"
if [ -z "$OUTPUT" ]; then echo "  ✓ H1: Only Manager remains"; PASS=$((PASS+1))
else echo "  ✗ H1: Extra windows: $OUTPUT"; FAIL=$((FAIL+1)); fi

cleanup; echo "  ✓ Test session cleaned"; PASS=$((PASS+1))

# === RESULTS ===
echo -e "\n═══════ RESULTS ═══════"
echo "  PASSED: $PASS | FAILED: $FAIL | TOTAL: $((PASS+FAIL))"
exit $FAIL
