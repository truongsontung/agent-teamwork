#!/bin/bash
# Agent Teamwork - Comprehensive Test Suite
# Usage: ./test_agent_teamwork.sh [-v]

VERBOSE=false; [[ "$1" == "-v" ]] && VERBOSE=true
PASS=0; FAIL=0; S="test-agent-session"
export SESSION_NAME="$S"
DIR="$(cd "$(dirname "$0")" && pwd)"
TC() { bash "$DIR/tmux_controller.sh" "$@"; }
MG() { bash "$DIR/manager.sh" "$@"; }

assert() { local d="$1" e="$2" a="$3"
  if [[ "$a" == *"$e"* ]]; then echo "  ✓ $d"; PASS=$((PASS+1))
  else echo "  ✗ $d (expected: $e, got: ${a:0:60})"; FAIL=$((FAIL+1)); fi
}
assert_exit() { local d="$1" e="$2" a="$3"
  if [ "$a" -eq "$e" ]; then echo "  ✓ $d"; PASS=$((PASS+1))
  else echo "  ✗ $d (exit: $a, expected: $e)"; FAIL=$((FAIL+1)); fi
}
header() { echo -e "\n━━━ $1 ━━━"; }
run() { echo -e "\n▶ $1"; shift; OUTPUT=$("$@" 2>&1); EXIT_CODE=$?; $VERBOSE && echo "  → $(echo "$OUTPUT" | head -3)"; }

tmux kill-session -t "$S" 2>/dev/null
tmux new-session -d -s "$S" -n "Manager"

# === A: SETUP ===
header "A. SETUP"
tmux has-session -t "$S" 2>/dev/null; assert_exit "Session created" 0 $?
run "SESSION_NAME env" bash -c 'echo "${SESSION_NAME:-unset}"'; assert "Env set" "$S" "$OUTPUT"
tmux kill-session -t "$S" 2>/dev/null
run "No session error" TC create X; assert "Error" "Session" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE
tmux new-session -d -s "$S" -n "Manager"

# === B: WORKER MANAGEMENT ===
header "B. WORKER MANAGEMENT"
run "B1: Create worker" TC create Test-A; assert "✓" "✓" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE
run "B2: Duplicate" TC create Test-A; assert "Error" "already exists" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE
run "B3: Custom model" TC create Test-B opencode/mimo-v2.5-free; assert "Custom model" "mimo" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE
for i in 1 2 3; do TC create "S-$i" >/dev/null 2>&1; done
run "B4: Max workers" TC create S-4; assert "Max error" "Max workers" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE
run "B5: Kill" TC kill Test-A; assert "✓" "✓" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE
run "B6: Kill non-existent" TC kill NoWorker; assert "Error" "not found" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE
for w in Test-B S-1 S-2 S-3; do TC kill "$w" >/dev/null 2>&1; done

# === C: COMMAND SENDING ===
header "C. COMMAND SENDING"
TC create Send-Test >/dev/null 2>&1
run "C1: Send" TC send Send-Test "echo hello"; assert_exit "Exit 0" 0 $EXIT_CODE
run "C2: Multi-word" TC send Send-Test "echo hello world from worker"; assert_exit "Exit 0" 0 $EXIT_CODE
run "C3: Send non-existent" TC send NoWorker "ls"; assert "Error" "not found" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE
run "C4: Read non-existent" TC read NoWorker; assert "Error" "not found" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE
run "C5: Read screen" TC read Send-Test; assert_exit "Exit 0" 0 $EXIT_CODE
run "C6: Smart send" TC smart Send-Test "echo smart-test-done" 10; assert_exit "Smart OK" 0 $EXIT_CODE
run "C7: Wait non-existent" TC wait NoWorker 5; assert_exit "Wait err" 1 $EXIT_CODE
TC kill Send-Test >/dev/null 2>&1

