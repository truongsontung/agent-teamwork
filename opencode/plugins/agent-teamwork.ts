import { z } from "zod"
function tool(def: any) { return def }
tool.schema = z

// Phân loại lỗi model/provider thành nhãn ngắn để Manager dễ phản ứng
function classifyModelError(s: string): string {
  const t = (s || "").toLowerCase()
  if (/(rate.?limit|too many requests|429|slow down|throttl)/.test(t)) return "ratelimit"
  // context phải kiểm tra TRƯỚC quota, vì "exceeded" cũng nằm trong cụm context overflow
  if (/(context|token).*(overflow|exceed|too long)|maximum context|context length/.test(t)) return "context"
  if (/(quota|limit reached|out of (credits|requests)|usage limit|credit)/.test(t)) return "quota"
  if (/(auth|api[ _-]?key|unauthor|invalid key|401|403|permission denied)/.test(t)) return "auth"
  if (/(content.?filter|moderat|blocked by)/.test(t)) return "contentfilter"
  if (/(network|econnrefused|enotfound|timeout|fetch failed|connection)/.test(t)) return "network"
  return "model"
}

function extractErrorText(raw: any, p: any): { text: string; tag: string } {
  const errObj: any = (p && p.error) || (raw && raw.error) || null
  if (!errObj) return { text: "session error (không có chi tiết)", tag: "" }
  if (typeof errObj === "string") return { text: errObj, tag: "" }
  const text = errObj.message || errObj.error || errObj.reason || JSON.stringify(errObj)
  const tag = errObj._tag || errObj.name || errObj.status || ""
  return { text: String(text), tag: String(tag) }
}

let _client: any = null
let _lastSessionID: string | undefined = undefined

function loadWorkerConfig(): { model: string; max_workers: number } {
  try {
    const cfgPath = `${process.env.HOME}/.config/opencode/worker.json`
    const file = require("fs").readFileSync(cfgPath, "utf-8")
    const cfg = JSON.parse(file)
    return { model: cfg.model || "zen-proxy/deepseek-v4-flash-free", max_workers: cfg.max_workers || 5 }
  } catch {
    return { model: "zen-proxy/deepseek-v4-flash-free", max_workers: 5 }
  }
}

const workers = new Map<string, WorkerGateway>()
const starting = new Map<string, number>()
let portCursor = 4091

let pushQueue: Promise<void> = Promise.resolve()

class PortInUseError extends Error {}

async function pushManagerEvent(msg: string) {
  pushQueue = pushQueue
    .then(async () => {
      const sid = _lastSessionID
      if (!sid || !_client?.session?.promptAsync) return
      // Gửi thẳng vào session (hiện trong hội thoại + kích hoạt manager),
      // KHÔNG dùng ô input chung → tránh 2 bug: chèn vào prompt dở của user,
      // và kẹt input khi manager đang thinking.
      await _client.session.promptAsync({
        path: { id: sid },
        body: { parts: [{ type: "text", text: msg }] },
      })
    })
    .catch(() => {})
  await pushQueue
}

class WorkerGateway {
  name: string
  port: number
  proc: any
  sessionId: string
  model: string
  done = false
  dead = false
  awaitingTask = false
  hasTask = false
  taskSent = false
  lastResult = ""
  pendingPermission?: string
  pendingQuestion?: string
  pendingQuestionLabels: string[] = []
  pendingQuestionMultiple = false
  private monitorAbort = new AbortController()
  private exitHandled = false
  private stderrMonitorAbort = new AbortController()

  constructor(name: string, port: number, proc: any, sid: string, model: string) {
    this.name = name; this.port = port; this.proc = proc
    this.sessionId = sid; this.model = model
  }

  private async push(msg: string) {
    await pushManagerEvent(msg)
  }

