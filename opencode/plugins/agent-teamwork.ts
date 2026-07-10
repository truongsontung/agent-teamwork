// Agent Teamwork Plugin — 1 file thay toàn bộ bash script
// Quản lý opencode serve workers trực tiếp từ Manager TUI
import { z } from "zod"
function tool(def) { return def }
tool.schema = z

// ── Config ──────────────────────────────────────────────

const PORT_BASE = 4091
const DEFAULT_MODEL = "deepseek/deepseek-v4-pro"
const MAX_WORKERS = 5
let _client: any = null  // SDK client, set at plugin init

// ── State ───────────────────────────────────────────────

const workers = new Map()
const statusDir = `${process.env.PROJECT_DIR || process.cwd()}/.worker`

function statusPath(name: string) { return `${statusDir}/_${name}.status` }
function resultPath(name: string) { return `${statusDir}/_${name}.result` }
function permPath(name: string)   { return `${statusDir}/_${name}.perm` }

function setStatus(name: string, st: string) {
  const w = workers.get(name)
  if (w) w.status = st
  try { require("fs").mkdirSync(statusDir, { recursive: true }) } catch {}
  require("fs").writeFileSync(statusPath(name), st)
  writeStatusLog()
}

function writeStatusLog() {
  const lines = []
  const now = new Date().toLocaleTimeString()
  for (const [n, w] of workers) {
    const extra = w.pendingPermission ? ` perm:${w.pendingPermission}` : ""
    lines.push(`${now} ${n}=${w.status}${extra}`)
  }
  if (lines.length > 0) {
    try { require("fs").mkdirSync(statusDir, { recursive: true }) } catch {}
    require("fs").writeFileSync(`${statusDir}/status.log`, lines.join("\n") + "\n")
  }
}

// ── Port allocation ─────────────────────────────────────

function nextPort(): number {
  let p = PORT_BASE
  while (true) {
    const used = [...workers.values()].some(w => w.port === p)
    if (!used) return p
    p++
  }
}

// ── Serve lifecycle ─────────────────────────────────────

async function startServe(port: number): Promise<number> {
  const proc = Bun.spawn(
    ["opencode", "serve", "--port", String(port), "--hostname", "127.0.0.1"],
    { stdout: "pipe", stderr: "pipe" }
  )
  for (let i = 0; i < 30; i++) {
    try {
      await fetch(`http://127.0.0.1:${port}/session/status`, { signal: AbortSignal.timeout(2000) })
      return proc.pid
    } catch {}
    await Bun.sleep(1000)
  }
  proc.kill()
  throw new Error(`Serve not ready on port ${port}`)
}

async function createSession(port: number, name: string, agent: string): Promise<string> {
  const res = await fetch(`http://127.0.0.1:${port}/session`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: name, agent }),
  })
  const json = await res.json() as any
  return json.id
}

// ── SSE Monitor (per worker) ────────────────────────────

async function pushEvent(msg: string) {
  if (!_client) return
  try {
    await _client.tui.appendPrompt({ body: { text: msg } })
    await _client.tui.submitPrompt()
  } catch {
    _client.tui.appendPrompt({ body: { text: msg } }).catch(() => {})
  }
}

async function monitorSSE(name: string, port: number) {
  while (true) {
    // Check if worker process still alive
    const w = workers.get(name)
    if (!w) return
    try { process.kill(w.pid, 0) } catch { setStatus(name, "dead"); return }

    try {
      const res = await fetch(`http://127.0.0.1:${port}/event`)
      if (!res.ok) { await Bun.sleep(3000); continue }
      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let buf = ""

      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buf += decoder.decode(value, { stream: true })
        const lines = buf.split("\n")
        buf = lines.pop() || ""

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue
          let json: any
          try { json = JSON.parse(line.slice(6)) } catch { continue }
          handleSSE(name, json)
        }
      }
    } catch {
      // reconnect
    }
    await Bun.sleep(2000)
  }
}

