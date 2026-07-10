import { z } from "zod"
function tool(def: any) { return def }
tool.schema = z

let _client: any = null
const MAX_WORKERS = 5
const DEFAULT_MODEL = "deepseek/deepseek-v4-pro"
const workers = new Map<string, WorkerGateway>()
// Reserve ports while a create call is awaiting startup. Without this, two
// concurrent creates both see the same free port and start conflicting serves.
const starting = new Map<string, number>()
let portCursor = 4091

// appendPrompt + submitPrompt must stay atomic relative to other worker events.
let pushQueue: Promise<void> = Promise.resolve()

class PortInUseError extends Error {}

async function pushManagerEvent(msg: string) {
  pushQueue = pushQueue
    .then(async () => {
      if (!_client) return
      await _client.tui.appendPrompt({ body: { text: msg } })
      await _client.tui.submitPrompt()
    })
    .catch((e: any) => {
      console.error(`[Gateway] push error: ${e.message || e}`)
    })
  await pushQueue
}

// ═══════════════════════════════════════════
// WorkerGateway — mỗi worker 1 instance riêng
// ═══════════════════════════════════════════

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
  lastResult = ""
  pendingPermission?: string
  private monitorAbort = new AbortController()
  private exitHandled = false

  constructor(name: string, port: number, proc: any, sid: string, model: string) {
    this.name = name; this.port = port; this.proc = proc
    this.sessionId = sid; this.model = model
  }

  // ── Gửi event về Manager ─────────────

  private async push(msg: string) {
    await pushManagerEvent(msg)
  }

  // ── SSE Monitor ──────────────────────

  startMonitor() {
    const gw = this;
    (async () => {
      let running = true
      gw.proc.exited
        .then((code: number) => gw.handleExit(code))
        .catch(() => gw.handleExit("unknown"))
        .finally(() => { running = false })

      while (running) {
        if (gw.dead) return
        try {
          const r = await fetch(`http://127.0.0.1:${gw.port}/event`, {
            signal: gw.monitorAbort.signal,
          })
          if (!r.ok || !r.body) { await Bun.sleep(1000); continue }

          const reader = r.body.getReader()
          const decoder = new TextDecoder()
          let buf = ""

          while (running) {
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
              if (p.sessionID && p.sessionID !== gw.sessionId) continue

              // Fire-and-forget, nhưng bắt lỗi để log
              gw.onEvent(raw, p).catch((e: any) => {
                console.error(`[GW:${gw.name}] onEvent error: ${e.message || e}`)
              })
            }
          }
        } catch {
          if (gw.monitorAbort.signal.aborted) return
          if (running) await Bun.sleep(1000)
        }
      }

    })().catch(() => {})
  }

  private async handleExit(code: number | string) {
    if (this.exitHandled) return
    this.exitHandled = true
    if (this.dead) return // deliberate worker_kill / Manager cleanup

    this.dead = true
    this.monitorAbort.abort()
    if (workers.get(this.name) === this) workers.delete(this.name)
    await this.push(`!ev ${this.name} died exit=${code}`)
    void Bun.spawn(["rm", "-rf", `/tmp/oc-${this.port}`]).exited
  }

  private async onEvent(raw: any, p: any) {
    const t = raw.type

    // An SSE subscription may still contain the session's initial `idle`
    // notification when worker_send is called.  A task becomes eligible for
    // completion only after the server has announced a non-idle state.
    if (t === "session.status" && p.status?.type && p.status.type !== "idle" && this.awaitingTask) {
      this.hasTask = true
    }

    // ── Done ──
    if (this.hasTask && ((t === "session.status" && p.status?.type === "idle") || t === "session.idle")) {
      if (this.done) return
      this.done = true
      await this.fetchAndCacheResult()
      await this.push(`!ev ${this.name} done`)
      return
    }

    // ── Permission ──
    if (t === "permission.asked") {
      if (!this.pendingPermission) {
        this.pendingPermission = p.id
        await this.push(`!ev ${this.name} permission ${p.permission || "?"}`)
      }
      return
    }
    if (t === "permission.replied") {
      this.pendingPermission = undefined
      this.done = false
      return
    }
  }

  // ── Kết quả ──────────────────────────

  async fetchAndCacheResult() {
    const sid = this.sessionId
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        const r = await fetch(`http://127.0.0.1:${this.port}/session/${sid}/message`)
        if (!r.ok) { await Bun.sleep(500); continue }
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
      } catch {}
      if (attempt < 4) await Bun.sleep(500)
    }
    return ""
  }

  // ── Send task ────────────────────────

  async sendTask(task: string) {
    // Do not count an initial idle event as completion.  `onEvent` promotes
    // this to hasTask only after OpenCode reports a non-idle status.
    this.awaitingTask = true
    this.hasTask = false
    this.done = false
    const [provider, modelId] = this.model.includes("/")
      ? this.model.split("/") : ["opencode", this.model]
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
      this.awaitingTask = false
      this.hasTask = false
      throw new Error(`send failed HTTP ${r.status}`)
    }
    void this.push(`!ev ${this.name} started`)
  }

  // ── Permission ───────────────────────

  async allowPermission() {
    const pid = this.pendingPermission
    if (!pid) return "(đã auto-resolve)"
    try {
      const r = await fetch(
        `http://127.0.0.1:${this.port}/session/${this.sessionId}/permissions/${pid}`,
        { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ response: "once" }) }
      )
      if (!r.ok) { this.pendingPermission = undefined; this.done = false; return `(HTTP ${r.status})` }
    } catch { return "(lỗi)" }
    this.pendingPermission = undefined
    this.done = false
    return "ok"
  }

  // ── Kill ─────────────────────────────

  async kill() {
    this.dead = true
    this.monitorAbort.abort()
    try { this.proc.kill() } catch {}
    await Promise.race([
      this.proc.exited.catch(() => {}),
      Bun.sleep(5_000),
    ])
    try { this.proc.kill("SIGKILL") } catch {}
    await Bun.spawn(["rm", "-rf", `/tmp/oc-${this.port}`]).exited
  }
}