  private startStderrMonitor() {
    const fs = require("fs")
    const logPath = `/tmp/oc-${this.port}/opencode/log/opencode.log`

    ;(async () => {
      let lastSize = 0
      try {
        while (!this.dead && !this.stderrMonitorAbort.signal.aborted) {
          try {
            if (!fs.existsSync(logPath)) {
              await Bun.sleep(1000)
              continue
            }
            const stat = fs.statSync(logPath)
            if (stat.size > lastSize) {
              const fd = fs.openSync(logPath, "r")
              const buf = Buffer.alloc(stat.size - lastSize)
              fs.readSync(fd, buf, 0, buf.length, lastSize)
              fs.closeSync(fd)
              lastSize = stat.size

              const text = buf.toString("utf-8")
              const cls = classifyModelError(text)
              if (cls === "ratelimit" || cls === "quota") {
                if (!this.done) {
                  this.done = true
                  await this.push(`!ev ${this.name} error [${cls}] ${text.trim().split("\n").pop() || text}`)
                }
                break
              }
            }
          } catch {}
          await Bun.sleep(1000)
        }
      } catch {}
    })()
  }

  startMonitor() {
    this.startStderrMonitor()
    this.monitorTask = (async () => {
      let running = true
      let backoff = 1000

      this.proc.exited
        .then((code: number) => this.handleExit(code))
        .catch(() => this.handleExit("unknown"))
        .finally(() => { running = false })

      while (running && !this.dead) {
        try {
          const r = await fetch(`http://127.0.0.1:${this.port}/event`, {
            signal: this.monitorAbort.signal,
          })
          if (!r.ok || !r.body) {
            await Bun.sleep(backoff)
            backoff = Math.min(backoff * 2, 10000)
            continue
          }
          backoff = 1000

          const reader = r.body.getReader()
          const decoder = new TextDecoder()
          let buf = ""

          while (running && !this.dead) {
            let chunk: any
            try { chunk = await reader.read() } catch { break }
            if (chunk.done) break

            buf += decoder.decode(chunk.value, { stream: true })
            const lines = buf.split("\n"); buf = lines.pop() || ""

            for (const line of lines) {
              const data = line.startsWith("data: ") ? line.slice(6) : line.startsWith("data:") ? line.slice(5).trimStart() : ""
              if (!data) continue
              let raw: any
              try { raw = JSON.parse(data) } catch { continue }
              const p = raw.properties || {}
              if (p.sessionID && p.sessionID !== this.sessionId) continue

              try {
                await this.onEvent(raw, p)
              } catch (e: any) {
                console.error(`[GW:${this.name}] onEvent error: ${e.message || e}`)
              }
            }
          }
        } catch {
          if (this.monitorAbort.signal.aborted) return
          if (running) await Bun.sleep(backoff)
          backoff = Math.min(backoff * 2, 10000)
        }
      }
    })().catch(() => {})
  }
  private monitorTask: Promise<void> | null = null

  private async handleExit(code: number | string) {
    if (this.exitHandled) return
    this.exitHandled = true
    if (this.dead) return

    this.dead = true
    this.monitorAbort.abort()
    this.stderrMonitorAbort.abort()
    if (workers.get(this.name) === this) workers.delete(this.name)
    await this.push(`!ev ${this.name} died exit=${code}`)
    try { (globalThis as any).__atwScheduler?.onWorkerEvent(this.name, "died", {}) } catch {}
    await Bun.spawn(["rm", "-rf", `/tmp/oc-${this.port}`]).exited
  }

