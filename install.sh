#!/bin/bash
# Agent Teamwork — cài toàn cục vào ~/.config/opencode/
# Sau khi cài: mở opencode bất kỳ project nào → Tab → Manager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENDIR="$HOME/.config/opencode"

echo "Installing Agent Teamwork to $OPENDIR ..."

mkdir -p "$OPENDIR/plugins" "$OPENDIR/agents"
rm -f "$OPENDIR/plugins/agent-teamwork.js"  # remove old JS version

# Ensure plugin auto-loading + hide teamwork tools from non-manager agents.
# Global-deny the teamwork tool patterns (applies to build/plan/etc.); the
# manager agent re-allows them below → clean separation. opencode hides any
# tool whose last-matching permission is pattern:"*" action:"deny".
python3 -c "
import json, os
cfg = '$OPENDIR/opencode.json'
c = {}
if os.path.exists(cfg):
    with open(cfg) as f: c = json.load(f)
c.setdefault('\$schema', 'https://opencode.ai/config.json')
if c.get('plugin') == []: del c['plugin']
perm = c.get('permission') or {}
for p in ('worker_*', 'cal_*', 'task_*', 'scheduler_*', 'doc_*'):
    perm[p] = 'deny'
c['permission'] = perm
with open(cfg, 'w') as f: json.dump(c, f, indent=2)
" 2>/dev/null || true

# ── Plugin ───────────────────────────────────────────────
cp "$SCRIPT_DIR/opencode/plugins/agent-teamwork.ts" "$OPENDIR/plugins/"
echo "  ✓ plugin → $OPENDIR/plugins/agent-teamwork.ts"
cp "$SCRIPT_DIR/opencode/plugins/agent-teamwork-scheduler.ts" "$OPENDIR/plugins/"
echo "  ✓ scheduler plugin → $OPENDIR/plugins/agent-teamwork-scheduler.ts"

# ── Worker config ────────────────────────────────────────
cp "$SCRIPT_DIR/worker.json" "$OPENDIR/"
echo "  ✓ config → $OPENDIR/worker.json"

# ── Manager agent ────────────────────────────────────────
MGR="$SCRIPT_DIR/manager.json"
mgr_desc=$(jq -r '.description' "$MGR")
mgr_mode=$(jq -r '.mode' "$MGR")
mgr_model=$(jq -r '.model // empty' "$MGR")
mgr_prompt=$(jq -r '.prompt' "$MGR")

if [ -n "$mgr_model" ]; then
  model_line="model: $mgr_model"
else
  model_line=""
fi

cat > "$OPENDIR/agents/manager.md" <<AGENTEOF
---
description: $mgr_desc
mode: $mgr_mode
$model_line
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
  "worker_*": allow
  "cal_*": allow
  "task_*": allow
  "scheduler_*": allow
  "doc_*": allow
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