function handleSSE(name: string, event: any) {
  const type = event.type
  const props = event.properties || {}
  const w = workers.get(name)
  const prevStatus = w && w.status || ""

  if (type === "session.idle" && prevStatus !== "idle") {
    handleIdle(name).catch(() => pushEvent(`!ev ${name} done`))
  } else if (type === "session.error" && prevStatus !== "error") {
    setStatus(name, "error")
    const err = JSON.stringify(props.error || props.message || props)
    pushEvent(`!ev ${name} error ${err}`)
  } else if (type === "permission.asked" && prevStatus !== "permission") {
    setStatus(name, "permission")
    if (w) w.pendingPermission = props.id
    try { require("fs").writeFileSync(permPath(name), JSON.stringify(event)) } catch {}
    const perm = props.permission || "?"
    const pats = (props.patterns || []).join(",")
    pushEvent(`!ev ${name} permission ${perm} [${pats}]`)
  } else if (type === "permission.replied") {
    setStatus(name, "running")
    if (w) w.pendingPermission = undefined
  } else if (type === "session.status") {
    const st = props.status && props.status.type
    if (st === "idle" && prevStatus !== "idle") setStatus(name, "idle")
    else if (st === "busy" && prevStatus !== "running") setStatus(name, "running")
  }
}

function saveResult(name: string) {
  const w = workers.get(name)
  if (!w) return
  fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/message`)
    .then(r => r.json())
    .then((data: any) => {
      const msgs = Array.isArray(data) ? data : [data]
      const text = msgs
        .flatMap((m: any) => (m.parts || []).filter((p: any) => p.type === "text").map((p: any) => p.text))
        .join("\n").trim()
      if (text) {
        w.lastResult = text
        try { require("fs").writeFileSync(resultPath(name), text) } catch {}
      }
    })
    .catch(() => {})
}

async function handleIdle(name: string) {
  const w = workers.get(name)
  if (!w || w.status === "idle") return
  setStatus(name, "idle")
  // Fetch result before pushing event
  try {
    const res = await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/message`)
    const data = await res.json()
    const msgs = Array.isArray(data) ? data : [data]
    const text = msgs
      .flatMap((m: any) => (m.parts || []).filter((p: any) => p.type === "text").map((p: any) => p.text))
      .join("\n").trim()
    if (text) {
      w.lastResult = text
      try { require("fs").writeFileSync(resultPath(name), text) } catch {}
    }
  } catch {}
  pushEvent(`!ev ${name} done`)
}

// ── Tools ───────────────────────────────────────────────

