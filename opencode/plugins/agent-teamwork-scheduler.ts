import { z } from "zod"
function tool(def: any) { return def }
tool.schema = z

// ════════════════════════════════════════════════════════════════════════
//  agent-teamwork-scheduler.ts
//  Bộ nhắc việc + Lịch cá nhân Manager (plugin riêng, không sửa plugin gốc)
//
//  Hai mục chính:
//   A. Bảng tiến độ dự án (Watchdog) — đối chiếu trạng thái Worker (W) và
//      Manager (M). W lấy TỰ ĐỘNG từ Gateway SSE qua bridge (onWorkerEvent),
//      M lấy từ hành động thật của manager qua bridge (onManagerAction).
//   B. Lịch làm việc cá nhân (Calendar) — manager tự lên lịch, đến giờ nhắc.
// ════════════════════════════════════════════════════════════════════════

let _client: any = null
let _managerSid: string | undefined = undefined

const REMIND_INTERVAL_MS = 5 * 60 * 1000        // throttle nhắc thường
const UNCONSUMED_INTERVAL_MS = 2 * 60 * 1000     // unconsumed ưu tiên cao
const BATCH_WINDOW_MS = 60 * 1000                // cửa sổ gộp: nhắc luôn các mục đến lịch trong 1 phút tới

// ── Persist THEO SESSION ─────────────────────────────────────────────────
// Hai file riêng cho mỗi session (tại STATE_DIR):
//   <sid>.cal.json   → LỊCH CÁ NHÂN. Luôn tồn tại, persist qua MỌI lần thoát.
//   <sid>.tasks.json → SỔ GIAO VIỆC (crash-continuity). Ghi tăng dần mỗi lần
//     manager giao task; xóa mục khi kill; xóa sạch khi killall; XÓA CẢ FILE khi
//     thoát CHỦ ĐỘNG (cờ tắt sạch). Còn sót lúc mở lại = phiên trước CRASH thật
//     (kill -9 / mất điện, không kịp xóa) → nhắc !ev resume rồi xóa, bắt đầu sổ mới.
const STATE_DIR = `${process.env.HOME}/.local/share/agent-teamwork/scheduler`

function calFile(): string | undefined {
  return _managerSid ? `${STATE_DIR}/${_managerSid}.cal.json` : undefined
}
function tasksFile(): string | undefined {
  return _managerSid ? `${STATE_DIR}/${_managerSid}.tasks.json` : undefined
}
function saveCal() {
  const f = calFile()
  if (!f) return
  try {
    const fs = require("fs")
    fs.mkdirSync(STATE_DIR, { recursive: true })
    fs.writeFileSync(f, JSON.stringify({ calSeq, calendar: [...calendar.values()] }))
  } catch {}
}
function loadCal() {
  const f = calFile()
  if (!f) return
  try {
    const fs = require("fs")
    const data = JSON.parse(fs.readFileSync(f, "utf8"))
    const now = Date.now()
    calendar.clear()
    for (const ev of (data.calendar || [])) {
      // Lịch lặp quá hạn (đóng app lâu) & CHƯA đang chờ xác nhận → dời tới kỳ kế.
      // Lịch 1 lần quá hạn, hoặc mục đang "chờ xác nhận" (due) → giữ nguyên để
      // tick nhắc tiếp ngay lần quét đầu.
      if (ev.repeat !== "none" && ev.nextAt <= now && !ev.due) ev.nextAt = nextOccurrence(ev, now)
      calendar.set(ev.id, ev)
    }
    if (typeof data.calSeq === "number" && data.calSeq > calSeq) calSeq = data.calSeq
  } catch {}
}
function saveTasks() {
  const f = tasksFile()
  if (!f) return
  try {
    const fs = require("fs")
    fs.mkdirSync(STATE_DIR, { recursive: true })
    if (taskLedger.length === 0) { try { fs.unlinkSync(f) } catch {} ; return }
    fs.writeFileSync(f, JSON.stringify(taskLedger))
  } catch {}
}
// Xóa file sổ giao việc = "cờ tắt sạch". Gọi khi thoát CHỦ ĐỘNG (dispose/exit).
function clearTasksFile() {
  const f = tasksFile()
  if (!f) return
  try { require("fs").unlinkSync(f) } catch {}
}
// Nạp sổ lúc mở session. Có nội dung = phiên trước CRASH (không kịp xóa) →
// nhắc manager việc dang dở rồi xóa file + bắt đầu sổ mới.
function loadTasks() {
  const f = tasksFile()
  if (!f) return
  try {
    const fs = require("fs")
    const arr = JSON.parse(fs.readFileSync(f, "utf8"))
    fs.unlinkSync(f)
    taskLedger = []
    if (Array.isArray(arr) && arr.length) {
      const summary = arr.map((t: TaskLog) => `${t.worker}: ${t.task}`).join(" | ")
      push(`!ev WARN resume ${arr.length} việc dang dở từ phiên trước (worker đã mất khi crash, cần tạo lại worker & giao lại): ${summary}`)
    }
  } catch {}
}