// ═══════════════════════════════════════════
// Serve — spawn + readiness check
// ═══════════════════════════════════════════

async function portInUse(port: number) {
  try {
    // Any HTTP response means another process owns this loopback port. Do not
    // delete its XDG data directory or connect the new gateway to it.
    await fetch(`http://127.0.0.1:${port}/session/status`, {
      signal: AbortSignal.timeout(500),
    })
    return true
  } catch {
    return false
  }
}

async function startServe(port: number, name: string) {
  if (await portInUse(port)) throw new PortInUseError(`port ${port} is already in use`)

  const dbDir = `/tmp/oc-${port}`
  try { (await Bun.spawn(["rm", "-rf", dbDir]).exited) } catch {}
  try { (await Bun.spawn(["mkdir", "-p", `${dbDir}/opencode`]).exited) } catch {}

  // Copy auth.json từ data dir gốc để serve có API key
  const srcAuth = `${process.env.XDG_DATA_HOME || `${process.env.HOME}/.local/share`}/opencode/auth.json`
  try { await Bun.spawn(["cp", srcAuth, `${dbDir}/opencode/auth.json`]).exited } catch {}

  const proc = Bun.spawn(
    // Workers must only expose OpenCode's built-in tools. The parent project
    // can contain external plugins (for example ~/.opencode's `list` plugin)
    // that alter glob/read behavior and are unrelated to the assigned task.
    ["opencode", "serve", "--pure", "--port", String(port), "--hostname", "127.0.0.1"],
    {
      // Drain stderr continuously. This both avoids a full pipe blocking the
      // worker and preserves a short diagnostic when startup fails.
      stdout: "ignore", stderr: "pipe",
      env: {
        ...process.env,
        XDG_DATA_HOME: dbDir,                        // DB riêng
        XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME || `${process.env.HOME}/.config`, // config chung (provider/auth)
      },
    }
  )

  let stderrTail = ""
  const stderr = proc.stderr
  void (async () => {
    const reader = stderr.getReader()
    const decoder = new TextDecoder()
    while (true) {
      const chunk = await reader.read()
      if (chunk.done) return
      stderrTail = (stderrTail + decoder.decode(chunk.value, { stream: true })).slice(-4_000)
    }
  })().catch(() => {})
  const startupError = () => stderrTail.trim().replace(/\s+/g, " ").slice(-1_000)

  for (let i = 0; i < 30; i++) {
    if (proc.exitCode !== null) {
      proc.kill()
      const detail = startupError()
      throw new Error(`serve ${name} exited code=${proc.exitCode}${detail ? `: ${detail}` : ""}`)
    }
    try {
      const r = await fetch(`http://127.0.0.1:${port}/session/status`, {
        signal: AbortSignal.timeout(2000),
      })
      if (r.ok) return proc
    } catch {}
    await Bun.sleep(500)
  }
  proc.kill()
  const detail = startupError()
  throw new Error(`serve ${name} not ready on port ${port}${detail ? `: ${detail}` : ""}`)
}