const toolDefs = {

  worker_create: tool({
    description: "Tạo worker mới (opencode serve riêng). Worker có context độc lập, dùng để xử lý task song song.",
    args: {
      name: tool.schema.string().describe("Tên worker (vd: Worker-API)"),
      model: tool.schema.string().optional().describe(`Model, mặc định ${DEFAULT_MODEL}`),
      agent: tool.schema.string().optional().describe("Agent: build (mặc định, đầy đủ tool) hoặc plan (chỉ đọc)"),
    },
    async execute(args, ctx) {
      const name = args.name
      if (workers.has(name)) throw new Error(`Worker '${name}' already exists`)
      if (workers.size >= MAX_WORKERS) throw new Error(`Max ${MAX_WORKERS} workers`)

      const port = nextPort()
      const pid = await startServe(port)
      const agent = args.agent || "build"
      const sessionId = await createSession(port, name, agent)

      const w = { name, port, pid, sessionId, model: args.model || DEFAULT_MODEL, status: "running" }
      workers.set(name, w)
      setStatus(name, "running")

      // Start SSE monitor in background
      monitorSSE(name, port).catch(() => {})

      return `+${name}`
    },
  }),

  worker_send: tool({
    description: "Gửi task cho worker (non-blocking). Worker sẽ xử lý và bot sẽ báo !ev khi xong.",
    args: {
      name: tool.schema.string().describe("Tên worker"),
      task: tool.schema.string().describe("Nhiệm vụ mô tả chi tiết"),
    },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)

      const [provider, modelId] = w.model.includes("/") ? w.model.split("/") : ["opencode", w.model]

      await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/prompt_async`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          parts: [{ type: "text", text: args.task }],
          model: { providerID: provider, modelID: modelId },
        }),
      })
      setStatus(args.name, "running")
      return "+"
    },
  }),

  worker_status: tool({
    description: "Đọc trạng thái worker từ cache. CHỈ dùng khi user hỏi, KHÔNG dùng để chờ.",
    args: {
      name: tool.schema.string().optional().describe("Tên worker (bỏ trống = tất cả)"),
    },
    async execute(args, ctx) {
      if (args.name) {
        const w = workers.get(args.name)
        if (!w) return "dead"
        return w.status
      }
      if (workers.size === 0) return "(none)"
      return [...workers.entries()].map(([n, w]) => `${n} ${w.status}`).join("\n")
    },
  }),

  worker_result: tool({
    description: "Đọc kết quả worker. Trả text nếu có, hoặc '(chưa xong)' nếu chưa.",
    args: {
      name: tool.schema.string().describe("Tên worker"),
    },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) return "(không tìm thấy worker)"
      if (w.status === "error") return `(worker lỗi: ${w.status})`
      if (w.status === "dead") return "(worker đã chết)"
      if (w.lastResult) return w.lastResult
      try {
        const txt = require("fs").readFileSync(resultPath(args.name), "utf-8")
        if (txt) { w.lastResult = txt; return txt }
      } catch {}
      return `(${args.name}: ${w.status} — đợi !ev ${args.name} done)`
    },
  }),

  worker_allow: tool({
    description: "Chấp nhận permission đang chờ của worker.",
    args: {
      name: tool.schema.string().describe("Tên worker"),
    },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)
      if (!w.pendingPermission) throw new Error("No pending permission")

      await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/permissions/${w.pendingPermission}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "allow" }),
      })
      w.pendingPermission = undefined
      setStatus(args.name, "running")
      return "ok"
    },
  }),

  worker_deny: tool({
    description: "Từ chối permission đang chờ của worker.",
    args: {
      name: tool.schema.string().describe("Tên worker"),
    },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)
      if (!w.pendingPermission) throw new Error("No pending permission")

      await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/permissions/${w.pendingPermission}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "deny" }),
      })
      w.pendingPermission = undefined
      setStatus(args.name, "running")
      return "ok"
    },
  }),

  worker_kill: tool({
    description: "Hủy worker và dọn dẹp.",
    args: {
      name: tool.schema.string().describe("Tên worker"),
    },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)

      try { await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`, { method: "POST" }) } catch {}
      try { process.kill(w.pid) } catch {}
      try { process.kill(w.pid, "SIGKILL") } catch {}

      workers.delete(args.name)
      try { require("fs").rmSync(statusPath(args.name), { force: true }) } catch {}
      try { require("fs").rmSync(resultPath(args.name), { force: true }) } catch {}
      try { require("fs").rmSync(permPath(args.name), { force: true }) } catch {}
      return `-${args.name}`
    },
  }),

  worker_killall: tool({
    description: "Hủy tất cả worker.",
    args: {},
    async execute(args, ctx) {
      const names = [...workers.keys()]
      for (const name of names) {
        const w = workers.get(name)
        try { await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`, { method: "POST" }) } catch {}
        try { process.kill(w.pid) } catch {}
      }
      const count = workers.size
      workers.clear()
      return String(count)
    },
  }),
}

// ── Plugin entry ────────────────────────────────────────

export const AgentTeamwork = async ({ client, $ }) => {
  _client = client

  // Fallback poll: nếu SSE đứt, poll HTTP để không bỏ sót sự kiện
  const fallback = setInterval(async () => {
    for (const [name, w] of workers) {
      if (w.status === "dead" || w.status === "error") continue
      try {
        const res = await fetch(`http://127.0.0.1:${w.port}/session/status`)
        const json = await res.json()
        const st = json[w.sessionId] && json[w.sessionId].type
        if (st === "idle" && w.status !== "idle") {
          handleIdle(name).catch(() => pushEvent(`!ev ${name} done`))
        }
        // Also check if stuck on busy for too long → might be permission
        if (st === "busy" && w.status === "permission") {
          // SSE caught it, but fallback confirms
        }
      } catch {}
    }
  }, 5000)

  return {
    dispose: async () => {
      clearInterval(fallback)
      const names = [...workers.keys()]
      for (const name of names) {
        const w = workers.get(name)
        try { await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`, { method: "POST" }) } catch {}
        try { process.kill(w.pid) } catch {}
      }
      workers.clear()
      try { require("fs").rmSync(statusDir, { recursive: true, force: true }) } catch {}
    },

    tool: toolDefs,
  }
}