type ItemKind = "task" | "permission" | "ask"
interface Item {
  id: string
  name: string
  kind: ItemKind
  wDone: boolean      // worker side (xong / đã hỏi)
  wAt?: number
  mActed: boolean     // manager side (đã đọc result / đã allow / đã choose)
  mAt?: number
  createdAt: number
  deadline?: number
  lastRemindAt?: number
}
interface CalEvent {
  id: string
  label: string
  nextAt: number
  repeat: "none" | "daily" | "weekly" | "interval"
  hour: number
  minute: number
  dow?: number
  intervalMs?: number  // với repeat="interval": chu kỳ lặp (mọi N phút)
  lastRemindAt?: number
  due?: boolean       // đã tới giờ, đang CHỜ manager cal_done/cal_del (nhắc lại tới khi xác nhận)
  dueAt?: number      // thời điểm tới hạn (để hiển thị "trễ Xm")
}
// Sổ giao việc: mỗi mục = 1 lần manager giao task cho worker. Chỉ để
// crash-continuity, tối giản (worker + tóm tắt task + lúc giao).
interface TaskLog { worker: string; task: string; at: number }

const interactions = new Map<string, Item>()
const calendar = new Map<string, CalEvent>()
let taskLedger: TaskLog[] = []
let seq = 0
let calSeq = 0
let clockTimer: any = null
let pendingBatch: string[] = []   // gom các nhắc "quên" trong 1 tick → 1 lần push
let verbose = false               // bật/tắt log chi tiết mỗi phút

let pushQueue: Promise<void> = Promise.resolve()

async function push(msg: string) {
  const sid = _managerSid
  if (!sid || !_client?.session?.promptAsync) return
  pushQueue = pushQueue
    .then(async () => {
      await _client.session.promptAsync({
        path: { id: sid },
        body: { agent: "manager", parts: [{ type: "text", text: msg }] },
      })
    })
    .catch(() => {})
  await pushQueue
}

// ── helpers ───────────────────────────────────────────────────────────────
function latestPendingTask(name: string): Item | undefined {
  let found: Item | undefined
  for (const it of interactions.values()) {
    if (it.name === name && it.kind === "task" && !it.wDone) {
      if (!found || it.createdAt > found.createdAt) found = it
    }
  }
  return found
}
function latestTaskNotActed(name: string): Item | undefined {
  let found: Item | undefined
  for (const it of interactions.values()) {
    if (it.name === name && it.kind === "task" && !it.mActed) {
      if (!found || it.createdAt > found.createdAt) found = it
    }
  }
  return found
}
function createTask(name: string, now: number, wDone = false): Item {
  const id = `${name}-t${++seq}`
  const it: Item = { id, name, kind: "task", wDone, wAt: wDone ? now : undefined, mActed: false, createdAt: now }
  interactions.set(id, it)
  return it
}
function createItem(name: string, kind: "permission" | "ask", now: number): Item {
  const id = `${name}-${kind[0]}${++seq}`
  const it: Item = { id, name, kind, wDone: true, wAt: now, mActed: false, createdAt: now }
  interactions.set(id, it)
  return it
}
function markActed(name: string, kind: "permission" | "ask") {
  for (const [id, it] of interactions) {
    if (it.name === name && it.kind === kind && it.wDone && !it.mActed) interactions.delete(id)
  }
}

