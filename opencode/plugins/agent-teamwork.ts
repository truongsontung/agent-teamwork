// Agent Teamwork Plugin — 1 file thay toàn bộ bash script
// Quản lý opencode serve workers trực tiếp từ Manager TUI
import { type Plugin, tool } from "@opencode-ai/plugin"

// ── Config ──────────────────────────────────────────────

const PORT_BASE = 4091
const DEFAULT_MODEL = "opencode/deepseek-v4-flash-free"
let _client: any = null  // SDK client, set at plugin init
const WORKER_CONFIG = (() => {
  try {
    const home = process.env.AGENT_TEAMWORK_HOME || ""
    const txt = require("fs").readFileSync(`${home}/worker.json`, "utf-8")
    return JSON.parse(txt)
  } catch { return {} }
})()

// ── Types ───────────────────────────────────────────────

interface Worker {
  name: string
  port: number
  pid: number
  sessionId: string
  model: string
  status: string
  lastResult?: string
  pendingPermission?: string
}

// ── State ───────────────────────────────────────────────

const workers = new Map<string, Worker>()
const statusDir = `${process.env.PROJECT_DIR || process.cwd()}/.worker`

function statusPath(name: string) { return `${statusDir}/_${name}.status` }
function resultPath(name: string) { return `${statusDir}/_${name}.result` }
function permPath(name: string)   { return `${statusDir}/_${name}.perm` }

function setStatus(name: string, st: string) {
  const w = workers.get(name)
  if (w) w.status = st
  try { require("fs").mkdirSync(statusDir, { recursive: true }) } catch {}
  require("fs").writeFileSync(statusPath(name), st)
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

function writeWorkerConfig(name: string, port: number): string {
  const dir = `${statusDir}/configs`
  try { require("fs").mkdirSync(dir, { recursive: true }) } catch {}
  const cfg = {
    "$schema": "https://opencode.ai/config.json",
    permission: WORKER_CONFIG.permission || { bash: "allow", read: "allow", edit: "allow", write: "allow" },
  }
  const path = `${dir}/${name}.json`
  require("fs").writeFileSync(path, JSON.stringify(cfg))
  return path
}

async function startServe(port: number, name: string): Promise<number> {
  const cfgPath = writeWorkerConfig(name, port)
  const proc = Bun.spawn(
    ["opencode", "serve", "--port", String(port), "--hostname", "127.0.0.1"],
    {
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, OPENCODE_CONFIG: cfgPath },
    }
  )
  // Wait for serve ready
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

async function createSession(port: number, name: string): Promise<string> {
  const res = await fetch(`http://127.0.0.1:${port}/session`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: name }),
  })
  const json = await res.json() as any
  return json.id
}

// ── SSE Monitor (per worker) ────────────────────────────

async function monitorSSE(name: string, port: number) {
  while (true) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/event`)
      const reader = res.body!.getReader()
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
      await Bun.sleep(5000)
    }
  }
}

function handleSSE(name: string, event: any) {
  const type = event.type
  const props = event.properties || {}

  if (type === "session.idle") {
    setStatus(name, "idle")
    saveResult(name, event)
    _client?.tui.appendPrompt({ body: { text: `!ev ${name} done` } }).catch(() => {})
  } else if (type === "session.error") {
    setStatus(name, "error")
    _client?.tui.appendPrompt({ body: { text: `!ev ${name} error` } }).catch(() => {})
  } else if (type === "permission.asked") {
    setStatus(name, "permission")
    const w = workers.get(name)
    if (w) w.pendingPermission = props.id
    try { require("fs").writeFileSync(permPath(name), JSON.stringify(event)) } catch {}
    _client?.tui.appendPrompt({ body: { text: `!ev ${name} permission` } }).catch(() => {})
  } else if (type === "permission.replied") {
    setStatus(name, "running")
    const w = workers.get(name)
    if (w) w.pendingPermission = undefined
  } else if (type === "session.status") {
    const st = props.status?.type
    if (st === "idle") setStatus(name, "idle")
    else if (st === "busy") setStatus(name, "running")
  }
}

function saveResult(name: string, event: any) {
  const w = workers.get(name)
  if (!w) return
  // Get result text from session messages
  fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/message`)
    .then(r => r.json())
    .then((msgs: any) => {
      const parts = Array.isArray(msgs) ? msgs : (msgs.parts || [msgs])
      const text = parts
        .flatMap((m: any) => (m.parts || [m]).filter((p: any) => p.type === "text").map((p: any) => p.text))
        .join("\n")
      w.lastResult = text || JSON.stringify(msgs)
      require("fs").writeFileSync(resultPath(name), w.lastResult)
    })
    .catch(() => {})
}

// ── Tools ───────────────────────────────────────────────

const toolDefs = {

  worker_create: tool({
    description: "Tạo worker mới (opencode serve riêng). Worker có context độc lập, dùng để xử lý task song song.",
    args: {
      name: tool.schema.string().describe("Tên worker (vd: Worker-API)"),
      model: tool.schema.string().optional().describe(`Model, mặc định ${DEFAULT_MODEL}`),
    },
    async execute(args, ctx) {
      const name = args.name
      if (workers.has(name)) throw new Error(`Worker '${name}' already exists`)
      const max = WORKER_CONFIG.max_workers || 5
      if (workers.size >= max) throw new Error(`Max ${max} workers`)

      const port = nextPort()
      const pid = await startServe(port, name)
      const sessionId = await createSession(port, name)

      const w: Worker = { name, port, pid, sessionId, model: args.model || DEFAULT_MODEL, status: "running" }
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
    description: "Kiểm tra trạng thái worker(s). Trả về idle|running|permission|error|dead.",
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
    description: "Đọc kết quả text của worker đã hoàn thành.",
    args: {
      name: tool.schema.string().describe("Tên worker"),
    },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)
      if (w.lastResult) return w.lastResult
      try {
        const txt = require("fs").readFileSync(resultPath(args.name), "utf-8")
        return txt || "(empty)"
      } catch {
        throw new Error("No result yet")
      }
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
      try { require("fs").rmSync(`${statusDir}/configs/${args.name}.json`, { force: true }) } catch {}
      return `-${args.name}`
    },
  }),

  worker_killall: tool({
    description: "Hủy tất cả worker.",
    args: {},
    async execute(args, ctx) {
      const names = [...workers.keys()]
      for (const name of names) {
        const w = workers.get(name)!
        try { await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`, { method: "POST" }) } catch {}
        try { process.kill(w.pid) } catch {}
      }
      const count = workers.size
      workers.clear()
      return String(count)
    },
  }),

  worker_permission_info: tool({
    description: "Xem chi tiết permission đang chờ của worker.",
    args: {
      name: tool.schema.string().describe("Tên worker"),
    },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)
      try {
        const data = JSON.parse(require("fs").readFileSync(permPath(args.name), "utf-8"))
        const perm = data.properties?.permission || "?"
        const patterns = (data.properties?.patterns || []).join(", ")
        return `type=${perm} id=${w.pendingPermission}\npatterns=${patterns}`
      } catch {
        throw new Error("No permission info")
      }
    },
  }),
}

// ── Plugin entry ────────────────────────────────────────

export const AgentTeamwork: Plugin = async ({ client, $ }) => {
  _client = client

  return {
    dispose: async () => {
      const names = [...workers.keys()]
      for (const name of names) {
        const w = workers.get(name)!
        try { await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`, { method: "POST" }) } catch {}
        try { process.kill(w.pid) } catch {}
      }
      workers.clear()
    },

    tool: toolDefs,
  }
}
