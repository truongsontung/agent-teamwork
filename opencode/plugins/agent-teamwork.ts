import { z } from "zod"
function tool(def: any) { return def }
tool.schema = z

let _client: any = null
const MAX_WORKERS = 5
const DEFAULT_MODEL = "nvidia/nemotron-3-ultra-550b-a55b"
const workers = new Map<string, WorkerGateway>()
const starting = new Map<string, number>()
let portCursor = 4091

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
  private monitorAbort = new AbortController()
  private exitHandled = false

  constructor(name: string, port: number, proc: any, sid: string, model: string) {
    this.name = name; this.port = port; this.proc = proc
    this.sessionId = sid; this.model = model
  }

  private async push(msg: string) {
    await pushManagerEvent(msg)
  }

  startMonitor() {
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
    if (workers.get(this.name) === this) workers.delete(this.name)
    await this.push(`!ev ${this.name} died exit=${code}`)
    await Bun.spawn(["rm", "-rf", `/tmp/oc-${this.port}`]).exited
  }

  private async onEvent(raw: any, p: any) {
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
    const isNewDone = (this.hasTask || this.taskSent) && (t === "session.next.complete" || t === "session.next.idle" || t === "session.next.prompted")

    if (isOldIdle || isNewDone) {
      if (this.done) return
      this.done = true
      await this.fetchAndCacheResult()
      await this.push(`!ev ${this.name} done`)
      return
    }

    // Error events
    if ((this.hasTask || this.taskSent) && (t === "session.next.step.failed" || t === "session.next.tool.failed" || t === "session.next.error")) {
      if (this.done) return
      this.done = true
      await this.fetchAndCacheResult()
      await this.push(`!ev ${this.name} error ${p.error?.message || p.message || "step failed"}`)
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

    // Debug: log unknown session.next events
    if (t.startsWith("session.next.")) {
      console.log(`[GW:${this.name}] event: ${t}`)
    }
  }

  async fetchAndCacheResult() {
    const sid = this.sessionId
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        const r = await fetch(`http://127.0.0.1:${this.port}/session/${sid}/message`, {
          signal: AbortSignal.timeout(5000),
        })
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

  async sendTask(task: string) {
    this.awaitingTask = true
    this.hasTask = false
    this.taskSent = true
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
      this.taskSent = false
      throw new Error(`send failed HTTP ${r.status}`)
    }
    void this.push(`!ev ${this.name} started`)
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

  async kill() {
    if (this.dead) return
    this.dead = true
    this.monitorAbort.abort()
    if (this.proc) {
      this.proc.kill()
      try { await this.proc.exited } catch {}
    }
    if (workers.get(this.name) === this) workers.delete(this.name)
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
    ["opencode", "serve", "--pure", "--port", String(port), "--hostname", "127.0.0.1"],
    {
      stdout: "ignore", stderr: "pipe",
      env: {
        ...process.env,
        XDG_DATA_HOME: dbDir,
        XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME || `${process.env.HOME}/.config`,
      },
    }
  )

  let stderrTail = ""
  const stderr = proc.stderr
  void (async () => {
    const reader = stderr.getReader()
    const decoder = new TextDecoder()
    try {
      while (true) {
        const chunk = await reader.read()
        if (chunk.done) return
        stderrTail = (stderrTail + decoder.decode(chunk.value, { stream: true })).slice(-4_000)
      }
    } catch {}
  })()
  const startupError = () => stderrTail.trim().replace(/\s+/g, " ").slice(-1_000)

  for (let i = 0; i < 30; i++) {
    if (proc.exitCode !== null) {
      proc.kill()
      const detail = startupError()
      throw new Error(`serve ${name} exited code=${proc.exitCode}${detail ? `: ${detail}` : ""}`)
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
  const detail = startupError()
  throw new Error(`serve ${name} not ready on port ${port}${detail ? `: ${detail}` : ""}`)
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
      if (!gw.done) throw new Error(`CHƯA XONG — BẮT BUỘC ĐỢI !ev ${args.name} done. Worker ${args.name} vẫn đang chạy. HÃY DỪNG GỌI worker_result VÀ CHỜ EVENT.`)
      await gw.fetchAndCacheResult()
      return gw.lastResult || "(done nhưng kết quả rỗng — thử worker_result lần nữa)"
    },
  }),

  worker_allow: tool({
    description: "Duyệt permission. response: once|always|never|<index>|<value>",
    args: { name: tool.schema.string(), response: tool.schema.string().optional() },
    async execute(args: any) {
      const gw = workers.get(args.name)
      if (!gw) throw new Error(`worker ${args.name} không tồn tại`)
      return await gw.allowPermission(args.response)
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
      await Promise.allSettled(active.map(gw => gw.kill()))
      return String(n)
    },
  }),
}

export const AgentTeamwork = async ({ client }: any) => {
  _client = client

  const cleanup = async () => {
    const active = [...workers.values()]
    workers.clear()
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
    tool: tools,
  }
}