// ── Bridge API (do agent-teamwork.ts gọi qua globalThis) ─────────────────
function onWorkerEvent(name: string, type: string, _p: any) {
  const now = Date.now()
  if (type === "done") {
    const it = latestPendingTask(name)
    if (it) { it.wDone = true; it.wAt = now }
    else createTask(name, now, true)
  } else if (type === "permission.asked") {
    createItem(name, "permission", now)
  } else if (type === "question.asked" || type === "question.v2.asked") {
    createItem(name, "ask", now)
  } else if (type === "died") {
    // worker bị kill/crash → xóa MỌI tương tác của worker này (kể cả đã đọc)
    for (const [id, it] of interactions) {
      if (it.name === name) interactions.delete(id)
    }
  } else if (type === "error") {
    // lỗi model/provider → worker vẫn sống, chỉ xóa các mục chưa xử lý
    for (const [id, it] of interactions) {
      if (it.name === name && !it.mActed) interactions.delete(id)
    }
  }
}
function onManagerAction(name: string, kind: string, detail?: string) {
  const now = Date.now()
  if (kind === "send") {
    createTask(name, now, false)
    // Ghi vào sổ giao việc (crash-continuity). Kill/killall sẽ "đóng sổ".
    taskLedger.push({ worker: name, task: (detail || "").replace(/\s+/g, " ").trim().slice(0, 200), at: now })
    saveTasks()
  } else if (kind === "result") {
    const it = latestTaskNotActed(name)
    if (it) { it.mActed = true; it.mAt = now }
  } else if (kind === "allow") markActed(name, "permission")
  else if (kind === "choose" || kind === "reject") markActed(name, "ask")
  else if (kind === "kill") {
    // Manager đóng sổ cho 1 worker → gỡ mọi mục của worker đó khỏi sổ giao việc.
    taskLedger = taskLedger.filter(t => t.worker !== name)
    saveTasks()
  } else if (kind === "killall") {
    taskLedger = []
    saveTasks()
  }
}

// ── Calendar parsing ──────────────────────────────────────────────────────
const DAY_MAP: any = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 }
function parseWhen(when: string, now: number): CalEvent {
  const tokens = when.trim().split(/\s+/)
  let repeat: "none" | "daily" | "weekly" = "none"
  let i = 0
  if (tokens[i] === "daily") { repeat = "daily"; i++ }
  else if (tokens[i] === "weekly") { repeat = "weekly"; i++ }
  // "in <N>m" | "in <N>h"  (đã split thành 2 token: ["in","30m"])
  if (tokens[i]?.toLowerCase() === "in") {
    const rel = tokens[i + 1]?.match(/^(\d+)(m|h)$/i)
    if (rel) {
      const n = parseInt(rel[1])
      const ms = rel[2].toLowerCase() === "h" ? n * 3600000 : n * 60000
      return { id: "", label: "", nextAt: now + ms, repeat: "none", hour: 0, minute: 0 }
    }
    throw new Error("định dạng thời gian không hợp lệ. VD: 14:30 | daily 09:00 | mon 09:00 | in 30m | every 90m")
  }
  // "every <N>m" | "every <N>h" — lặp mỗi N phút (chu kỳ bất kỳ; 1.5h = every 90m)
  if (tokens[i]?.toLowerCase() === "every") {
    const rel = tokens[i + 1]?.match(/^(\d+)(m|h)$/i)
    if (rel) {
      const n = parseInt(rel[1])
      const ms = rel[2].toLowerCase() === "h" ? n * 3600000 : n * 60000
      if (ms < 60000) throw new Error("chu kỳ lặp tối thiểu 1 phút (bộ nhắc quét mỗi phút)")
      return { id: "", label: "", nextAt: now + ms, repeat: "interval", intervalMs: ms, hour: 0, minute: 0 }
    }
    throw new Error("định dạng chu kỳ không hợp lệ. VD: every 90m | every 30m | every 2h")
  }
  let dow: number | undefined
  if (DAY_MAP[tokens[i]?.toLowerCase()] !== undefined) {
    dow = DAY_MAP[tokens[i].toLowerCase()]
    if (repeat === "none") repeat = "weekly"
    i++
  }
  const hm = tokens[i]?.match(/^(\d{1,2}):(\d{2})$/)
  if (!hm) throw new Error("định dạng thời gian không hợp lệ. VD: 14:30 | daily 09:00 | mon 09:00 | in 30m")
  const hour = parseInt(hm[1]); const minute = parseInt(hm[2])
  const d = new Date(now); d.setSeconds(0, 0); d.setMilliseconds(0)
  d.setHours(hour, minute, 0, 0)
  if (repeat === "weekly") {
    let guard = 0
    while ((d.getTime() <= now || d.getDay() !== dow) && guard < 8) { d.setDate(d.getDate() + 1); d.setHours(hour, minute, 0, 0); guard++ }
  } else {
    if (d.getTime() <= now) d.setDate(d.getDate() + 1)
  }
  return { id: "", label: "", nextAt: d.getTime(), repeat, hour, minute, dow }
}
function repeatLabel(ev: CalEvent): string {
  if (ev.repeat !== "interval") return ev.repeat
  const m = Math.round((ev.intervalMs || 0) / 60000)
  return m % 60 === 0 ? `every ${m / 60}h` : `every ${m}m`
}
function fmtTime(ms: number) {
  const d = new Date(ms)
  const t = new Intl.DateTimeFormat("en-GB", {
    hour: "2-digit", minute: "2-digit",
    timeZoneName: "shortOffset", hour12: false,
  }).formatToParts(d)
  const hhmm = `${t.find(p => p.type === "hour")!.value}:${t.find(p => p.type === "minute")!.value}`
  const tz = t.find(p => p.type === "timeZoneName")!.value
  return `${hhmm} ${tz}`
}
function nextOccurrence(ev: CalEvent, now: number): number {
  if (ev.repeat === "interval") {
    // Căn theo now (không phải ev.nextAt) để khi tick trễ > 1 chu kỳ sẽ
    // co giãn đúng số kỳ bị bỏ, thay vì nhảy chu kỳ và bỏ lỡ cửa sổ OVERDUE.
    const step = ev.intervalMs || 60000
    let n = now + step
    while (n <= now) n += step
    return n
  }
  if (ev.repeat === "daily") {
    const d = new Date(now); d.setSeconds(0, 0); d.setMilliseconds(0); d.setHours(ev.hour, ev.minute, 0, 0)
    if (d.getTime() <= now) d.setDate(d.getDate() + 1)
    return d.getTime()
  }
  if (ev.repeat === "weekly") {
    const d = new Date(now); d.setSeconds(0, 0); d.setMilliseconds(0)
    let guard = 0
    while (d.getDay() !== ev.dow && guard < 8) { d.setDate(d.getDate() + 1); guard++ }
    d.setHours(ev.hour, ev.minute, 0, 0)
    return d.getTime()
  }
  return ev.nextAt
}

