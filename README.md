# Agent Teamwork

Cài 1 lần — dùng mọi project. Bấm Tab để có Manager điều phối worker song song ngay trong opencode TUI.

```bash
git clone https://github.com/truongsontung/agent-teamwork.git ~/agent-teamwork
~/agent-teamwork/install.sh
```

## Dùng

Mở opencode ở bất kỳ project nào → **Tab** → Manager. Gõ task, Manager tự phân rã + tạo worker + gom kết quả.

```
Xây dựng login JWT: API backend + bảng DB + form frontend
```

## Cách hoạt động

```
openode TUI
├── Manager agent (Tab để chọn)
│   ├── worker_create / worker_send / worker_status / worker_result
│   ├── worker_allow / worker_deny / worker_kill / worker_killall
│   └── todowrite hiển thị tiến độ worker
│
├── Plugin (agent-teamwork.ts, 380 dòng)
│   ├── Spawn opencode serve processes (worker)
│   ├── SSE monitor per worker (real-time)
│   └── appendPrompt("!ev X done") khi worker xong
│
└── Workers (opencode serve, port 4091+)
    └── Context độc lập, tool đầy đủ
```

Manager **không có** read/edit/write — mọi thao tác code phải qua worker. Plugin bắn sự kiện `!ev` vào input, Manager xử lý ngay không cần poll.

## Cấu hình

| File | Dùng để |
|---|---|
| `~/.config/opencode/agents/manager.md` | Model + prompt Manager |
| `~/.config/opencode/worker.json` | Model worker mặc định, max_workers |
| `~/.config/opencode/plugins/agent-teamwork.ts` | Plugin (không cần sửa) |

## Cập nhật

```bash
cd ~/agent-teamwork && git pull && ./install.sh
```

## Gỡ

```bash
rm ~/.config/opencode/plugins/agent-teamwork.ts
rm ~/.config/opencode/agents/manager.md
```
