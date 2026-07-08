# Hướng dẫn cài đặt & Chạy Hệ thống Agent

## Bước 1: Cài đặt dependencies

```bash
# Cài jq (cần cho config)
sudo apt install jq -y

# Kiểm tra opencode và mimo đã cài chưa
which opencode mimo
```

## Bước 2: Vào thư mục

```bash
cd /home/vps2/mimo/tmux-agent
```

## Bước 3: Cấu hình agents

```bash
# Xem config hiện tại
cat config.json

# Sửa config theo ý bạn
vim config.json
```

### Config mẫu

```json
{
  "session_name": "agent-session",
  "agents": {
    "A": {
      "name": "Manager",
      "tool": "opencode",
      "model": "opencode/gpt-5.5",
      "mode": "plan"
    },
    "B": {
      "name": "Worker",
      "tool": "mimo",
      "model": "mimo/mimo-v2.5-pro",
      "mode": "build"
    }
  }
}
```

### Các model có sẵn

| Tool | Models |
|------|--------|
| opencode | `opencode/gpt-5.5`, `opencode/claude-opus-4-8`, `opencode/deepseek-v4-flash` |
| mimo | `mimo/mimo-v2.5-pro`, `mimo/mimo-v2.5-free`, `mimo/mimo-auto` |

## Bước 4: Cấu hình Permission

```bash
# Chế độ tự động (không cần human)
./perm.sh auto

# Hoặc chế độ an toàn (cần human cho .env)
./perm.sh secure
```

### Quy tắc Permission

| Chế độ | Auto-approve | Auto-deny | Cần human |
|--------|--------------|-----------|-----------|
| FULL_AUTO | *.md, *.json, .env, src/* | *.key, *.pem | Không có |
| SECURE | *.md, *.json, src/* | *.key, *.pem | .env, *token* |

## Bước 5: Khởi động hệ thống

```bash
./start.sh
```

Output:
```
╔══════════════════════════════════════════════════════════╗
║         Starting Agent System                          ║
╚══════════════════════════════════════════════════════════╝

Agent A:
  Tool: opencode
  Model: opencode/gpt-5.5
  Mode: plan

Agent B:
  Tool: mimo
  Model: mimo/mimo-v2.5-pro
  Mode: build

✓ Session started with Permission Handler!
```

## Bước 6: Kết nối vào tmux

```bash
tmux attach -t agent-session
```

## Bước 7: Sử dụng

### Trong tmux

```
Ctrl+B rồi 0  →  Cửa sổ Agent A (Manager)
Ctrl+B rồi 1  →  Cửa sổ Agent B (Worker)
```

### Giao task cho Agent A

```bash
# Trong cửa sổ Agent A
echo "[TASK] T001 | Phân tích code src/" > shared/messages/a_to_b.txt
```

### Agent A đọc file với permission

```bash
# Auto-approve
./perm.sh read README.md

# Auto-deny
./perm.sh read secret.key
```

### Agent B phản hồi

```bash
# Trong cửa sổ Agent B
echo "[TASK_RESULT] T001 | SUCCESS
Output: Tìm thấy 10 file" > shared/messages/b_to_a.txt
```

## Bước 8: Quản lý tasks

```bash
# Thêm task
./task_manager.sh add T001 "Deploy app" B HIGH

# Xem dashboard
./task_manager.sh dashboard

# Nhắc nhở
./reminder.sh B
```

## Tóm tắt các files

```
tmux-agent/
├── config.json              ← CẤU HÌNH (sửa ở đây)
├── start.sh                 ← KHỞI ĐỘNG
├── perm.sh                  ← QUẢN LÝ PERMISSION
├── comms.sh                 ← GIAO TIẾP CƠ BẢN
├── smart_comms.sh           ← GIAO TIẾP NÂNG CAO
├── task_manager.sh          ← QUẢN LÝ TASKS
├── reminder.sh              ← NHẮC NHỞ
├── handshake.sh             ← TẠO CONTEXT CHO AGENTS
├── prompts/
│   ├── agent_a_minimal.md   ← PROMPT AGENT A
│   └── agent_b_minimal.md   ← PROMPT AGENT B
└── shared/messages/         ← THƯ MỤC GIAO TIẾP
```

## Troubleshooting

| Vấn đề | Giải pháp |
|--------|-----------|
| `jq not found` | `sudo apt install jq` |
| `Session not found` | `./start.sh` lại |
| Permission denied | `./perm.sh auto` |
| Agent không nhận task | Kiểm tra `shared/messages/a_to_b.txt` |
