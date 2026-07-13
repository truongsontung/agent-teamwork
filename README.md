# Agent Teamwork

Cài 1 lần — dùng mọi project. Bấm **Tab** để chuyển sang Manager, điều phối worker song song ngay trong opencode TUI.

## Cài đặt

### Cách 1 — từ npm (nhanh nhất)

```bash
npx agent-teamwork
```

Yêu cầu: đã cài `opencode`, và có sẵn `jq` + `python3` (installer dùng để ghi config).

### Cách 2 — từ source

```bash
git clone https://github.com/truongsontung/agent-teamwork.git ~/agent-teamwork
~/agent-teamwork/install.sh
```

Cả hai cách đều cài vào `~/.config/opencode/`:
- `plugins/agent-teamwork.ts` — plugin chính (bridge điều phối worker)
- `plugins/agent-teamwork-scheduler.ts` — plugin nhắc việc + lịch cá nhân
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
│   ├── Log monitor fallback (poll log file 1s, detect rate limit/quota)
│   └── session.promptAsync("!ev X done") → gửi thẳng vào session Manager
│
└── Workers (opencode serve, port 4091+)
    └── Context độc lập, model config riêng
```

**Manager không có quyền read/edit/write** — mọi thao tác code phải qua worker. Plugin bắn sự kiện `!ev` **thẳng vào session** của Manager (qua `session.promptAsync`), Manager xử lý ngay không cần poll.

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
| `worker_choose <tên> <label\|index>` | Trả lời question worker — hỗ trợ single & multiple choice (`[multi]`) |
| `worker_choose <tên> "1,3"` | Chọn nhiều option (multiple-choice, gửi `1,3` cho worker) |
| `worker_reject <tên>` | Từ chối question của worker |
| `worker_kill <tên>` | Hủy worker |
| `worker_killall` | Hủy tất cả workers |

## Events (!ev)

Manager nhận events **gửi thẳng vào session** (plugin dùng `session.promptAsync`, không đụng ô input chung của TUI):

| Event | Ý nghĩa |
|-------|----------|
| `!ev <tên> started` | Worker bắt đầu xử lý |
| `!ev <tên> permission <type>` | Worker cần duyệt quyền |
| `!ev <tên> ask <header> Q1: <câu hỏi> [multi] (opt1\|opt2\|opt3)` | Worker đang hỏi, chờ Manager tick chọn qua `worker_choose` |
| `!ev <tên> done` | Worker hoàn thành task |
| `!ev <tên> error [cls] <msg>` | Worker gặp lỗi. `cls` = quota/ratelimit/auth/context/network/model (phân loại lỗi model/provider) |
| `!ev <tên> died exit=<code>` | Worker process bị killed |

## Log monitor fallback

SSE không phải lúc nào cũng emit `session.error` khi model provider trả về rate limit/quota error. Plugin có cơ chế **fallback** — monitor file log của worker:

```
/tmp/oc-<port>/opencode/log/opencode.log
```

**Cơ chế hoạt động:**
1. Poll mỗi **1 giây**, so sánh file size
2. Đọc bytes mới, dùng `classifyModelError()` detect patterns:
   - **Rate limit** (429, `too many requests`, `throttle`, `rate_limit`, `retry-after`...)
   - **Quota** (`exceeded`, `out of credits`, `insufficient`, `quota_exceeded`...)
3. Nếu detect → push `!ev <worker> error [ratelimit|quota] <message>` tới Manager

Đây là **bảo vệ kép** — SSE handler vẫn là primary, log monitor là fallback.

## Race condition fix

Trường hợp SSE `complete` event đến **trước** provider error (race condition):
- Trước: SSE handlers reject rate limit/quota errors khi `done=true`
- Sau: **Cho phép pass through** kể cả khi `done=true`, đảm bảo Manager luôn nhận được lỗi từ provider

## Cơ chế bơm sự kiện (`session.promptAsync`)

Plugin đẩy `!ev` vào Manager bằng cách gọi thẳng `client.session.promptAsync` tới **đúng session** của Manager (session ID bắt tự động qua `event` hook), thay vì ghi vào ô input chung của TUI.

**Vì sao không dùng `appendPrompt` + `submitPrompt` nữa** — cách cũ ghi vào ô input chung gây 2 lỗi:
1. Khi Manager **idle** và user đang gõ prompt dở → `appendPrompt` chèn `!ev` vào chung, `submitPrompt` đẩy **cả prompt dở của user lẫn `!ev`** đi cùng lúc.
2. Khi tick đến lúc Manager **đang thinking** → text kẹt lại trong ô input, tick sau đẩy dồn cả hai vào một lượt.

`session.promptAsync` ghi thẳng vào session (hiện trong hội thoại + kích hoạt Manager, non-blocking) nên **không đụng ô input** → cả 2 lỗi biến mất. Áp dụng cho cả bridge (`agent-teamwork.ts`) và scheduler (`agent-teamwork-scheduler.ts`).

## Thay đổi gần đây

| Thay đổi | Chi tiết |
|----------|----------|
| **Bơm `!ev` qua `session.promptAsync`** | Gửi thẳng vào session Manager thay cho `appendPrompt`/`submitPrompt` — sửa lỗi lẫn với prompt dở của user & kẹt input khi thinking |
| **Log monitor fallback** | Monitor log file detect rate limit/quota errors khi SSE không emit error event |
| **Race condition fix** | SSE error handlers cho phép rate limit/quota pass through kể cả khi `done=true` |
| **worker_killall fix** | `worker_killall` giờ cũng clear `starting` map (trước chỉ clear `workers`) |
| **Tick-ask multi-choice** | `worker_choose` hỗ trợ multiple-choice: `worker_choose X "1,3"` |

## Bộ nhắc việc & Lịch cá nhân (Scheduler plugin)

Plugin riêng `agent-teamwork-scheduler.ts` (cùng codebase, deploy qua `install.sh`) cung cấp 2 mục:

**Thời điểm hoạt động:** bộ nhắc CHỈ chạy trong phiên Manager. Nó **tự khởi động** ngay khi Manager bắt đầu dùng worker (tạo/gửi task) hoặc thêm lịch cá nhân, và cũng có thể bật thủ công bằng `scheduler_start`. Clock **không** chạy lúc mở opencode → không bơm `!ev` vào các session không phải Manager.

### 1. Bảng tiến độ dự án (Watchdog — đối chứng Worker × Manager)
Theo dõi mọi tương tác worker↔manager qua **4 trạng thái task** kết hợp 2 trục độc lập:

| Worker (W) | Manager (M) | Trạng thái | Nhắc |
|------------|-------------|------------|------|
| chưa xong | chưa đọc | PENDING | quá deadline → `overdue` |
| chưa xong | đã đọc | STALE | `stale` (cảnh báo luồng sai) |
| **đã xong** | **chưa đọc** | **UNCONSUMED** | `!ev X unconsumed` → đọc result ngay |
| đã xong | đã đọc | COMPLETED | xong, tự xóa |

Cộng thêm `permission_wait` / `ask_wait` khi worker chờ manager duyệt quyền / tick-chọn quá hạn.
- W (worker) lấy **tự động** từ Gateway SSE qua bridge (không phụ thuộc manager nhớ báo) → giải quyết triệt để "worker xong mà manager quên đọc".
- M (manager) lấy từ hành động thật (`worker_result` / `worker_allow` / `worker_choose` / `worker_reject`).

**Nhắc việc thông minh (smart batch):** bộ nhắc **quét mỗi phút** nhưng **chỉ bơm `!ev remind` khi có mục thực sự đến lịch** — nếu quét qua không có gì đến lịch thì không báo gì. Khi 1 mục đến lịch, các hành động **quên** (`unconsumed` / `overdue` / `permission_wait` / `ask_wait` / `cal due`) và các mục **sắp đến trong 1 phút tới** được **gộp chung 1 lần** thành `!ev remind N: <mục1> | <mục2> | ...` (mỗi mục: `<tên> <loại> <thời_gian>` hoặc `cal <id> <label>`). Riêng hành động **sai** (`stale` — đọc result trước khi worker xong) được **nhắc ngay, riêng biệt**, không gộp — vì cần xử lý khẩn cấp.

### 2. Lịch làm việc cá nhân (Calendar)
Manager tự lên lịch và đến giờ được nhắc (chỉ nhắc, không tự động gửi task):

```
cal_add "daily report" daily 09:00
cal_add "standup" mon 09:00
cal_add "check quota" in 30m
cal_add "poll build" every 90m     # lặp mỗi N phút (chu kỳ bất kỳ: 1.5h = every 90m)
cal_add "sync" 14:30
cal_list                 # ⏰ sắp tới / 🔔 chờ xác nhận
cal_done <id>            # đã làm kỳ này (1-lần→xóa, lặp→dời kỳ kế)
cal_del <id>             # bỏ hẳn (dừng vĩnh viễn)
```

Các dạng `<when>`: `HH:MM` (1-lần) · `in <N>m|h` (1-lần sau N) · `daily HH:MM` · `<thứ> HH:MM` (mon…sun, lặp tuần) · `every <N>m|h` (lặp mỗi N phút, chu kỳ bất kỳ — manager tự quy đổi ra phút).

**Nhắc tới khi xác nhận (không bỏ lỡ):** đến giờ → `!ev cal due <id> <label>`, và **nhắc lại mỗi 5 phút** cho tới khi Manager đóng vòng bằng `cal_done` (đã làm) hoặc `cal_del` (bỏ hẳn). Lịch **1-lần** `cal_done` → xóa; lịch **lặp** `cal_done` → dời sang kỳ kế và ngừng nhắc tới kỳ đó.

### Công cụ mới (Manager)
| Tool | Mô tả |
|------|-------|
| `task_list` | Xem bảng tiến độ (task/permission/ask + lịch) |
| `task_deadline <tên> <phút>` | Đặt deadline → quá hạn chưa xong báo `overdue` |
| `cal_add / cal_list / cal_done / cal_del` | Lịch cá nhân |
| `doc_read <path\|glob>` | Đọc **đúng 1 tài liệu** cho Manager (vd `~/kich_ban/01*`); khớp nhiều file → trả danh sách để chọn |
| `scheduler_start` | Bật thủ công bộ nhắc (thường tự bật khi Manager dùng worker/thêm lịch) |
| `scheduler_verbose <on\|off>` | Bật/tắt log chi tiết mỗi phút (mặc định off, reset khi restart) |

### Lưu trạng thái theo session (persist)

Dữ liệu lưu theo từng session tại `~/.local/share/agent-teamwork/scheduler/`, mỗi session **2 file riêng**:

**`<sessionID>.cal.json` — Lịch cá nhân.** Luôn tồn tại, **persist qua mọi lần thoát**. Mở lại đúng session (restart opencode) → lịch tự nạp lại và bộ nhắc chạy tiếp:
- Lịch **lặp** (`daily`/`weekly`) quá hạn trong lúc đóng app → tự dời tới lần kế tiếp.
- Lịch **1 lần** đã qua giờ → báo "đã lỡ" ngay lần quét đầu.
- Mục đang **🔔 chờ xác nhận** (due) → giữ nguyên, tiếp tục nhắc sau restart.

**`<sessionID>.tasks.json` — Sổ giao việc (crash-continuity).** Ghi tăng dần mỗi lần Manager `worker_send` (chỉ lưu `{worker, tóm tắt task, lúc giao}`). Cơ chế "cờ tắt sạch":
- `worker_kill` → gỡ mục của worker đó; `worker_killall` → xóa sạch ("đóng sổ").
- **Thoát chủ động** (Ctrl+C / opencode tắt plugin đúng cách) → **xóa cả file** → phiên sau **không** nhắc.
- **Crash thật** (kill -9, mất điện, OOM) → không kịp xóa → file còn lại → phiên sau phát `!ev resume N <...>` để Manager tạo lại worker & giao lại việc dang dở, rồi xóa file (bắt đầu sổ mới).

Lý do sổ giao việc tối giản: worker là process riêng, **crash là mất sạch dữ liệu** → chỉ cần nhớ "đã giao việc gì cho ai" để giao lại, không khôi phục kết quả chi tiết. Worker **died** (kể cả bị cleanup kill khi Ctrl+C) **không** tự gỡ khỏi sổ — chỉ `worker_kill/killall` do Manager chủ động mới đóng sổ.

### Tách tool: chỉ Manager thấy tool teamwork

Plugin đăng ký tool ở phạm vi **toàn cục** → mặc định mọi agent (`build`, `plan`, …) đều thấy `worker_*`/`cal_*`/`task_*`/`scheduler_*`. Để tách biệt, `install.sh` dùng cơ chế permission của opencode:

- **opencode.json** (global): `permission` deny các mẫu `worker_*`, `cal_*`, `task_*`, `scheduler_*` → **ẩn khỏi mọi agent** (opencode loại tool có permission khớp cuối cùng là `pattern:"*" action:"deny"` khỏi danh sách gửi cho model, nên `build` **không thấy** luôn).
- **manager.md** (agent frontmatter): `permission` **allow** lại các mẫu đó. Vì permission riêng của agent được ghép **sau cùng** (thắng theo "findLast"), Manager thấy đầy đủ tool teamwork, còn các agent khác thì không.

Kết quả: `build`/`plan` chỉ thấy tool code thường; Manager chỉ thấy tool điều phối (đã deny sẵn read/edit/write/bash…).

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
# từ npm
npx agent-teamwork@latest

# hoặc từ source
cd ~/agent-teamwork && git pull && ./install.sh
```

## Gỡ bỏ

```bash
rm ~/.config/opencode/plugins/agent-teamwork.ts
rm ~/.config/opencode/plugins/agent-teamwork-scheduler.ts
rm ~/.config/opencode/agents/manager.md
rm -rf ~/.local/share/agent-teamwork    # xóa lịch đã lưu theo session
```

## License

ISC