# === D: DASHBOARD ===
header "D. DASHBOARD"
TC create Dash-A >/dev/null 2>&1; TC create Dash-B >/dev/null 2>&1
run "D1: Dashboard TC" TC dashboard
assert "Header" "DASHBOARD" "$OUTPUT"; assert "A" "Dash-A" "$OUTPUT"; assert "B" "Dash-B" "$OUTPUT"
assert "Uptime" "Uptime" "$OUTPUT"; assert "Year" "2026" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE
run "D2: Dashboard MG" MG dashboard
assert "Header" "DASHBOARD" "$OUTPUT"; assert "Workers" "Dash-" "$OUTPUT"; assert "Uptime" "uptime" "$OUTPUT"
TC kill Dash-A >/dev/null 2>&1; TC kill Dash-B >/dev/null 2>&1

# === E: MANAGER.SH ===
header "E. MANAGER.SH"
run "E1: create" MG create M-Worker; assert "✓" "✓" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE
run "E2: duplicate" MG create M-Worker; assert "Error" "already exists" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE
run "E3: send" MG send M-Worker "ls"; assert_exit "Exit 0" 0 $EXIT_CODE
run "E4: send non-existent" MG send NoMan "ls"; assert "Error" "not found" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE
run "E5: read non-existent" MG read NoMan; assert "Error" "not found" "$OUTPUT"; assert_exit "Exit 1" 1 $EXIT_CODE
MG create M-All1 >/dev/null 2>&1; MG create M-All2 >/dev/null 2>&1
run "E6: send-all" MG send-all "echo hello-all"; assert_exit "Exit 0" 0 $EXIT_CODE
for w in M-Worker M-All1 M-All2; do TC kill "$w" >/dev/null 2>&1; done

# === F: CROSS-SCRIPT ===
header "F. CROSS-SCRIPT"
TC create Cross-W >/dev/null 2>&1
run "F1: MG send to TC worker" MG send Cross-W "echo cross"; assert_exit "Exit 0" 0 $EXIT_CODE
run "F2: MG read TC worker" MG read Cross-W; assert_exit "Exit 0" 0 $EXIT_CODE
run "F3: MG dash" MG dashboard; assert "Shows Cross-W" "Cross-W" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE
TC kill Cross-W >/dev/null 2>&1
MG create Rev-W >/dev/null 2>&1
run "F4: TC send to MG worker" TC send Rev-W "echo rev"; assert_exit "Exit 0" 0 $EXIT_CODE
run "F5: TC read MG worker" TC read Rev-W; assert_exit "Exit 0" 0 $EXIT_CODE
run "F6: TC dash" TC dashboard; assert "Shows Rev-W" "Rev-W" "$OUTPUT"; assert_exit "Exit 0" 0 $EXIT_CODE
TC kill Rev-W >/dev/null 2>&1

# === G: HELP ===
header "G. HELP"
run "G1: TC help" TC; assert "USAGE" "USAGE" "$OUTPUT"
run "G2: MG help" MG; assert "USAGE" "USAGE" "$OUTPUT"

# === H: CLEANUP ===
header "H. CLEANUP"
echo -e "\n▶ H1: Check remaining"
REMAINING=$(tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null | grep -vc "Manager")
echo "  Non-Manager windows: $REMAINING"
if [ "$REMAINING" -eq 0 ]; then echo "  ✓ H1: Only Manager remains"; PASS=$((PASS+1))
else echo "  ✗ H1: Leftovers: $(tmux list-windows -t "$S" -F '#{window_name}' 2>/dev/null | grep -v Manager | tr '\n' ' ')"; FAIL=$((FAIL+1)); fi
tmux kill-session -t "$S" 2>/dev/null; echo "  ✓ Cleaned up"; PASS=$((PASS+1))

# === RESULTS ===
echo -e "\n═══════ RESULTS ═══════"
echo "  PASSED: $PASS | FAILED: $FAIL | TOTAL: $((PASS+FAIL))"
exit $FAIL