// ── Clock loop (mỗi phút) ─────────────────────────────────────────────────
function startClock() {
  if (clockTimer) return
  scheduleNext()
}
function scheduleNext() {
  clockTimer = setTimeout(async () => {
    try {
      await tick()
    } finally {
      // Luôn reschedule dù tick lỗi — nếu không, clockTimer hết hạn mà không
      // được lập lịch lại → scheduler chết vĩnh viễn sau 1 lần tick fail.
      scheduleNext()
    }
  }, 60_000)
}
function stopClock() {
  if (clockTimer) { clearTimeout(clockTimer); clockTimer = null }
}

async function tick() {
  const now = Date.now()
  pendingBatch = []
  const nearCal: CalEvent[] = []
  let trulyDue = 0

  // 1) Lịch cá nhân: tới giờ → chuyển "chờ xác nhận" (due) và nhắc. Sau đó
  //    NHẮC LẠI mỗi REMIND_INTERVAL cho tới khi manager cal_done/cal_del.
  //    KHÔNG tự dời/xóa — buộc manager đóng vòng để không bỏ lỡ.
  for (const [id, ev] of calendar) {
    if (ev.due) {
      if (!ev.lastRemindAt || now - ev.lastRemindAt >= REMIND_INTERVAL_MS) {
        const late = Math.max(0, Math.round((now - (ev.dueAt || now)) / 60000))
        pendingBatch.push(`cal ${id} ${ev.label} @${fmtTime(ev.dueAt || ev.nextAt)}${late ? ` (trễ ${late}m) — gọi cal_done xác nhận` : ""}`)
        ev.lastRemindAt = now
        trulyDue++
      }
    } else if (now >= ev.nextAt) {
      ev.due = true; ev.dueAt = ev.nextAt; ev.lastRemindAt = now
      pendingBatch.push(`cal ${id} ${ev.label} @${fmtTime(ev.nextAt)}`)
      trulyDue++
    } else if (ev.nextAt <= now + BATCH_WINDOW_MS) {
      nearCal.push(ev)
    }
  }

  // 2) Đối chiếu worker/manager: trả về số mục "đã đến lúc nhắc" (truly due).
  //    - STALE (hành động SAI) → push NGAY, KHÔNG tính vào trulyDue, KHÔNG gộp.
  //    - còn lại (quên) → gộp vào pendingBatch.
  trulyDue += reconcile(now)

  // 3) Nếu có ít nhất 1 mục thực sự đến lịch → GỘP LUÔN các mục sắp đến (<=1 phút)
  if (trulyDue > 0) {
    for (const ev of nearCal) {
      if (ev.lastRemindAt && now - ev.lastRemindAt < REMIND_INTERVAL_MS) continue
      pendingBatch.push(`cal ${ev.id} ${ev.label} @${fmtTime(ev.nextAt)} (~${Math.max(1, Math.round((ev.nextAt - now) / 1000))}s)`)
      ev.lastRemindAt = now
    }
  }

  // 4) Chỉ bơm 1 lần nhắc khi có mục đến lịch. Không có gì → KHÔNG báo gì.
  if (pendingBatch.length) {
    await push(`!ev remind ${pendingBatch.length}: ` + pendingBatch.join(" | "))
  }

  // 5) Quét dọn task đã hoàn tất (W & M đều xong > 1 phút)
  for (const [id, it] of interactions) {
    if (it.kind === "task" && it.wDone && it.mActed && it.mAt && now - it.mAt > 60000) interactions.delete(id)
  }

  // 6) Verbose log: bắn toàn bộ trạng thái mỗi phút để debug
  if (verbose) {
    const ts = new Date(now).toTimeString().slice(0, 8)
    const lines: string[] = [`[tick ${ts}]`]

    // interactions
    if (interactions.size === 0) {
      lines.push("  tasks: (empty)")
    } else {
      for (const it of interactions.values()) {
        let state = ""
        if (it.kind === "task") {
          if (it.wDone && it.mActed) state = "COMPLETED"
          else if (it.wDone && !it.mActed) state = "UNCONSUMED"
          else if (!it.wDone && it.mActed) state = "STALE"
          else state = "PENDING"
          if (it.deadline) state += ` dl=${new Date(it.deadline).toTimeString().slice(0, 5)}`
        } else {
          state = it.mActed ? "DONE" : "WAIT"
        }
        const age = Math.round((now - it.createdAt) / 1000)
        lines.push(`  ${it.id} [${it.kind}] ${state} age=${age}s`)
      }
    }

    // calendar
    if (calendar.size === 0) {
      lines.push("  cal: (empty)")
    } else {
      for (const ev of calendar.values()) {
        const till = Math.round((ev.nextAt - now) / 1000)
        lines.push(`  ${ev.id} "${ev.label}" [${repeatLabel(ev)}] in=${till}s`)
      }
    }

    // tick result
    lines.push(`  trulyDue=${trulyDue} batch=${pendingBatch.length} sent=${pendingBatch.length > 0 ? "yes" : "no"}`)
    if (pendingBatch.length) lines.push(`  → ${pendingBatch.join(" | ")}`)
    if (nearCal.length) lines.push(`  nearCal: ${nearCal.map(e => e.id).join(", ")}`)

    await push(lines.join("\n"))
  }

  saveCal()
}

