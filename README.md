# Agent Teamwork

Cài 1 lần — dùng mọi project. Manager trong opencode TUI, điều phối worker song song.

```bash
git clone https://github.com/truongsontung/agent-teamwork.git ~/agent-teamwork
~/agent-teamwork/install.sh
```

Xong. Mở opencode ở **bất kỳ project nào** → bấm **Tab** → Manager sẵn sàng.

## Dùng

Trong Manager TUI, gõ task:

```
Xây dựng login JWT: API backend + bảng DB + form frontend
```

Manager tự phân rã → `worker_create` → `worker_send` → đợi `!ev done` → gom kết quả.

## Cấu hình

| File | Để làm gì |
|---|---|
| `~/.config/opencode/agents/manager.md` | Model Manager, prompt, permission |
| `~/.config/opencode/worker.json` | Model Worker mặc định, max_workers |
| `~/.config/opencode/plugins/agent-teamwork.ts` | Plugin (không cần sửa) |

Đổi model Manager: sửa dòng `model:` trong `manager.md`.
Đổi model Worker: sửa `model` trong `worker.json`.

## Cài đặt thủ công

Nếu không muốn dùng `install.sh`:

```bash
cp opencode/plugins/agent-teamwork.ts ~/.config/opencode/plugins/
cp worker.json ~/.config/opencode/
# Tự tạo ~/.config/opencode/agents/manager.md từ manager.json
```

## Gỡ

```bash
rm ~/.config/opencode/plugins/agent-teamwork.ts
rm ~/.config/opencode/agents/manager.md
```

## Cấu trúc repo

```
agent-teamwork/
├── install.sh              ← Cài toàn cục 1 lần
├── manager.json            ← Nguồn prompt Manager
├── worker.json             ← Config worker
├── opencode/plugins/
│   └── agent-teamwork.ts   ← Plugin (380 dòng TypeScript)
└── README.md
```
