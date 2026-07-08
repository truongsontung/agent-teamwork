# Agent Teamwork

Hệ thống quản lý nhiều AI agent (opencode) qua tmux. Manager agent điều khiển các Worker agents chạy song song, mỗi worker trong một tmux window riêng.

## Yêu cầu

- tmux 3.4+
- jq
- opencode (cho workers)

## Setup

```bash
git clone <repo> && cd agent-teamwork
./setup.sh
```

`setup.sh` tự động phát hiện trạng thái:

| Session `agent-session` đã tồn tại? | Hành vi |
|-------------------------------------|---------|
| **Có** (worker agents đang chạy) | Tạo window "Manager" vào session có sẵn — **không kill gì** |
| **Chưa** | Tạo session `agent-session` mới (detached, persist sau SSH disconnect) |

Manager agent được launch với agent config `.opencode/agents/manager.md` — system prompt được load làm instructions cho Manager, không phải user message.

## Cấu trúc

```
agent-teamwork/
├── config.json              ← Cấu hình
├── setup.sh                 ← Khởi tạo session
├── tmux_controller.sh       ← Điều khiển workers qua tmux
├── manager.sh               ← Script quản lý workers (cùng API)
├── .opencode/
│   └── agents/
│       └── manager.md       ← Agent definition (system prompt cho Manager)
├── prompts/
│   └── manager_prompt.md    ← Prompt gốc (reference)
├── test_agent_teamwork.sh   ← Test suite
└── README.md
```

### `tmux_controller.sh` vs `manager.sh`

Hai script cung cấp cùng chức năng, có thể dùng thay thế lẫn nhau. Worker tạo từ script nào cũng quản lý được từ script kia.

## Config (`config.json`)

```json
{
  "session_name": "agent-session",
  "max_workers": 5,
  "manager": {
    "tool": "mimo",
    "model": "mimo/mimo-auto"
  },
  "workers": {
    "default_model": "opencode/deepseek-v4-flash-free",
    "available_models": [
      "opencode/deepseek-v4-flash-free",
      "opencode/mimo-v2.5-free",
      "opencode/gpt-5.5",
      "opencode/claude-opus-4-8"
    ]
  }
}
```

| Field | Mô tả |
|-------|-------|
| `session_name` | Tên tmux session (mặc định: `agent-session`) |
| `max_workers` | Số worker tối đa |
| `manager.tool` | Tool launch Manager (`opencode` hoặc `mimo`) |
| `manager.model` | Model cho Manager agent |
| `workers.default_model` | Model mặc định khi tạo worker mới |

## API

### Worker Management

```bash
# Tạo worker
./tmux_controller.sh create Worker-1
./tmux_controller.sh create Worker-2 opencode/mimo-v2.5-free  # custom model
./manager.sh create Worker-3

# Kill worker
./tmux_controller.sh kill Worker-1

# Lỗi khi trùng tên
./tmux_controller.sh create Worker-1  # → Error: already exists

# Lỗi khi worker không tồn tại
./tmux_controller.sh kill NoWorker     # → Error: not found

# Lỗi khi quá max_workers
# → Error: Max workers (5) reached

# Lỗi khi chưa chạy setup
# → Error: Session '...' not found. Run ./setup.sh first
```

### Command Sending

```bash
# Lệnh đơn giản
./tmux_controller.sh send Worker-1 ls

# Lệnh multi-word (tự động xử lý)
./tmux_controller.sh send Worker-1 npm install express mongoose

# Gửi đến tất cả workers
./manager.sh send-all npm test

# Gửi đến worker không tồn tại → Error: Target 'X' not found
```

### Đọc Output

```bash
# Đọc màn hình worker
./tmux_controller.sh read Worker-1

# Worker không tồn tại → Error: Target 'X' not found
```

### Chờ Worker Hoàn Thành

