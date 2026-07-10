import { z } from "zod"
function tool(def: any) { return def }
tool.schema = z

let _client: any = null
const MAX_WORKERS = 5
const DEFAULT_MODEL = "deepseek/deepseek-v4-pro"
const workers = new Map<string, WorkerGateway>()
let portCursor = 4091

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
  lastResult = ""
  pendingPermission?: string

  constructor(name: string, port: number, proc: any, sid: string, model: string) {
    this.name = name; this.port = port; this.proc = proc
    this.sessionId = sid; this.model = model
  }

  // ── Gửi event về Manager ─────────────

  private async push(msg: string) {
    if (!_client) return
    try {
      await _client.tui.appendPrompt({ body: { text: msg } })
      await _client.tui.submitPrompt()
    } catch (e: any) {
      console.error(`[GW:${this.name}] push error: ${e.message || e}`)
    }
  }

  // ── SSE Monitor ──────────────────────

  startMonitor() {
    const gw = this;
    (async () => {
      let running = true
      gw.proc.exited.catch(() => {}).finally(() => { running = false })

      while (running) {
        if (gw.dead) return
        try {
          const r = await fetch(`http://127.0.0.1:${gw.port}/event`)
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
              if (!line.startsWith("data: ")) continue
              let raw: any
              try { raw = JSON.parse(line.slice(6)) } catch { continue }
              const p = raw.properties || {}
              if (p.sessionID && p.sessionID !== gw.sessionId) continue

              // Fire-and-forget, nhưng bắt lỗi để log
              gw.onEvent(raw, p).catch((e: any) => {
                console.error(`[GW:${gw.name}] onEvent error: ${e.message || e}`)
              })
            }
          }
        } catch { if (running) await Bun.sleep(1000) }
      }

      if (!gw.dead) {
        gw.dead = true
        gw.push(`!ev ${gw.name} died exit=${gw.proc.exitCode}`)
      }
    })().catch(() => {})
  }

  private async onEvent(raw: any, p: any) {
    const t = raw.type

    // ── Done ──
    if ((t === "session.status" && p.status?.type === "idle") || t === "session.idle") {
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
    if (!r.ok) throw new Error(`send failed HTTP ${r.status}`)
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

  kill() {
    this.dead = true
    try { this.proc.kill() } catch {}
  }
}

// ═══════════════════════════════════════════
// Serve — spawn + readiness check
// ═══════════════════════════════════════════

async function startServe(port: number, name: string) {
  const dbDir = `/tmp/oc-${port}`
  try { (await Bun.spawn(["rm", "-rf", dbDir]).exited) } catch {}
  try { (await Bun.spawn(["mkdir", "-p", `${dbDir}/opencode`]).exited) } catch {}

  // Copy auth.json từ data dir gốc để serve có API key
  const srcAuth = `${process.env.XDG_DATA_HOME || `${process.env.HOME}/.local/share`}/opencode/auth.json`
  try { await Bun.spawn(["cp", srcAuth, `${dbDir}/opencode/auth.json`]).exited } catch {}

  const proc = Bun.spawn(
    ["opencode", "serve", "--port", String(port), "--hostname", "127.0.0.1"],
    {
      stdout: "pipe", stderr: "pipe",
      env: {
        ...process.env,
        XDG_DATA_HOME: dbDir,                        // DB riêng
        XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME || `${process.env.HOME}/.config`, // config chung (provider/auth)
      },
    }
  )

  for (let i = 0; i < 30; i++) {
    if (proc.exitCode !== null) {
      proc.kill()
      throw new Error(`serve ${name} exited code=${proc.exitCode}`)
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
  throw new Error(`serve ${name} not ready on port ${port}`)
}

async function createSession(port: number, name: string, agent: string) {
  const r = await fetch(`http://127.0.0.1:${port}/session`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: name, agent }),
  })
  if (!r.ok) throw new Error(`createSession ${name}: HTTP ${r.status}`)
  return (await r.json()).id
}

function nextPort(): number {
  const used = new Set([...workers.values()].map(w => w.port))
  let p = portCursor
  while (used.has(p)) p++
  portCursor = p
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
      if (workers.has(name)) throw new Error(`worker ${name} đã tồn tại`)
      if (workers.size >= MAX_WORKERS) throw new Error("đã đạt max worker")

      const port = nextPort()
      const proc = await startServe(port, name)
      const agent = args.agent || "build"
      const sid = await createSession(port, name, agent)

      const gw = new WorkerGateway(name, port, proc, sid, args.model || DEFAULT_MODEL)
      workers.set(name, gw)
      gw.startMonitor()
      return `+${name} (port ${port})`
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
      gw.kill()
      workers.delete(args.name)
      Bun.spawn(["rm", "-rf", `/tmp/oc-${gw.port}`])
      return `-${args.name}`
    },
  }),

  worker_killall: tool({
    description: "Hủy tất cả.",
    args: {},
    async execute() {
      for (const gw of workers.values()) {
        gw.kill()
        Bun.spawn(["rm", "-rf", `/tmp/oc-${gw.port}`])
      }
      const n = workers.size
      workers.clear()
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

  process.once("SIGINT", () => {
    for (const gw of workers.values()) gw.kill()
    process.exit(0)
  })
  process.once("SIGTERM", () => {
    for (const gw of workers.values()) gw.kill()
    process.exit(0)
  })

  return {
    dispose() {
      process.removeAllListeners("SIGINT")
      process.removeAllListeners("SIGTERM")
      for (const gw of workers.values()) gw.kill()
      workers.clear()
    },
    tool: tools,
  }
}