  private async onEvent(raw: any, p: any) {
    try { (globalThis as any).__atwScheduler?.onWorkerEvent(this.name, raw.type, p) } catch {}
    const t = raw.type

    // Old events (pre-1.17)
    if (t === "session.status" && p.status?.type && p.status.type !== "idle" && this.awaitingTask) {
      this.hasTask = true
      this.awaitingTask = false
    }

    // New events (1.17+) - session.next.*
    // Task starts
    if ((t === "session.next.step.started" || t === "session.next.running") && this.awaitingTask) {
      this.hasTask = true
      this.awaitingTask = false
    }

    // Task done: old idle OR new complete/idle/prompted
    const isOldIdle = this.hasTask && ((t === "session.status" && p.status?.type === "idle") || t === "session.idle")
    // Khi worker đang chờ Manager tick-chọn (pendingQuestion), session.next.prompted
    // là trạng thái "đang hỏi", KHÔNG được tính là done.
    const isNewDone = (this.hasTask || this.taskSent) && (
      t === "session.next.complete" || t === "session.next.idle" ||
      (t === "session.next.prompted" && !this.pendingQuestion)
    )

    if (isOldIdle || isNewDone) {
      if (this.done) return
      this.done = true
      await this.fetchAndCacheResult()
      await this.push(`!ev ${this.name} done`)
      try { (globalThis as any).__atwScheduler?.onWorkerEvent(this.name, "done", {}) } catch {}
      return
    }

    // Error events
    if ((this.hasTask || this.taskSent) && (t === "session.next.step.failed" || t === "session.next.tool.failed" || t === "session.next.error")) {
      const em = p.error?.message || p.message || "step failed"
      const cls = classifyModelError(em)
      // Allow rate limit/quota errors through even if done (race: SSE complete before error)
      if (this.done && cls !== "ratelimit" && cls !== "quota") return
      this.done = true
      await this.fetchAndCacheResult()
      await this.push(`!ev ${this.name} error [${cls}] ${em}`)
      try { (globalThis as any).__atwScheduler?.onWorkerEvent(this.name, "error", {}) } catch {}
      return
    }

    // Session-level error: lỗi model/provider (quota, rate-limit, auth, context overflow...)
    // opencode phát qua event "session.error" (KHÔNG nằm trong session.next.*).
    // Nếu không bắt ở đây, Manager sẽ KHÔNG nhận được bất kỳ !ev error nào khi hết quota/limit.
    if (t === "session.error") {
      const { text, tag } = extractErrorText(raw, p)
      const cls = classifyModelError(text + " " + tag)
      // Allow rate limit/quota errors through even if done (race: SSE complete before error)
      if (this.done && cls !== "ratelimit" && cls !== "quota") return
      this.done = true
      await this.push(`!ev ${this.name} error [${cls}] ${text}`)
      return
    }

    if (t === "permission.asked" || t === "permission.ask") {
      if (!this.pendingPermission) {
        this.pendingPermission = p.id
        const opts = p.options ? ` options=${JSON.stringify(p.options)}` : ""
        const msg = p.message ? ` msg="${p.message}"` : ""
        await this.push(`!ev ${this.name} permission ${p.permission || "?"}${opts}${msg}`)
      }
      return
    }
    if (t === "permission.replied" || t === "permission.resolved" || t === "permission.granted") {
      this.pendingPermission = undefined
      // Re-arm task tracking so completion detection works after permission
      this.awaitingTask = true
      this.hasTask = false
      this.done = false
      return
    }

    // Tick-chọn: worker hỏi Manager qua tool question
    if (t === "question.asked" || t === "question.v2.asked") {
      if (!this.pendingQuestion) {
        this.pendingQuestion = p.id || raw.id
        const qs: any[] = p.questions || []
        const labels: string[] = []
        const segs = qs.map((q: any, i: number) => {
          const opts: any[] = q.options || []
          opts.forEach((o: any) => { if (o && o.label) labels.push(o.label) })
          const multi = q.multiple ? " [multi]" : ""
          const optStr = opts.map((o: any) => o?.label || "").filter(Boolean).join("|")
          return `Q${i + 1}: ${q.question || ""}${multi} (${optStr})`
        })
        this.pendingQuestionLabels = labels
        this.pendingQuestionMultiple = qs.some((q: any) => q.multiple)
        const hdr = p.header ? ` header="${p.header}"` : ""
        await this.push(`!ev ${this.name} ask${hdr} ${segs.join(" || ")}`)
      }
      return
    }
    if (t === "question.replied" || t === "question.v2.replied" || t === "question.resolved") {
      if (this.pendingQuestion) {
        this.pendingQuestion = undefined
        this.pendingQuestionLabels = []
        this.pendingQuestionMultiple = false
        // Re-arm task tracking để bắt event done sau khi Manager trả lời
        this.awaitingTask = true
        this.hasTask = false
        this.done = false
      }
      return
    }
    if (t === "question.rejected" || t === "question.v2.rejected") {
      this.pendingQuestion = undefined
      this.pendingQuestionLabels = []
      this.pendingQuestionMultiple = false
      return
    }
  }