// Trả về số lượng mục "quên" đã đến lúc nhắc (truly due) được gộp vào pendingBatch.
function reconcile(now: number): number {
  let due = 0
  for (const it of interactions.values()) {
    if (it.kind === "task") {
      // 4 trạng thái task (W × M)
      if (it.wDone && !it.mActed) {
        // UNCONSUMED — worker xong, manager chưa đọc result → GỘP BATCH (quên)
        if (!it.lastRemindAt || now - it.lastRemindAt > UNCONSUMED_INTERVAL_MS) {
          pendingBatch.push(`${it.name} unconsumed ${Math.max(1, Math.round((now - (it.wAt || now)) / 60000))}m`)
          it.lastRemindAt = now; due++
        }
      } else if (!it.wDone && it.mActed) {
        // STALE — manager đọc trước khi worker xong (luồng SAI) → NHẮC NGAY, không gộp
        if (!it.lastRemindAt || now - it.lastRemindAt > REMIND_INTERVAL_MS) {
          push(`!ev ${it.name} stale (manager đọc result trước khi worker xong)`)
          it.lastRemindAt = now
        }
      } else if (!it.wDone && !it.mActed && it.deadline && now > it.deadline) {
        // PENDING quá deadline → GỘP BATCH
        if (!it.lastRemindAt || now - it.lastRemindAt > REMIND_INTERVAL_MS) {
          pendingBatch.push(`${it.name} overdue ${Math.max(1, Math.round((now - (it.deadline || now)) / 60000))}m`)
          it.lastRemindAt = now; due++
        }
      }
    } else {
      // permission / ask: worker chờ, manager chưa xử lý → GỘP BATCH
      if (it.wDone && !it.mActed) {
        if (!it.lastRemindAt || now - it.lastRemindAt > REMIND_INTERVAL_MS) {
          const ev = it.kind === "permission" ? "permission_wait" : "ask_wait"
          pendingBatch.push(`${it.name} ${ev} ${Math.max(1, Math.round((now - (it.wAt || now)) / 60000))}m`)
          it.lastRemindAt = now; due++
        }
      }
    }
  }
  return due
}

