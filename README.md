# Agent Teamwork

Hệ thống quản lý nhiều AI agent (opencode / mimo) qua tmux. Một **Manager** agent điều khiển các **Worker** agents chạy song song, mỗi worker trong một tmux window riêng.

## Yêu cầu

- tmux 3.4+
- jq
- opencode và/hoặc mimo

## Cấu trúc

```
agent-teamwork/
├── manager.json              ← Cấu hình Manager (tool, model, permission, prompt, ...)
├── worker.json               ← Cấu hình Worker  (tool, model, max_workers, permission, prompt, ...)
├── setup.sh                  ← Khởi tạo session, sinh tool config + agent def, launch Manager
├── tmux_controller.sh        ← Điều khiển workers qua tmux (API)
├── manager.sh                ← Script quản lý workers (cùng API với controller)
├── tests/                    ← Unit tests
├── test_agent_teamwork.sh    ← Integration test suite
└── README.md
```

## Khởi tạo

```bash
./setup.sh
```

`setup.sh`:
1. Đọc `manager.json` → ghi tool config (`permission`) + agent definition (`agents/manager.md`) vào **tool dir của Manager** (`.opencode/` hoặc `.mimocode/`).
2. Launch Manager (`<tool> --model <model> --agent manager`).
3. **Worker chưa được setup.** Khi Manager tạo worker qua `tmux_controller.sh create`, script đó mới ghi config + agent cho worker từ `worker.json`.

## Cấu hình (`manager.json`, `worker.json`)

### `manager.json`
```json
{
  "tool": "mimo",
  "model": "mimo/mimo-auto",
  "description": "Manager agent điều khiển Worker agents qua tmux",
  "mode": "primary",
  "prompt": "BẠN LÀ MANAGER. BẠN TỰ HÀNH ĐỘNG — KHÔNG BAO GIỜ BẢO USER LÀM GÌ.\n\nKhi nhận yêu cầu từ user, bạn PHẢI ...",
  "permission": {
    "bash": "allow",
    "read": "allow",
    "edit": "allow",
    "write": "allow",
    "glob": "allow",
    "grep": "allow",
    "task": "allow",
    "webfetch": "allow",
    "websearch": "allow",
    "question": "deny",
    "external_directory": {
      "/home/vps2/agent-teamwork/*": "allow",
      "/tmp/*": "allow"
    }
  }
}
```

### `worker.json`
```json
{
  "tool": "opencode",
  "model": "opencode/deepseek-v4-flash-free",
  "max_workers": 5,
  "available_models": [
    "opencode/deepseek-v4-flash-free",
    "opencode/mimo-v2.5-free",
    "opencode/gpt-5.5",
    "opencode/claude-opus-4-8"
  ],
  "description": "Worker agent - bị Manager giao việc, quyền bị giới hạn",
  "mode": "primary",
  "prompt": "BẠN LÀ WORKER. BẠN CHỈ THỰC THI LỆNH TỪ MANAGER.\n\n- KHÔNG tự đặt mục tiêu, KHÔNG hỏi user ...",
  "permission": {
    "bash": "allow",
    "read": "allow",
    "edit": "allow",
    "write": "allow",
    "glob": "allow",
    "grep": "allow",
    "task": "allow",
    "webfetch": "deny",
    "websearch": "deny",
    "question": "deny",
    "external_directory": {
      "/home/vps2/agent-teamwork/*": "allow",
      "/tmp/*": "deny"
    }
  }
}
```

| Field | Mô tả |
|-------|-------|
| `tool` | Tool launch (`opencode` / `mimo`) |
| `model` | Model cho agent đó |
| `max_workers` | (_worker.json_) số worker tối đa |
| `available_models` | (_worker.json_) danh sách model có thể chọn khi tạo worker |
| `permission` | Quyền của tool (theo schema opencode/mimo), gồm `external_directory` |
| `description` | Mô tả agent (ghi vào frontmatter của agent)` |
| `mode` | Agent mode (`"primary"`) |
| `prompt` | System prompt (thân prompt, ghi vào agent)` |

