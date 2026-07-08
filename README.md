# Agent Teamwork

Agent A (Manager) điều khiển các Agent B (Workers) qua tmux.

## Setup

```bash
./setup.sh
tmux attach -t agent-session
```

## Cấu trúc

```
agent-teamwork/
├── config.json           ← Cấu hình
├── setup.sh              ← Khởi động
├── tmux_controller.sh    ← Điều khiển tmux
├── manager.sh            ← Quản lý workers
└── prompts/
    └── manager_prompt.md ← Prompt cho Manager
```

## Cách dùng

### Manager commands

```bash
# Tạo worker
./manager.sh create Worker-1
./manager.sh create Worker-2 opencode/mimo-v2.5-free

# Gửi lệnh
./manager.sh send Worker-1 "npm install"
./manager.sh send-all "npm test"

# Đọc màn hình
./manager.sh read Worker-1

# Dashboard
./manager.sh dashboard
```

### Tmux controller

```bash
# Gửi lệnh
./tmux_controller.sh send Worker-1 "ls -la"

# Đọc màn hình
./tmux_controller.sh read Worker-1

# Đợi xong
./tmux_controller.sh wait Worker-1 60

# Smart send (gửi + đợi)
./tmux_controller.sh smart Worker-1 "npm install" 60

# Tạo/kill worker
./tmux_controller.sh create Worker-2
./tmux_controller.sh kill Worker-2
```

## Config

```json
{
  "max_workers": 5,
  "workers": {
    "default_model": "opencode/deepseek-v4-flash-free",
    "available_models": [
      "opencode/deepseek-v4-flash-free",
      "opencode/mimo-v2.5-free",
      "opencode/gpt-5.5"
    ]
  }
}
```

## Models

| Model | Type |
|-------|------|
| opencode/deepseek-v4-flash-free | Free |
| opencode/mimo-v2.5-free | Free |
| opencode/gpt-5.5 | Paid |
| opencode/claude-opus-4-8 | Paid |