// ── Tools cho Manager ─────────────────────────────────────────────────────
const tools = {
  task_list: tool({
    description: "Show progress board: task/permission/ask per worker + calendar.",
    args: {},
    async execute() {
      const lines: string[] = ["== TIẾN ĐỘ DỰ ÁN =="]
      const byName = new Map<string, string[]>()
      for (const it of interactions.values()) {
        let st = ""
        if (it.kind === "task") {
          st = it.wDone ? (it.mActed ? "COMPLETED" : "UNCONSUMED")
            : (it.mActed ? "STALE" : "PENDING" + (it.deadline ? " (dl " + new Date(it.deadline).toTimeString().slice(0, 5) + ")" : ""))
        } else st = it.mActed ? "DONE" : "WAIT"
        const arr = byName.get(it.name) || []
        arr.push(`    [${it.kind}] ${st}`)
        byName.set(it.name, arr)
      }
      if (byName.size === 0) lines.push("  (chưa có task/permission/ask)")
      for (const [n, arr] of byName) { lines.push(`• ${n}`); lines.push(...arr) }
      lines.push("== LỊCH CÁ NHÂN ==")
      if (calendar.size === 0) lines.push("  (trống)")
      const nowc = Date.now()
      for (const ev of calendar.values()) {
        const st = ev.due
          ? `🔔 chờ xác nhận (trễ ${Math.max(0, Math.round((nowc - (ev.dueAt || nowc)) / 60000))}m)`
          : `⏰ ${new Date(ev.nextAt).toTimeString().slice(0, 5)}`
        lines.push(`  ${ev.id} ${st} [${repeatLabel(ev)}] ${ev.label}`)
      }
      return lines.join("\n")
    },
  }),

  task_deadline: tool({
    description: "Set deadline (min) on worker latest task; overdue -> !ev X overdue.",
    args: { name: tool.schema.string(), minutes: tool.schema.string() },
    async execute(args: any) {
      const it = latestPendingTask(args.name)
      if (!it) return "(không có task đang chờ)"
      const m = parseInt(args.minutes)
      if (isNaN(m)) throw new Error("minutes không hợp lệ")
      it.deadline = Date.now() + m * 60000
      return `${args.name} deadline +${m}m`
    },
  }),

  cal_add: tool({
    description: 'Add calendar event. when: HH:MM | in <N>m|h | daily HH:MM | <dow> HH:MM | every <N>m|h (any interval, 1.5h=90m).',
    args: { label: tool.schema.string(), when: tool.schema.string() },
    async execute(args: any) {
      if (ensureRunning()) push("!ev scheduler ready")
      const ev = parseWhen(args.when, Date.now())
      ev.id = `cal-${++calSeq}`
      ev.label = args.label
      calendar.set(ev.id, ev)
      saveCal()
      return `+${ev.id} ${new Date(ev.nextAt).toTimeString().slice(0, 5)} [${repeatLabel(ev)}] ${ev.label}`
    },
  }),

  cal_list: tool({
    description: "List calendar (status: upcoming / awaiting-confirm).",
    args: {},
    async execute() {
      if (calendar.size === 0) return "(trống)"
      const now = Date.now()
      return [...calendar.values()].map(ev => {
        const st = ev.due
          ? `🔔 chờ xác nhận (trễ ${Math.max(0, Math.round((now - (ev.dueAt || now)) / 60000))}m)`
          : `⏰ ${new Date(ev.nextAt).toTimeString().slice(0, 5)}`
        return `${ev.id} ${st} [${repeatLabel(ev)}] ${ev.label}`
      }).join("\n")
    },
  }),

  cal_done: tool({
    description: "Confirm event done (this occurrence), on !ev cal due. One-time->deleted; repeat->next occurrence.",
    args: { id: tool.schema.string() },
    async execute(args: any) {
      const ev = calendar.get(args.id)
      if (!ev) return "(không tìm thấy)"
      if (ev.repeat === "none") {
        calendar.delete(args.id)
        saveCal()
        return `done ${args.id} (đã xóa)`
      }
      ev.nextAt = nextOccurrence(ev, Date.now())
      ev.due = false; ev.dueAt = undefined; ev.lastRemindAt = undefined
      saveCal()
      return `done ${args.id} → kỳ kế ${new Date(ev.nextAt).toTimeString().slice(0, 5)}`
    },
  }),

  cal_del: tool({
    description: "Delete calendar event permanently.",
    args: { id: tool.schema.string() },
    async execute(args: any) {
      if (calendar.delete(args.id)) { saveCal(); return `-${args.id}` }
      return "(không tìm thấy)"
    },
  }),

  scheduler_start: tool({
    description: "Start reminder clock if not running.",
    args: {},
    async execute() {
      const started = ensureRunning()
      if (started) push("!ev scheduler ready")
      return clockTimer ? (started ? "scheduler ready" : "scheduler running") : "scheduler stopped"
    },
  }),

  scheduler_verbose: tool({
    description: "Toggle per-minute debug log [on|off].",
    args: { on: tool.schema.string().optional() },
    async execute(args: any) {
      if (args.on === "on" || args.on === "1" || args.on === "true") verbose = true
      else if (args.on === "off" || args.on === "0" || args.on === "false") verbose = false
      else verbose = !verbose
      return `verbose ${verbose ? "ON" : "OFF"}`
    },
  }),
}

