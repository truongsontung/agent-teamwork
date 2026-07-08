# 🤝 Agent Teamwork

**Hệ thống hai Agent làm việc nhóm qua tmux** - Agent A (Manager) giám sát và kiểm soát Agent B (Worker)

> Khác với agent thông thường: Hệ thống này chạy **2 agents cùng lúc** trong tmux, giao tiếp qua file, Agent A **kiểm soát toàn bộ quyền hạn** của Agent B.

## ⚡ Bắt đầu nhanh

```bash
cd agent-teamwork
./setup.sh
tmux attach -t agent-session
```

## 📁 Cấu trúc thư mục

```
agent-teamwork/
├── config.json              ← CẤU HÌNH (sửa ở đây)
├── setup.sh                 ← KHỞI ĐỘNG (1 lệnh)
├── start.sh                 ← Script khởi tạo tmux
├── perm.sh                  ← Permission tự động
├── agent_perm.sh            ← Agent A kiểm soát Agent B
├── comms.sh                 ← Giao tiếp cơ bản
├── smart_comms.sh           ← Giao tiếp nâng cao (CHOICE, ALLOW)
├── task_manager.sh          ← Quản lý tasks
├── reminder.sh              ← Nhắc nhở tasks
├── handshake.sh             ← Tạo context cho agents
├── prompts/
│   ├── agent_a_minimal.md   ← Prompt Agent A
│   └── agent_b_minimal.md   ← Prompt Agent B
└── shared/
    ├── messages/            ← Thư mục giao tiếp
    └── state/               ← Lưu trạng thái
```

## ⚙️ Cấu hình (config.json)

```json
{
  "agents": {
    "A": {
      "name": "Manager",
      "tool": "mimo",
      "model": "mimo/mimo-auto",
      "mode": "build",
      "permission": {
        "mode": "auto",
        "auto_approve": [".md", ".txt", ".json"],
        "auto_deny": [".key", ".pem"]
      }
    },
    "B": {
      "name": "Worker",
      "tool": "opencode",
      "model": "opencode/deepseek-v4-flash-free",
      "mode": "build",
      "permission": {
        "mode": "controlled_by_A",
        "auto_approve": [".md", ".txt"],
        "auto_deny": [".key", ".pem"]
      }
    }
  }
}
```

### Model có sẵn

| Tool | Models |
|------|--------|
| mimo | `mimo/mimo-auto`, `mimo/mimo-v2.5-pro`, `mimo/mimo-v2.5-free` |
| opencode | `opencode/gpt-5.5`, `opencode/deepseek-v4-flash-free`, `opencode/claude-opus-4-8` |

## 🔐 Permission System

### Agent A (auto) - Tự quyết định

```bash
# Sửa trong config.json
"permission": {
    "mode": "auto",
    "auto_approve": [".md", ".txt", ".key"],  ← Thêm .key vào đây
    "auto_deny": []                           ← Để trống
}
```

### Agent B (controlled_by_A) - Do Agent A quyết định

```bash
# Trong tmux, Agent A gõ:
./agent_perm.sh allow .env      # Cho phép Agent B đọc .env
./agent_perm.sh allow .key      # Cho phép Agent B đọc *.key
./agent_perm.sh deny .env       # Từ chối Agent B đọc .env
./agent_perm.sh show            # Xem tất cả quyền
```

## 📋 Workflow trong tmux

```
┌─────────────────────────────────────────────────────────────────┐
│  1. Ctrl+B rồi 0  →  Chuyển sang Agent A (Manager)            │
│                                                                 │
│  2. Giao task:                                                  │
│     echo "[TASK] T001 | Phân tích code" > shared/messages/a_to_b.txt │
│                                                                 │
│  3. Agent A tự động gửi task cho Agent B                        │
│                                                                 │
│  4. Ctrl+B rồi 1  →  Xem Agent B đang làm gì                   │
│                                                                 │
│  5. Ctrl+B rồi 0  →  Quay lại Agent A xem kết quả              │
└─────────────────────────────────────────────────────────────────┘
```

## 📨 Message Types

### Cơ bản

| Type | Mô tả | Ví dụ |
|------|--------|--------|
| `[TASK]` | Giao việc | `[TASK] T001 | Phân tích code` |
| `[RESULT]` | Kết quả | `[TASK_RESULT] T001 | SUCCESS` |
| `[DECISION]` | Quyết định | `[DECISION] T001 | APPROVE` |

### Nâng cao (smart_comms.sh)

| Type | Mô tả | Ví dụ |
|------|--------|--------|
| `[CHOICE]` | Xin chọn | `send-choice T001 "Chọn method" "A" "B"` |
| `[ALLOW]` | Xin phép | `send-allow T001 ".env" "READ" "Cần DB URL"` |
| `[CONFIRM]` | Xác nhận | `send-confirm T001 "Xóa file" "Không thể hoàn tác"` |

## 🛠️ Commands tham khảo

```bash
# Khởi động
./setup.sh

# Permission
./agent_perm.sh allow <file>     # Agent A cho phép Agent B đọc
./agent_perm.sh deny <file>      # Agent A từ chối Agent B
./agent_perm.sh show             # Xem quyền

# Tasks
./task_manager.sh add T001 "Task name" B HIGH
./task_manager.sh dashboard
./reminder.sh B

# Giao tiếp
./comms.sh send-a "[TASK] T001 | ..."
./comms.sh send-b "[RESULT] T001 | SUCCESS"
./comms.sh check-a
./comms.sh check-b
```

## 🔧 Troubleshooting

| Vấn đề | Giải pháp |
|--------|-----------|
| `jq not found` | `sudo apt install jq` |
| Session not found | `./setup.sh` lại |
| Agent không nhận task | Kiểm tra `shared/messages/a_to_b.txt` |
| Permission denied | `./agent_perm.sh allow <file>` |

## 📊 So sánh với Agent thường

| | Agent thường | Agent Teamwork |
|---|---------------|----------------|
| **Số lượng** | 1 agent | 2 agents |
| **Giao tiếp** | Đơn lẻ | Qua file tmux |
| **Permission** | Toàn cục | Agent A kiểm soát Agent B |
| **Giám sát** | Không có | Agent A giám sát Agent B |
| **Token** | 100% | ~140% (thêm Agent A) |

## 📝 License

Miễn phí sử dụng
