# Agent Teamwork

Cài 1 lần — dùng mọi project. Bấm **Tab** để chuyển sang Manager, điều phối worker song song ngay trong opencode TUI.

## Cài đặt

```bash
git clone https://github.com/truongsontung/agent-teamwork.git ~/agent-teamwork
~/agent-teamwork/install.sh
```

Script sẽ cài vào `~/.config/opencode/`:
- `plugins/agent-teamwork.ts` — plugin chính
- `agents/manager.md` — Manager agent definition
- `worker.json` — worker config (model, max_workers)

## Sử dụng

1. Mở opencode ở bất kỳ project nào
2. Nhấn **Tab** → chọn **Manager**
3. Gõ task, Manager tự phân công → tạo worker → gom kết quả

Ví dụ:
```
Xây dựng login JWT: API backend + bảng DB + form frontend
```

## Kiến trúc

```
opencode TUI
├── Manager agent (Tab để chọn)
│   ├── worker_create / worker_send / worker_result
│   ├── worker_allow / worker_kill / worker_killall
│   └── todowrite hiển thị tiến độ worker
│
├── Plugin (agent-teamwork.ts)
│   ├── Đọc config từ worker.json (model, max_workers)
│   ├── Spawn opencode serve processes (workers)
│   ├── SSE monitor per worker (real-time events)
│   └── appendPrompt("!ev X done") → Manager nhận qua TUI prompt
│
└── Workers (opencode serve, port 4091+)
    └── Context độc lập, model config riêng
```

**Manager không có quyền read/edit/write** — mọi thao tác code phải qua worker. Plugin bắn sự kiện `!ev` vào TUI prompt, Manager xử lý ngay không cần poll.

## Event-driven workflow

```
Manager                  Plugin                    Workers
  │                        │                          │
  ├── worker_create w1 ───►├── spawn opencode serve ──►│
  │                        │   (model từ worker.json)  │
  │◄── "+w1 (port 4091)" ─┤                          │
  │                        │                          │
  ├── worker_send w1 ────►├── POST /prompt_async ────►│
  │   [CHỜ]               │◄── SSE: started ─────────┤
  │                        │   (tự động)              │
  │                        │◄── SSE: next.complete ───┤
  │◄── !ev w1 done ──────┤                          │
  │                        │                          │
  ├── worker_result w1 ──►├── GET /message ──────────►│
  │◄── (kết quả) ─────────┤                          │
```

## Tools

| Tool | Mô tả |
|------|-------|
| `worker_create <tên>` | Tạo worker mới (agent: build mặc định) |
| `worker_create <tên> <model> plan` | Tạo worker model khác, agent chỉ đọc |
| `worker_send <tên> "task"` | Gửi task (fire & forget, không block) |
| `worker_result <tên>` | Đọc kết quả — **chỉ gọi sau khi nhận `!ev <tên> done`** |
| `worker_allow <tên>` | Duyệt permission (once/always/never/index) |
| `worker_choose <tên> <label\|index>` | Trả lời question của worker (tick chọn) — gọi sau `!ev <tên> ask` |
| `worker_reject <tên>` | Từ chối question của worker |
| `worker_kill <tên>` | Hủy worker |
| `worker_killall` | Hủy tất cả workers |

## Events (!ev)

Manager nhận events qua TUI prompt (plugin dùng `appendPrompt` + `submitPrompt`):

| Event | Ý nghĩa |
|-------|----------|
| `!ev <tên> started` | Worker bắt đầu xử lý |
| `!ev <tên> permission <type>` | Worker cần duyệt quyền |
| `!ev <tên> ask <header> Q1: <câu hỏi> [multi] (opt1\|opt2\|opt3)` | Worker đang hỏi, chờ Manager tick chọn qua `worker_choose` |
| `!ev <tên> done` | Worker hoàn thành task |
| `!ev <tên> error [cls] <msg>` | Worker gặp lỗi. `cls` = quota/ratelimit/auth/context/network/model (phân loại lỗi model/provider) |
| `!ev <tên> died exit=<code>` | Worker process bị killed |

## Cấu hình

| File | Chức năng |
|------|-----------|
| `~/.config/opencode/agents/manager.md` | Model, prompt, permission Manager |
| `~/.config/opencode/worker.json` | Model worker mặc định, max_workers |
| `~/.config/opencode/opencode.json` | Providers (deepapi, zen-proxy...) |
| `~/.config/opencode/plugins/agent-teamwork.ts` | Plugin (không cần sửa) |

### Worker config (`worker.json`)

Plugin đọc trực tiếp file này khi khởi động. Thay đổi model/max_workers tại đây, không cần sửa plugin.

```json
{
  "model": "zen-proxy/deepseek-v4-flash-free",
  "max_workers": 5
}
```

- `model`: Model mặc định cho tất cả workers. Hỗ trợ `provider/model` hoặc `model`.
- `max_workers`: Số worker tối đa đồng thời (default: 5).

### Provider config (`opencode.json`)

```json
{
  "provider": {
    "deepapi": {
      "apiKey": "...",
      "baseURL": "https://api.deepapi.io/v1"
    },
    "zen-proxy": {
      "apiKey": "...",
      "baseURL": "https://zen.algobungo.dev/v1"
    }
  }
}
```

## Manager restrictions

Manager agent được cấu hình với **tất cả quyền deny** (read, edit, write, bash, glob, grep, task, webfetch, websearch, question). Mục đích:

- Manager chỉ dùng được worker tools + todowrite
- Mọi thao tác code/IO phải qua worker
- Workers có đầy đủ quyền, context riêng biệt

## Permissions

Khi worker cần quyền (edit, bash, write...), plugin tự động:
1. Push `!ev <tên> permission <type> options=[...]` vào prompt
2. Manager gọi `worker_allow <tên>` với response (once/always/never/index)
3. Plugin forward đến worker, worker tiếp tục xử lý

## Tái sử dụng worker

Worker đã tạo **không cần kill** sau khi xong. Gửi task mới bằng `worker_send` để tái sử dụng. Chỉ kill khi cần thiết (`worker_kill` / `worker_killall`).

## Cập nhật

```bash
cd ~/agent-teamwork && git pull && ./install.sh
```

## Gỡ bỏ

```bash
rm ~/.config/opencode/plugins/agent-teamwork.ts
rm ~/.config/opencode/agents/manager.md
```

## License

ISC
