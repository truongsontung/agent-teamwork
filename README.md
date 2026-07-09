# Agent Teamwork

Hệ thống Manager → Worker cho opencode. Manager phân rã task, Worker thực thi song song với context biệt lập — giảm token 3-5x.

## Yêu cầu

- `tmux` `jq` `curl` `ss` (hoặc `lsof`)
- `opencode` trong PATH

```bash
sudo apt install tmux jq curl
```

## Dùng ngay sau khi clone

```bash
# 1. Clone về đâu cũng được
git clone https://github.com/truongsontung/agent-teamwork.git ~/agent-teamwork

# 2. Vào thư mục dự án của bạn
cd ~/my-project

# 3. Chạy setup (tạo ./agent + launch Manager trong tmux)
~/agent-teamwork/setup.sh

# 4. Mở terminal khác, attach vào tmux để nói chuyện với Manager
tmux attach -t agent-teamwork
```

Manager đã sẵn sàng trong tmux window. Gõ task cho nó:

```
Xây dựng hệ thống login với JWT, gồm API backend, bảng DB, form frontend
```

Manager sẽ tự động:
- Phân rã → 3 worker (backend, db, frontend)
- Tạo `./agent create`, gửi `./agent send-async`, poll `./agent status`
- Gom kết quả `./agent result`, báo cáo lại cho bạn

## Dừng

```bash
# Ctrl+C ở terminal chạy setup.sh
# Hoặc: đóng tmux window Manager → daemon tự dọn
```

Tự động: kill toàn bộ worker + xoá `.worker/` + xoá `./agent` + xoá agent files.

## Manager thấy gì

Manager KHÔNG biết agent-teamwork cài ở đâu. Nó chỉ thấy:

```
$ ls
agent    src/    package.json    ...

$ ./agent create Worker-1
+Worker-1

$ ./agent send-async Worker-1 "nhiệm vụ"
+

$ ./agent status Worker-1
idle

$ ./agent result Worker-1
...kết quả text...

$ ./agent kill Worker-1
-Worker-1
```

Tất cả đều là black-box — giống như gõ `opencode` mà không cần biết code ở đâu.

## API ./agent

| Lệnh | Output |
|---|---|
| `create <name> [model]` | `+name` |
| `send-async <name> "<task>"` | `+` |
| `status <name>` | `idle` \| `running` \| `permission` \| `error` \| `dead` |
| `status-all` | `name status` mỗi dòng |
| `result <name>` | text kết quả |
| `permission-info <name>` | `tool=X id=Y` + args |
| `allow <name>` / `deny <name>` | `ok` |
| `kill <name>` | `-name` |
| `killall` | số worker bị kill |
| `dashboard` | `name status` mỗi dòng |

## Cấu hình

Sửa `~/agent-teamwork/manager.json` và `~/agent-teamwork/worker.json` trước khi chạy setup nếu cần đổi model, permission, max_workers.

## Cấu trúc

```
~/agent-teamwork/           ← clone về đây, không đụng sau setup
├── manager.json
├── worker.json
├── serve_controller.sh
├── setup.sh
└── README.md

~/my-project/               ← dự án của bạn
├── agent                   ← wrapper (tự tạo/xoá bởi setup)
├── .worker/                ← state dir (tự tạo/xoá)
├── .opencode/              ← config Manager (tự tạo)
└── src/ ...                ← code dự án
```
