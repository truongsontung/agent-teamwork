// Agent Teamwork Plugin — 1 file thay toàn bộ bash script
// Quản lý opencode serve workers trực tiếp từ Manager TUI

// tool() identity wrapper (no import needed)
function tool(def) { return def }

// ── Config ──────────────────────────────────────────────

const PORT_BASE = 4091
const DEFAULT_MODEL = "deepseek/deepseek-v4-pro"
let _client = null  // SDK client, set at plugin init
const WORKER_CONFIG = (() => {
  try {
    const home = process.env.AGENT_TEAMWORK_HOME || `${process.env.HOME || "~"}/.config/opencode`
    const txt = require("fs").readFileSync(`${home}/worker.json`, "utf-8")
    return JSON.parse(txt)
  } catch { return {} }
// end Worker)()

// ── Types ───────────────────────────────────────────────


// ── State ───────────────────────────────────────────────

const workers = new Map()
const statusDir = `${process.env.PROJECT_DIR || process.cwd()}/.worker`

function statusPath(name) { return `${statusDir}/_${name}.status` }
function resultPath(name) { return `${statusDir}/_${name}.result` }
function permPath(name)   { return `${statusDir}/_${name}.perm` }

function setStatus(name, st) {
  const w = workers.get(name)
  if (w) w.status = st
  try { require("fs").mkdirSync(statusDir, { recursive: true }) } catch {}
  require("fs").writeFileSync(statusPath(name), st)
  writeStatusLog()
// end Worker

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
// end Worker

// ── Port allocation ─────────────────────────────────────

function nextPort() {
  let p = PORT_BASE
  while (true) {
    const used = [...workers.values()].some(w => w.port === p)
    if (!used) return p
    p++
  }
// end Worker

// ── Serve lifecycle ─────────────────────────────────────

function writeWorkerConfig(name, port) {
  const dir = `${statusDir}/configs`
  try { require("fs").mkdirSync(dir, { recursive: true }) } catch {}
  const cfg = {
    "$schema": "https://opencode.ai/config.json",
    permission: WORKER_CONFIG.permission || { bash: "allow", read: "allow", edit: "allow", write: "allow" },
  }
  const path = `${dir}/${name}.json`
  require("fs").writeFileSync(path, JSON.stringify(cfg))
  return path
// end Worker

async function startServe(port, name) {
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
// end Worker

async function createSession(port, name) {
  const res = await fetch(`http://127.0.0.1:${port}/session`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: name }),
  })
  const json = await res.json() 
  return json.id
// end Worker

// ── SSE Monitor (per worker) ────────────────────────────

async function pushEvent(msg) {
  if (!_client) return
  try {
    await _client.tui.appendPrompt({ body: { text: msg } })
    await _client.tui.submitPrompt()
  } catch {
    _client && _client.tui.appendPrompt({ body: { text: msg } }).catch(() => {})
  }
// end Worker
// end Worker

async function monitorSSE(name, port) {
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
          let json
          try { json = JSON.parse(line.slice(6)) } catch { continue }
          handleSSE(name, json)
        }
      }
    } catch {
      // reconnect
    }
    await Bun.sleep(2000)
  }
// end Worker

function handleSSE(name, event) {
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
    const st = props.status && props.status.type || ""
    if (st === "idle" && prevStatus !== "idle") setStatus(name, "idle")
    else if (st === "busy" && prevStatus !== "running") setStatus(name, "running")
  }
// end Worker

function saveResult(name) {
  const w = workers.get(name)
  if (!w) return
  fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/message`)
    .then(r => r.json())
    .then((data) => {
      const msgs = Array.isArray(data) ? data : [data]
      const text = msgs
        .flatMap((m) => (m.parts || []).filter((p) => p.type === "text").map((p) => p.text))
        .join("\n").trim()
      if (text) {
        w.lastResult = text
        try { require("fs").writeFileSync(resultPath(name), text) } catch {}
      }
    })
    .catch(() => {})
// end Worker

async function handleIdle(name) {
  const w = workers.get(name)
  if (!w || w.status === "idle") return
  setStatus(name, "idle")
  // Fetch result before pushing event
  try {
    const res = await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/message`)
    const data = await res.json()
    const msgs = Array.isArray(data) ? data : [data]
    const text = msgs
      .flatMap((m) => (m.parts || []).filter((p) => p.type === "text").map((p) => p.text))
      .join("\n").trim()
    if (text) {
      w.lastResult = text
      try { require("fs").writeFileSync(resultPath(name), text) } catch {}
    }
  } catch {}
  pushEvent(`!ev ${name} done`)
// end Worker

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
        const w = workers.get(name)
        try { await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`, { method: "POST" }) } catch {}
        try { process.kill(w.pid) } catch {}
      }
      const count = workers.size
      workers.clear()
      return String(count)
    },
  }),
// end Worker

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
// end Worker
