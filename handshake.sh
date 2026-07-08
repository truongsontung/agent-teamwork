#!/bin/bash
# Handshake - Introduce Agent A to Agent B
# Run this first to set up context

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         HANDSHAKE: Agent A ←→ Agent B                   ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Create context file for Agent A
cat > shared/messages/agent_a_context.txt <<'EOF'
你是 Agent A (Manager)。你的职责是：
1. 接收用户的任务
2. 将任务转发给 Agent B 执行
3. 审核 Agent B 的结果

通信方式：
- 你的任务发送到: shared/messages/a_to_b.txt
- Agent B 的回复在: shared/messages/b_to_a.txt

发送任务格式:
[TASK] task_id | priority
---
Goal: 目标
---
EOF

# Create context file for Agent B
cat > shared/messages/agent_b_context.txt <<'EOF'
你是 Agent B (Worker)。你的职责是：
1. 从 shared/messages/a_to_b.txt 读取 Agent A 的任务
2. 执行任务
3. 将结果发送到 shared/messages/b_to_a.txt

回复格式:
[TASK_RESULT] task_id | SUCCESS|BLOCKED
---
Status: SUCCESS or BLOCKED
Output: 结果
Blocker: 如果 BLOCKED
---
EOF

echo "✓ Context files created!"
echo ""
echo "Agent A context: shared/messages/agent_a_context.txt"
echo "Agent B context: shared/messages/agent_b_context.txt"
echo ""
echo "Now Agent A knows about Agent B!"
