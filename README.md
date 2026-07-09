# Agent Teamwork

1 lệnh. Plugin native. Manager điều phối worker ngay trong opencode TUI.

```
cd ~/my-project
~/agent-teamwork/setup.sh
```

## Kiến trúc

```
┌─ Manager TUI ────────────────────────────────────────┐
│  Plugin agent-teamwork.ts (380 dòng TypeScript)      │
│  ├── worker_create / send / status / result          │
│  ├── worker_allow / deny / kill / killall            │
│  ├── SSE monitor per worker (real-time)              │
│  ├── client.tui.appendPrompt() bắn !ev vào input     │
│  └── dispose: kill workers khi exit                  │
└──────────────────────────────────────────────────────┘
         │ Bun.spawn          │ fetch / SSE
         ▼                    ▼
┌──────────────┐   ┌──────────────┐
│ :4091 serve  │   │ :4092 serve  │   ...
│ context: BE  │   │ context: FE  │
└──────────────┘   └──────────────┘
```

## Dùng

```bash
git clone https://github.com/truongsontung/agent-teamwork.git ~/agent-teamwork
cd ~/my-project
~/agent-teamwork/setup.sh
```

Gõ task cho Manager trong TUI:

```
Xây dựng login JWT: API backend + bảng DB + form frontend
```

Manager tự: `worker_create` 3 worker → `worker_send` song song → đợi `!ev done` → `worker_result` → `worker_killall`.

## Yêu cầu

- `opencode` trong PATH
- `jq`

## Sự kiện

Plugin bắn `!ev` vào input Manager khi worker đổi trạng thái:

| Event | Manager làm gì |
|---|---|
| `!ev X done` | `worker_result X` |
| `!ev X permission` | `worker_permission_info X` → `worker_allow X` |
| `!ev X error` | `worker_status X` kiểm tra |

## Cấu trúc thư mục

```
agent-teamwork/
├── manager.json            ← Prompt Manager
├── worker.json             ← Config Worker (model, permission)
├── setup.sh                ← 1 lệnh: copy plugin + viết agent + launch
├── opencode/plugins/
│   └── agent-teamwork.ts   ← TOÀN BỘ HỆ THỐNG (plugin native)
└── README.md
```
