# Agent Teamwork — opencode serve workers

Hệ thống Manager → Worker qua **REST HTTP API + SSE event monitor**.

- **Manager**: opencode TUI (tmux window), nhận task từ user, phân rã, điều phối worker
- **Workers**: `opencode serve` processes trên port riêng, mỗi worker = 1 context biệt lập
- **Daemon**: 1 process thống nhất, chạy ngầm:
  - **Manager permission**: auto-Enter (screen capture tmux)
  - **Worker events**: SSE monitor → ghi file `.worker/<name>.status`
  - **Worker permission**: báo Manager qua status file → Manager quyết định allow/deny
  - **Cleanup**: khi Manager tắt hoặc Ctrl+C → kill workers + xoá `.worker/`

## Kiến trúc

```
setup.sh
├── Manager (tmux window, opencode TUI)
│   └── permission: bot auto-Enter (screen capture)
│
├── Daemon (1 process, background)
│   ├── Subprocess: serve_controller.sh bot
│   │   └── 1 SSE monitor/worker → ghi status files
│   ├── Loop: check Manager alive + auto-Enter permission
│   └── On Manager exit: kill workers → rm .worker/ → exit
│
└── Workers (opencode serve :4091, :4092, ...)
    ├── /session/:id/message     ← Manager gửi task (HTTP POST)
    ├── /session/:id/permissions ← Manager allow/deny
    ├── /event (SSE)             ← Bot đọc events
    └── /session/status          ← Poll fallback
```

## Permission — xử lý triệt để

Config `"permission": {"*": "allow"}` **không triệt để** — vẫn có prompt mà config không phủ.

| Ai gặp permission | Ai phát hiện | Ai xử lý |
|---|---|---|
| **Manager TUI** | Daemon (screen capture) | Daemon auto-Enter |
| **Worker serve** | Bot SSE (`permission.asked`) | Ghi file → Manager đọc → `allow`/`deny` |

```
Worker gặp permission
  → SSE event "permission.asked"
  → Bot ghi .worker/<n>.status = "permission"
  → Bot ghi .worker/<n>.permission = JSON chi tiết
  → Manager gọi: status Worker-1 → thấy "permission"
  → Manager gọi: permission-info Worker-1 → xem chi tiết
  → Manager gọi: allow Worker-1 → approve
  → Worker tiếp tục chạy
```

## Cài đặt & Chạy

```bash
cd agent-teamwork/
./setup.sh
```

Khi Manager TUI tắt (hoặc Ctrl+C) → **tự động kill toàn bộ workers + xoá `.worker/`**.

## API — serve_controller.sh

```bash
# Tạo worker
./serve_controller.sh create Worker-1
./serve_controller.sh create Worker-2 opencode/gpt-5.5

# Gửi task (NON-BLOCKING — khuyên dùng)
./serve_controller.sh send-async Worker-1 "Review src/api/"

# Kiểm tra trạng thái
./serve_controller.sh status Worker-1        # idle|running|permission|error|dead
./serve_controller.sh status-all

# Xem + xử lý permission
./serve_controller.sh permission-info Worker-1
./serve_controller.sh allow Worker-1
./serve_controller.sh deny Worker-1

# Đọc kết quả
./serve_controller.sh result Worker-1        # text
./serve_controller.sh result-full Worker-1   # full JSON

# Quản lý
./serve_controller.sh dashboard
./serve_controller.sh kill Worker-1
./serve_controller.sh killall
```

## File trạng thái (`.worker/`)

| File | Nội dung |
|---|---|
| `<name>.json` | Worker state (port, pid, model) |
| `<name>.status` | idle / running / permission / error / dead |
| `<name>.permission` | JSON chi tiết permission đang chờ |
| `<name>.permission_id` | ID để gọi POST permissions |
| `<name>.error` | JSON lỗi |
| `<name>.sse_pid` | PID của SSE monitor |
| `<name>.last_result` | Kết quả cuối cùng |
| `configs/<name>.json` | Config riêng mỗi worker |
| `daemon.pid` | PID của daemon |
| `worker_bot.pid` | PID của worker bot |

## Cấu trúc thư mục

```
agent-teamwork/
├── manager.json              ← Manager config + prompt
├── worker.json               ← Worker config + serve params
├── serve_controller.sh       ← Controller chính (REST + SSE)
├── setup.sh                  ← Khởi tạo + Manager TUI + Daemon
├── tmux_controller.sh        ← (legacy) tmux-based controller
├── manager.sh                ← (legacy) tmux-based manager
├── .worker/                  ← State dir (tự tạo, tự xoá khi exit)
├── tests/
└── README.md
```