  async fetchAndCacheResult() {
    const sid = this.sessionId
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        const r = await fetch(`http://127.0.0.1:${this.port}/session/${sid}/message`, {
          signal: AbortSignal.timeout(5000),
        })
        if (!r.ok) {
          const errText = await r.text().catch(() => "")
          if (attempt < 4) { await Bun.sleep(500); continue }
          await this.push(`!ev ${this.name} error fetch result HTTP ${r.status}: ${errText}`)
          return ""
        }
        const data = await r.json()
        const msgs = Array.isArray(data) ? data : [data]
        const texts: string[] = []
        for (const m of msgs) {
          if (m.role === "user") continue
          const parts = m.parts || (Array.isArray(m) ? m : [m])
          for (const part of parts) {
            if (part && part.type === "text" && part.text) {
              texts.push(part.text)
            }
          }
        }
        const text = texts.join("\n").trim()
        if (text) { this.lastResult = text; return text }
      } catch (e: any) {
        if (attempt < 4) { await Bun.sleep(500); continue }
        await this.push(`!ev ${this.name} error fetch result: ${e.message || e}`)
        return ""
      }
      if (attempt < 4) await Bun.sleep(500)
    }
    return ""
  }

  async sendTask(task: string) {
    this.awaitingTask = true
    this.hasTask = false
    this.taskSent = true
    this.done = false
    const [provider, ...rest] = this.model.includes("/")
      ? this.model.split("/") : ["opencode", this.model]
    const modelId = rest.join("/")
    try {
      const r = await fetch(
        `http://127.0.0.1:${this.port}/session/${this.sessionId}/prompt_async`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            parts: [{ type: "text", text: task }],
            model: { providerID: provider, modelID: modelId },
          }),
        }
      )
      if (!r.ok) {
        const errText = await r.text().catch(() => "")
        this.awaitingTask = false
        this.hasTask = false
        this.taskSent = false
        this.done = true
        await this.push(`!ev ${this.name} error send failed HTTP ${r.status}: ${errText}`)
        return
      }
      void this.push(`!ev ${this.name} started`)
    } catch (e: any) {
      this.awaitingTask = false
      this.hasTask = false
      this.taskSent = false
      this.done = true
      await this.push(`!ev ${this.name} error ${e.message || e}`)
    }
  }

  async allowPermission(response?: string) {
    const pid = this.pendingPermission
    if (!pid) return "(đã auto-resolve)"
    try {
      const body: any = { response: response || "once" }
      // If response looks like an option index/value, send as option
      if (response && response !== "once" && response !== "always" && response !== "never") {
        body.option = response
      }
      const r = await fetch(
        `http://127.0.0.1:${this.port}/session/${this.sessionId}/permissions/${pid}`,
        { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }
      )
      if (!r.ok) throw new Error(`permission HTTP ${r.status}`)
      this.pendingPermission = undefined
      this.done = false
      return "permission granted"
    } catch (e: any) {
      this.pendingPermission = undefined
      throw e
    }
  }

  private async replyQuestion(qid: string, body?: any, reject = false): Promise<boolean> {
    const suffix = reject ? "/reject" : "/reply"
    const paths = [
      `http://127.0.0.1:${this.port}/question/${qid}${suffix}`,
      `http://127.0.0.1:${this.port}/api/session/${this.sessionId}/question/${qid}${suffix}`,
    ]
    let lastErr = ""
    for (const url of paths) {
      try {
        const r = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: body ? JSON.stringify(body) : undefined,
        })
        if (r.ok) return true
        lastErr = `HTTP ${r.status}`
      } catch (e: any) {
        lastErr = e.message || String(e)
      }
    }
    throw new Error(`question ${reject ? "reject" : "reply"} failed: ${lastErr}`)
  }

  async chooseQuestion(response?: string) {
    const qid = this.pendingQuestion
    if (!qid) return "(không có question đang chờ)"
    const raw = (response || "").trim()
    let labels: string[]
    if (raw === "") {
      labels = []
    } else if (/^[\d,\s]+$/.test(raw)) {
      // response là index/indexes (hỗ trợ "1,3" cho multiple)
      labels = raw.split(/[,\s]+/).filter(Boolean)
        .map((n) => this.pendingQuestionLabels[parseInt(n, 10) - 1])
        .filter((x): x is string => !!x)
    } else {
      // response là label(s), phân tách bằng | hoặc ,
      labels = raw.split(/[|]/).map((s) => s.trim()).filter(Boolean)
    }
    const body = { answers: [labels] }
    await this.replyQuestion(qid, body, false)
    this.pendingQuestion = undefined
    this.pendingQuestionLabels = []
    this.pendingQuestionMultiple = false
    this.done = false
    return "question answered"
  }

  async rejectQuestion() {
    const qid = this.pendingQuestion
    if (!qid) return "(không có question đang chờ)"
    await this.replyQuestion(qid, undefined, true)
    this.pendingQuestion = undefined
    this.pendingQuestionLabels = []
    this.pendingQuestionMultiple = false
    this.done = false
    return "question rejected"
  }

  async kill() {
    if (this.dead) return
    this.dead = true
    this.monitorAbort.abort()
    this.stderrMonitorAbort.abort()
    if (this.proc) {
      this.proc.kill()
      try { await this.proc.exited } catch {}
    }
    if (workers.get(this.name) === this) workers.delete(this.name)
    try { (globalThis as any).__atwScheduler?.onWorkerEvent(this.name, "died", {}) } catch {}
    await Bun.spawn(["rm", "-rf", `/tmp/oc-${this.port}`]).exited
  }
}