// Bộ nhắc KHÔNG chạy lúc mở opencode — chỉ khởi động khi Manager thực sự dùng
// (tạo worker/gửi task/thêm lịch) hoặc khi gọi scheduler_start. Tránh bơm
// !ev vào các session không phải Manager.
function ensureRunning(): boolean {
  if (!clockTimer) {
    startClock()
    return true   // vừa khởi động
  }
  return false    // đã chạy sẵn
}

export const AgentTeamworkScheduler = async ({ client }: any) => {
  _client = client
  // loadCal()/loadTasks() thật sự chạy trong event hook khi đã biết sessionID.
  ;(globalThis as any).__atwScheduler = {
    onWorkerEvent: (name: string, type: string, p: any) => { if (ensureRunning()) push("!ev scheduler ready"); onWorkerEvent(name, type, p) },
    onManagerAction: (name: string, kind: string, detail?: string) => { if (ensureRunning()) push("!ev scheduler ready"); onManagerAction(name, kind, detail) },
  }

  // Cờ tắt sạch: thoát CHỦ ĐỘNG → xóa file sổ giao việc → phiên sau KHÔNG nhắc.
  // dispose() lo trường hợp opencode tắt plugin đúng cách; "exit" là lưới đỡ khi
  // process kết thúc bình thường. CRASH thật không chạy được đây → file còn lại.
  process.on("exit", () => { try { clearTasksFile() } catch {} })

  return {
    async dispose() {
      clearTasksFile()
      stopClock()
      ;(globalThis as any).__atwScheduler = undefined
    },
    event: async ({ event }: any) => {
      const sid = event?.properties?.sessionID
        || event?.properties?.info?.sessionID
        || event?.properties?.info?.id
      if (sid && typeof sid === "string" && sid.startsWith("ses_") && sid !== _managerSid) {
        _managerSid = sid
        loadCal()
        loadTasks()
        if (calendar.size > 0) ensureRunning()
      }
    },
    tool: tools,
  }
}