## Tách biệt quyền Manager / Worker

**Manager và Worker có file config riêng biệt**, không dùng chung:

- Manager → `.mimocode/opencode.json` (tool=mimo) hoặc `.opencode/opencode.json` (tool=opencode)
- Worker → `.mimocode/opencode.json` hoặc `.opencode/opencode.json` tùy tool

`setup.sh` chỉ ghi config Manager. Khi Manager tạo worker qua `tmux_controller.sh create`, script đó mới ghi **tool config + agent definition** (`opencode.json` + `agents/worker.md`) của worker vào tool dir của worker từ `worker.json`, ngay trước khi launch worker. Vì opencode/mimo chỉ **đọc config 1 lần lúc khởi động**, ghi đè này **không ảnh hưởng** process Manager đang chạy.

→ **Sửa `worker.json` không đụng Manager**. Kể cả khi cả 2 dùng cùng 1 tool (vd cùng opencode): file chung là staging được ghi đè trước mỗi lần launch, process nào cũng chỉ đọc config lúc start.

## Tự động 100% (user ủy quyền tuyệt đối)

- Tất cả quyền `allow`; `question: deny` (không bao giờ hỏi user).
- `external_directory` phủ đúng scope (Manager rộng, worker hẹp), không prompt.
- `tmux_controller.sh` `wait`/`smart` **không tự bấm Allow** permission prompt → trả exit code `2` để Manager quyết định.

## API

### Worker Management

```bash
# Tạo worker (tool + model từ worker.json; launch --agent worker)
./tmux_controller.sh create Worker-1
./tmux_controller.sh create Worker-2 opencode/mimo-v2.5-free  # custom model

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

### Gửi lệnh, đọc output, dashboard

```bash
./tmux_controller.sh send Worker-1 ls
./tmux_controller.sh read Worker-1
./tmux_controller.sh smart Worker-1 "npm run build" 120   # send + wait
./tmux_controller.sh dashboard
./manager.sh send-all "npm test"
```

### Exit Codes (`wait` / `smart`)

| Code | Ý nghĩa |
|------|---------|
| `0` | Worker hoàn thành (idle) |
| `1` | Timeout |
| `2` | Permission / Ask / Confirm prompt — Manager phải `read` và xử lý |

### Interactive Mode

```bash
./tmux_controller.sh interactive
# Controller> send Worker-1 npm install
# Controller> dashboard
# Controller> quit
```

## Workflow

Manager là một AI agent trong window "Manager". Prompt (field `prompt` trong `manager.json`) hướng dẫn nó dùng `./tmux_controller.sh` để tạo workers, gửi lệnh, đọc kết quả. Manager tự hành động, không hỏi user.

```bash
# Manager tự tạo worker, giao task, đọc kết quả
./tmux_controller.sh create Reviewer-1
./tmux_controller.sh smart Reviewer-1 "Review src/api/" 120
./tmux_controller.sh read Reviewer-1
./tmux_controller.sh dashboard
```

## Testing

```bash
bash tests/test_unit_manager.sh           # 42 tests, mock tmux/jq
bash tests/test_unit_tmux_controller.sh   # 51 tests, mock tmux/jq
./test_agent_teamwork.sh                  # integration tests (cần tmux)
./test_agent_teamwork.sh -v               # verbose
```

## Biến môi trường

| Biến | Mô tả |
|------|-------|
| `SESSION_NAME` | Ghi đè tên tmux session (do `setup.sh` export) |

## Troubleshooting

| Vấn đề | Giải pháp |
|--------|-----------|
| `jq: command not found` | `sudo apt install jq` |
| `./setup.sh` không tạo được session | `tmux kill-session -t agent-session` rồi chạy lại |
| Worker không nhận lệnh | `./tmux_controller.sh dashboard` |
| `set-hook: invalid option` | tmux 3.4 không có hook đó — dùng stability detection |
