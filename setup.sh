#!/bin/bash
# Agent Teamwork — 1 lệnh, không tmux, không bot riêng
# Plugin native quản lý toàn bộ worker + SSE + event injection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

export AGENT_TEAMWORK_HOME="$SCRIPT_DIR"
export PROJECT_DIR

MGR="$SCRIPT_DIR/manager.json"
WK="$SCRIPT_DIR/worker.json"

mgr_tool=$(jq -r '.tool' "$MGR")
mgr_model=$(jq -r '.model' "$MGR")
mgr_desc=$(jq -r '.description' "$MGR")
mgr_mode=$(jq -r '.mode' "$MGR")
mgr_prompt=$(jq -r '.prompt' "$MGR")

# ── Copy plugin to project ──────────────────────────────

mkdir -p "$PROJECT_DIR/.opencode/plugins"
cp "$SCRIPT_DIR/opencode/plugins/agent-teamwork.ts" "$PROJECT_DIR/.opencode/plugins/"

# ── Write Manager agent ─────────────────────────────────

mkdir -p "$PROJECT_DIR/.opencode/agents"
cat > "$PROJECT_DIR/.opencode/agents/manager.md" <<AGENTEOF
---
description: $mgr_desc
mode: $mgr_mode
permission:
  read: deny
  edit: deny
  write: deny
  glob: deny
  grep: deny
  task: deny
  webfetch: deny
  websearch: deny
  question: deny
  bash: allow
---

$mgr_prompt
AGENTEOF

# Worker.md stub
wk_desc=$(jq -r '.description' "$WK")
wk_mode=$(jq -r '.mode' "$WK")
wk_prompt=$(jq -r '.prompt' "$WK")
cat > "$PROJECT_DIR/.opencode/agents/worker.md" <<AGENTEOF
---
description: $wk_desc
mode: $wk_mode
---

$wk_prompt
AGENTEOF

# ── Dọn dẹp ─────────────────────────────────────────────

rm -rf "$PROJECT_DIR/.worker" "$PROJECT_DIR/agent" 2>/dev/null

cleanup() {
    rm -rf "$PROJECT_DIR/.worker" "$PROJECT_DIR/agent" 2>/dev/null
    rm -f "$PROJECT_DIR/.opencode/agents/manager.md" "$PROJECT_DIR/.opencode/agents/worker.md" 2>/dev/null
    rm -f "$PROJECT_DIR/.opencode/plugins/agent-teamwork.ts" 2>/dev/null
    exit 0
}
trap cleanup INT TERM EXIT

# ── Launch Manager TUI ──────────────────────────────────

cd "$PROJECT_DIR"
exec $mgr_tool --model $mgr_model --agent manager