`wait_prompt` phát hiện worker xong việc qua 3 cơ chế:
1. **Screen stability**: output không thay đổi trong 2 giây
2. **Shell prompt**: phát hiện `$` hoặc `≥` ở cuối
3. **Opencode idle**: phát hiện dấu hiệu `ready`, `waiting for input`

```bash
# Chờ worker với timeout 60s
./tmux_controller.sh wait Worker-1 60

# Smart send (gửi + chờ)
./tmux_controller.sh smart Worker-1 npm run build 120
```

### Dashboard

```bash
# tmux_controller.sh — hiển thị chi tiết (uptime, last command)
./tmux_controller.sh dashboard

# manager.sh — hiển thị nhanh (uptime)
./manager.sh dashboard
```

Output mẫu:
```
╔══════════════════════════════════════════════════════════╗
║         AGENT TEAMWORK DASHBOARD                       ║
║         2026-07-08 20:30:00                            ║
╠══════════════════════════════════════════════════════════╣
║  Worker-1
║    Uptime: 02:34
║    Last: npm install
║
║  Worker-2
║    Uptime: 01:15
║    Last: N/A
║
╚══════════════════════════════════════════════════════════╝
```

### Interactive Mode

```bash
./tmux_controller.sh interactive
# Controller> send Worker-1 npm install
# Controller> dashboard
# Controller> quit
```

## Workflow Ví Dụ

### Manager Agent (opencode) Điều Khiển Workers

Manager là một opencode instance trong window "Manager". Prompt (`prompts/manager_prompt.md`) hướng dẫn nó dùng `./tmux_controller.sh` để tạo workers, gửi lệnh, đọc kết quả.

1. `./setup.sh` → tạo session
2. `tmux attach -t agent-session` → mở Manager window
3. Manager gõ lệnh tạo workers
4. Manager giao task, giám sát qua `dashboard`
5. Worker trả kết quả → Manager đọc và tổng hợp

### Workflow Mẫu

```bash
# Manager window: tạo 3 reviewers
./tmux_controller.sh create Reviewer-1
./tmux_controller.sh create Reviewer-2 opencode/mimo-v2.5-free
./tmux_controller.sh create Reviewer-3

# Giao task
./tmux_controller.sh send Reviewer-1 Review src/api/
./tmux_controller.sh send Reviewer-2 Review src/utils/
./tmux_controller.sh send Reviewer-3 Review src/models/

# Giám sát
./tmux_controller.sh dashboard

# Đọc kết quả
./tmux_controller.sh read Reviewer-1
```

## Testing

```bash
./test_agent_teamwork.sh        # chạy 56 tests
./test_agent_teamwork.sh -v     # verbose (xem output từng test)
```

Test suite kiểm tra: tạo/kill worker, duplicate, max_workers, custom model, send multi-word, read, wait, smart, send non-existent, dashboard, cross-script compatibility, help/usage, cleanup.

### Exit Codes (`wait` / `smart`)

| Code | Ý nghĩa |
|------|---------|
| `0` | Worker hoàn thành (idle) |
| `1` | Timeout — Manager tự `read` để xử lý |

### Auto-Handled Events

`wait_prompt` tự động xử lý các sự kiện Permission/Allow. Manager agent (AI) tự detect và xử lý các hội thoại `Ask/Confirm/Question` — không cần exit code riêng.

## Biến Môi Trường

| Biến | Mô tả |
|------|-------|
| `SESSION_NAME` | Ghi đè tên tmux session (do `setup.sh` export) |

## Troubleshooting

| Vấn đề | Giải pháp |
|--------|-----------|
| `jq: command not found` | `sudo apt install jq` |
| `./setup.sh` không tạo được session | `tmux kill-session -t agent-session` rồi chạy lại |
| Worker không nhận lệnh | Kiểm tra `./tmux_controller.sh dashboard` xem worker còn sống |
| `set-hook: invalid option` | tmux 3.4 không có hook `pane-output-change` — dùng stability detection |
| Worker không tạo được | Kiểm tra `max_workers` trong config |
