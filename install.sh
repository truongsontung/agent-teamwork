#!/bin/bash
# Agent Teamwork — cài toàn cục vào ~/.config/opencode/
# Sau khi cài: mở opencode bất kỳ project nào → Tab → Manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENDIR="$HOME/.config/opencode"

echo "Installing Agent Teamwork to $OPENDIR ..."

mkdir -p "$OPENDIR/plugins" "$OPENDIR/agents"

# ── Plugin ───────────────────────────────────────────────
cp "$SCRIPT_DIR/opencode/plugins/agent-teamwork.ts" "$OPENDIR/plugins/"
echo "  ✓ plugin → $OPENDIR/plugins/agent-teamwork.ts"

# ── Worker config ────────────────────────────────────────
cp "$SCRIPT_DIR/worker.json" "$OPENDIR/"
echo "  ✓ config → $OPENDIR/worker.json"

# ── Manager agent ────────────────────────────────────────

MGR="$SCRIPT_DIR/manager.json"
mgr_desc=$(jq -r '.description' "$MGR")
mgr_mode=$(jq -r '.mode' "$MGR")
mgr_model=$(jq -r '.model' "$MGR")
mgr_prompt=$(jq -r '.prompt' "$MGR")

cat > "$OPENDIR/agents/manager.md" <<AGENTEOF
---
description: $mgr_desc
mode: $mgr_mode
model: $mgr_model
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
  bash: deny
---

$mgr_prompt
AGENTEOF
echo "  ✓ agent → $OPENDIR/agents/manager.md"

echo ""
echo "Done. Mở opencode → Tab để chuyển sang Manager."
echo ""
echo "Cấu hình:"
echo "  Manager model: $OPENDIR/agents/manager.md  (sửa dòng model)"
echo "  Worker config: $OPENDIR/worker.json        (model, permission)"
echo "  Plugin code:   $OPENDIR/plugins/agent-teamwork.ts"