async function createSession(port: number, name: string, agent: string) {
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
    ...[...workers.values()].map(w => w.port),
    ...starting.values(),
  ])
  let p = portCursor
  while (used.has(p)) p++
  portCursor = p + 1
  return p
}

// ═══════════════════════════════════════════
// Tools
// ═══════════════════════════════════════════

const tools = {
  worker_create: tool({
    description: "Tạo worker. agent: build (mặc định)|plan.",
    args: {
      name: tool.schema.string(),
      model: tool.schema.string().optional(),
      agent: tool.schema.string().optional(),
    },
    async execute(args: any) {
      const name = args.name
      if (workers.has(name) || starting.has(name)) throw new Error(`worker ${name} đã tồn tại hoặc đang khởi tạo`)
      if (workers.size + starting.size >= MAX_WORKERS) throw new Error("đã đạt max worker")

      let port = nextPort()
      starting.set(name, port)
      let proc: any = null
      try {
        // A previous Manager can have left a serve behind. Skip its port rather
        // than connecting the new gateway to that unrelated process.
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
        const sid = await createSession(port, name, agent)

        const gw = new WorkerGateway(name, port, proc, sid, args.model || DEFAULT_MODEL)
        workers.set(name, gw)
        gw.startMonitor()
        return `+${name} (port ${port})`
      } catch (e) {
        try { proc?.kill() } catch {}
        await Bun.spawn(["rm", "-rf", `/tmp/oc-${port}`]).exited
        const message = e instanceof Error ? e.message : String(e)
        await pushManagerEvent(`!ev ${name} error create failed: ${message}`)
        throw e
      } finally {
        starting.delete(name)
      }
    },
  }),

  worker_send: tool({
    description: "Gửi task (non-blocking).",
    args: { name: tool.schema.string(), task: tool.schema.string() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) throw new Error(`worker ${args.name} không tồn tại`)
      await gw.sendTask(args.task)
      return "+"
    },
  }),

  worker_result: tool({
    description: "Đọc kết quả.",
    args: { name: tool.schema.string() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) return "(không tìm thấy)"
      if (gw.lastResult) return gw.lastResult
      if (!gw.done) return `(chưa xong — đợi !ev ${args.name} done)`
      await gw.fetchAndCacheResult()
      return gw.lastResult || "(done nhưng kết quả rỗng — thử worker_result lần nữa)"
    },
  }),

  worker_allow: tool({
    description: "Duyệt permission.",
    args: { name: tool.schema.string() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) throw new Error(`worker ${args.name} không tồn tại`)
      return await gw.allowPermission()
    },
  }),

  worker_kill: tool({
    description: "Hủy worker.",
    args: { name: tool.schema.string() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) return "-"
      await gw.kill()
      workers.delete(args.name)
      return `-${args.name}`
    },
  }),

  worker_killall: tool({
    description: "Hủy tất cả.",
    args: {},
    async execute() {
      const active = [...workers.values()]
      const n = workers.size
      workers.clear()
      await Promise.all(active.map(gw => gw.kill()))
      return String(n)
    },
  }),

  worker_status: tool({
    description: "Trạng thái (chỉ debug).",
    args: { name: tool.schema.string().optional() },
    async execute(args: any) {
      const st = (gw: WorkerGateway) =>
        gw.dead ? "dead" : gw.pendingPermission ? "permission" : gw.done ? "idle" : "running"
      if (args.name) {
        const gw = workers.get(args.name)
        return gw ? st(gw) : "dead"
      }
      if (workers.size === 0) return "(none)"
      return [...workers.entries()]
        .map(([n, gw]) => `${n} ${st(gw)}`)
        .join("\n")
    },
  }),
}

// ═══════════════════════════════════════════
// Plugin export
// ═══════════════════════════════════════════

export const AgentTeamwork = async ({ client }: any) => {
  _client = client

  const cleanup = async () => {
    const active = [...workers.values()]
    workers.clear()
    await Promise.all(active.map(gw => gw.kill()))
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
    tool: tools,
  }
}