async function portInUse(port: number): Promise<boolean> {
  try {
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 500)
    const r = await fetch(`http://127.0.0.1:${port}/session/status`, { signal: controller.signal })
    clearTimeout(timeout)
    return r.ok
  } catch {
    return false
  }
}

async function startServe(port: number, name: string) {
  if (await portInUse(port)) throw new PortInUseError(`port ${port} is already in use`)

  const dbDir = `/tmp/oc-${port}`
  try { await Bun.spawn(["rm", "-rf", dbDir]).exited } catch {}
  try { await Bun.spawn(["mkdir", "-p", `${dbDir}/opencode`]).exited } catch {}

  const srcAuth = `${process.env.XDG_DATA_HOME || `${process.env.HOME}/.local/share`}/opencode/auth.json`
  try { await Bun.spawn(["cp", srcAuth, `${dbDir}/opencode/auth.json`]).exited } catch (e) {
    console.warn(`[Gateway:${name}] auth.json copy failed: ${e}`)
  }

  const proc = Bun.spawn(
    ["opencode", "serve", "--port", String(port), "--hostname", "127.0.0.1", "--pure"],
    {
      stdout: "ignore", stderr: "pipe",
      env: {
        ...process.env,
        XDG_DATA_HOME: dbDir,
        XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME || `${process.env.HOME}/.config`,
      },
    }
  )

  for (let i = 0; i < 30; i++) {
    if (proc.exitCode !== null) {
      proc.kill()
      throw new Error(`serve ${name} exited code=${proc.exitCode}`)
    }
    try {
      const controller = new AbortController()
      const timeout = setTimeout(() => controller.abort(), 3000)
      const r = await fetch(`http://127.0.0.1:${port}/session/status`, { signal: controller.signal })
      clearTimeout(timeout)
      if (r.ok) return proc
    } catch {}
    await Bun.sleep(500)
  }
  proc.kill()
  throw new Error(`serve ${name} not ready on port ${port}`)
}

async function createSession(port: number, name: string, agent: string): Promise<string> {
  const r = await fetch(`http://127.0.0.1:${port}/session`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: name, agent }),
  })
  if (!r.ok) {
    const detail = (await r.text()).replace(/\s+/g, " ").slice(0, 1_000)
    throw new Error(`createSession ${name}: HTTP ${r.status}${detail ? `: ${detail}` : ""}`)
  }
  return (await r.json()).id
}

function nextPort(): number {
  const used = new Set([
    [...workers.values()].map(w => w.port),
    ...starting.values(),
  ])
  let p = portCursor
  while (used.has(p)) p++
  portCursor = p + 1
  return p
}

