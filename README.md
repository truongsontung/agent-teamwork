# Agent Teamwork

1 lệnh duy nhất. Manager TUI mở ngay terminal. Không tmux.

## Dùng

```bash
# Clone 1 lần
git clone https://github.com/truongsontung/agent-teamwork.git ~/agent-teamwork

# Mỗi lần cần làm dự án:
cd ~/my-project
~/agent-teamwork/setup.sh
```

Terminal của bạn trở thành Manager TUI ngay lập tức. Gõ task:

```
Xây dựng hệ thống login JWT: backend API + bảng DB + form frontend
```

Manager tự phân rã → tạo worker → giao việc → gom kết quả → báo cáo.

**Bot chạy ngầm** giám sát worker, bắt sự kiện permission/idle/error. Manager dùng `./agent status` để đọc.

**Thoát:** nhấn Ctrl+C trong opencode TUI → bot dọn worker + xoá temp → exit.

## Yêu cầu

- `jq` `curl`
- `opencode` trong PATH

```bash
sudo apt install jq curl
```

## Manager dùng gì

Manager thấy `./agent` trong project — black-box, không biết cài ở đâu:

```
./agent create Worker-1          → +Worker-1
./agent send-async Worker-1 ".." → +
./agent status Worker-1          → idle
./agent result Worker-1          → ...kết quả...
./agent kill Worker-1            → -Worker-1
```

## Cấu hình

Sửa `~/agent-teamwork/manager.json` (model, permission Manager) hoặc `worker.json` (model, max_workers, permission Worker) trước khi setup.

## Cấu trúc sau setup

```
~/agent-teamwork/          ← clone, không đụng
~/my-project/              ← dự án
├── agent                  ← wrapper (tự sinh/xoá)
├── .worker/               ← state dir (tự sinh/xoá)
├── .opencode/             ← config Manager (tự sinh, giữ lại)
└── src/ ...               ← code của bạn
```