const tools = {
  worker_create: tool({
    description: "Create worker. agent: build (default)|plan.",
    args: {
      name: tool.schema.string(),
      model: tool.schema.string().optional(),
      agent: tool.schema.string().optional(),
    },
    async execute(args: any) {
      const config = loadWorkerConfig()
      const DEFAULT_MODEL = config.model
      const MAX_WORKERS = config.max_workers

      const name = args.name
      if (workers.has(name) || starting.has(name)) throw new Error(`worker ${name} đã tồn tại hoặc đang khởi tạo`)
      if (workers.size + starting.size >= MAX_WORKERS) throw new Error("đã đạt max worker")

      let port = nextPort()
      starting.set(name, port)
      let proc: any = null
      let startupFailed = false
      try {
        for (;;) {
          try {
            proc = await startServe(port, name)
            break
          } catch (e) {
            if (!(e instanceof PortInUseError)) throw e
            port = nextPort()
            starting.set(name, port)
          }
        }
        const agent = args.agent || "build"
        if (agent !== "build" && agent !== "plan") {
          throw new Error(`agent không hợp lệ: ${agent}. Chỉ hỗ trợ: build, plan`)
        }
        const sid = await createSession(port, name, agent)

        const gw = new WorkerGateway(name, port, proc, sid, args.model || DEFAULT_MODEL)
        workers.set(name, gw)
        gw.startMonitor()
        return `+${name} (port ${port})`
      } catch (e) {
        startupFailed = true
        if (proc) {
          try { proc.kill() } catch {}
          try { await proc.exited } catch {}
        }
        await Bun.spawn(["rm", "-rf", `/tmp/oc-${port}`]).exited
        const message = e instanceof Error ? e.message : String(e)
        await pushManagerEvent(`!ev ${name} error create failed: ${message}`)
        throw e
      } finally {
        if (!startupFailed || !workers.has(name)) {
          starting.delete(name)
        }
      }
    },
  }),

  worker_send: tool({
    description: "Send task to worker (non-blocking).",
    args: { name: tool.schema.string(), task: tool.schema.string() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) throw new Error(`worker ${args.name} không tồn tại`)
      try { (globalThis as any).__atwScheduler?.onManagerAction(args.name, "send", args.task) } catch {}
      await gw.sendTask(args.task)
      return "+"
    },
  }),

  worker_result: tool({
    description: "Read worker result (only after !ev done).",
    args: { name: tool.schema.string() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) return "(không tìm thấy)"
      if (gw.lastResult) { try { (globalThis as any).__atwScheduler?.onManagerAction(args.name, "result") } catch {} return gw.lastResult }
      if (!gw.done) throw new Error(`CHƯA XONG — BẮT BUỘC ĐỢI !ev ${args.name} done. Worker ${args.name} vẫn đang chạy. HÃY DỪNG GỌI worker_result VÀ CHỜ EVENT.`)
      await gw.fetchAndCacheResult()
      try { (globalThis as any).__atwScheduler?.onManagerAction(args.name, "result") } catch {}
      return gw.lastResult || "(done nhưng kết quả rỗng — thử worker_result lần nữa)"
    },
  }),

  worker_allow: tool({
    description: "Approve permission. response: once|always|never|<index>|<value>",
    args: { name: tool.schema.string(), response: tool.schema.string().optional() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) throw new Error(`worker ${args.name} không tồn tại`)
      const r = await gw.allowPermission(args.response)
      try { (globalThis as any).__atwScheduler?.onManagerAction(args.name, "allow") } catch {}
      return r
    },
  }),

  worker_kill: tool({
    description: "Kill worker (closes its ledger).",
    args: { name: tool.schema.string() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) return "-"
      await gw.kill()
      workers.delete(args.name)
      // Manager chủ động "đóng sổ" worker này → gỡ khỏi sổ giao việc.
      try { (globalThis as any).__atwScheduler?.onManagerAction(args.name, "kill") } catch {}
      return `-${args.name}`
    },
  }),

  worker_killall: tool({
    description: "Kill all workers.",
    args: {},
    async execute() {
      const active = [...workers.values()]
      const n = workers.size + starting.size
      workers.clear()
      starting.clear()
      await Promise.allSettled(active.map(gw => gw.kill()))
      // Đóng sổ toàn bộ.
      try { (globalThis as any).__atwScheduler?.onManagerAction("*", "killall") } catch {}
      return String(n)
    },
  }),

  worker_choose: tool({
    description: "Answer worker question. response: <label>|<index>|'1,3' (multi). After !ev X ask.",
    args: { name: tool.schema.string(), response: tool.schema.string().optional() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) throw new Error(`worker ${args.name} không tồn tại`)
      const r = await gw.chooseQuestion(args.response)
      try { (globalThis as any).__atwScheduler?.onManagerAction(args.name, "choose") } catch {}
      return r
    },
  }),

  worker_reject: tool({
    description: "Reject worker question. After !ev X ask.",
    args: { name: tool.schema.string() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) throw new Error(`worker ${args.name} không tồn tại`)
      const r = await gw.rejectQuestion()
      try { (globalThis as any).__atwScheduler?.onManagerAction(args.name, "reject") } catch {}
      return r
    },
  }),

  worker_set_model: tool({
    description: "Set default worker model (worker.json).",
    args: { model: tool.schema.string() },
    async execute(args: any) {
      const fs = require("fs")
      const cfgPath = `${process.env.HOME}/.config/opencode/worker.json`
      let cfg = { model: "zen-proxy/deepseek-v4-flash-free", max_workers: 5 }
      try {
        const file = fs.readFileSync(cfgPath, "utf-8")
        cfg = JSON.parse(file)
      } catch {}
      cfg.model = args.model
      fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2))
      return `model → ${args.model}`
    },
  }),

  worker_get_model: tool({
    description: "Get worker model (or default).",
    args: { name: tool.schema.string().optional() },
    async execute(args: any) {
      if (args.name) {
        const gw = workers.get(args.name)
        if (!gw) return `worker ${args.name} không tồn tại`
        return `${args.name}: ${gw.model}`
      }
      const fs = require("fs")
      const cfgPath = `${process.env.HOME}/.config/opencode/worker.json`
      let cfg = { model: "zen-proxy/deepseek-v4-flash-free", max_workers: 5 }
      try {
        const file = fs.readFileSync(cfgPath, "utf-8")
        cfg = JSON.parse(file)
      } catch {}
      return `default: ${cfg.model} (max_workers: ${cfg.max_workers})`
    },
  }),

  doc_read: tool({
    description: "Read ONE document by path or glob (e.g. ~/kich_ban/01* or /abs/file.md). Must match exactly one file; if several match, returns the list to pick from.",
    args: { path: tool.schema.string() },
    async execute(args: any) {
      const fs = require("fs"), os = require("os"), path = require("path")
      let p = String(args.path || "").trim()
      if (!p) throw new Error("thiếu path")
      // ~ và ~/... → HOME
      if (p === "~" || p.startsWith("~/")) p = path.join(os.homedir(), p.slice(1))
      p = path.resolve(p)
      let file = p
      // Glob: chỉ hỗ trợ wildcard (* ?) ở TÊN FILE (1 cấp), đủ cho "01*".
      if (/[*?]/.test(path.basename(p))) {
        const dir = path.dirname(p), base = path.basename(p)
        let entries: string[] = []
        try { entries = fs.readdirSync(dir) } catch { return `(không mở được thư mục: ${dir})` }
        const re = new RegExp("^" + base.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$")
        const matches = entries.filter((e: string) => re.test(e)).sort()
        if (matches.length === 0) return `(không có file khớp: ${base} trong ${dir})`
        if (matches.length > 1) return `Khớp ${matches.length} file — chỉ đọc 1, hãy chỉ rõ:\n` + matches.map((m: string) => "  " + path.join(dir, m)).join("\n")
        file = path.join(dir, matches[0])
      }
      let st: any
      try { st = fs.statSync(file) } catch { return `(không tìm thấy: ${file})` }
      if (st.isDirectory()) return `(đây là thư mục, cần chỉ 1 file): ${file}`
      const MAX = 100 * 1024
      let content = ""
      try { content = fs.readFileSync(file, "utf8") } catch (e: any) { return `(không đọc được: ${e?.message || e})` }
      const truncated = content.length > MAX
      if (truncated) content = content.slice(0, MAX)
      return `# ${file} (${st.size} bytes${truncated ? ", cắt bớt còn 100KB" : ""})\n\n${content}`
    },
  }),
}

export const AgentTeamwork = async ({ client }: any) => {
  _client = client

  const cleanup = async () => {
    const active = [...workers.values()]
    workers.clear()
    starting.clear()
    await Promise.allSettled(
      active.map(gw => Promise.race([
        gw.kill(),
        new Promise(r => setTimeout(r, 5000))
      ]))
    )
  }

  process.once("SIGINT", () => {
    void cleanup().finally(() => process.exit(0))
  })
  process.once("SIGTERM", () => {
    void cleanup().finally(() => process.exit(0))
  })

  return {
    async dispose() {
      process.removeAllListeners("SIGINT")
      process.removeAllListeners("SIGTERM")
      await cleanup()
    },
    event: async ({ event }: any) => {
      const sid = event?.properties?.sessionID
        || event?.properties?.info?.sessionID
        || event?.properties?.info?.id
      if (sid && typeof sid === "string" && sid.startsWith("ses_")) _lastSessionID = sid
    },
    tool: tools,
  }
}