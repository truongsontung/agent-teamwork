// Agent Teamwork Plugin
// SSE-driven: worker send → SSE bắt done/permission → push !ev → Manager xử lý
import { z } from "zod"
function tool(def) { return def }
tool.schema = z

const PORT_BASE = 4091
const DEFAULT_MODEL = "deepseek/deepseek-v4-pro"
const MAX_WORKERS = 5
let _client = null

const workers = new Map()
const statusDir = `${process.env.PROJECT_DIR || process.cwd()}/.worker`

// ── Helpers ─────────────────────────────────────────────

function nextPort() { let p = PORT_BASE; while ([...workers.values()].some(w => w.port === p)) p++; return p }

function setStatus(n, s) { const w = workers.get(n); if (w) w.status = s }

async function startServe(port) {
  const proc = Bun.spawn(["opencode", "serve", "--port", String(port), "--hostname", "127.0.0.1"], { stdout: "pipe", stderr: "pipe" })
  for (let i = 0; i < 30; i++) {
    try { await fetch(`http://127.0.0.1:${port}/session/status`, { signal: AbortSignal.timeout(2000) }); return proc.pid }
    catch { await Bun.sleep(1000) }
  }
  proc.kill(); throw new Error("Serve not ready")
}

async function createSession(port, name, agent) {
  const r = await fetch(`http://127.0.0.1:${port}/session`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ title: name, agent }) })
  return (await r.json()).id
}

function extractText(data) {
  const msgs = Array.isArray(data) ? data : [data]
  return msgs.flatMap(m => { const p = m.parts || (Array.isArray(m) ? m : [m]); return p.filter(x => x && x.type === "text").map(x => x.text) }).join("\n").trim()
}

async function fetchAndCache(w) {
  try {
    const r = await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/message`)
    const text = extractText(await r.json())
    if (text) w.lastResult = text
    return text || ""
  } catch { return "" }
}

async function pushEvent(msg) {
  if (!_client) return
  try { await _client.tui.appendPrompt({ body: { text: msg } }); await _client.tui.submitPrompt() }
  catch {}
}

// ── SSE Monitor ─────────────────────────────────────────

async function monitorSSE(name, port, sessionId) {
  while (true) {
    const w = workers.get(name); if (!w || w.status === "dead") return
    try { process.kill(w.pid, 0) } catch { setStatus(name, "dead"); return }
    try {
      const res = await fetch(`http://127.0.0.1:${port}/event`)
      if (!res.ok) { await Bun.sleep(3000); continue }
      const reader = res.body.getReader(); const decoder = new TextDecoder(); let buf = ""
      while (true) {
        const { done, value } = await reader.read(); if (done) break
        buf += decoder.decode(value, { stream: true })
        const lines = buf.split("\n"); buf = lines.pop() || ""
        for (const line of lines) {
          if (!line.startsWith("data: ")) continue
          let json; try { json = JSON.parse(line.slice(6)) } catch { continue }
          const props = json.properties || {}
          if (props.sessionID && props.sessionID !== sessionId) continue
          const type = json.type
          // Permission
          if (type === "permission.asked" && w.status !== "permission") {
            w.pendingPermission = props.id; setStatus(name, "permission")
            pushEvent(`!ev ${name} permission ${props.permission || "?"}`)
          } else if (type === "permission.replied") {
            w.pendingPermission = undefined; setStatus(name, "running")
          }
          // Completion via session.status idle
          else if (type === "session.status" && (props.status && props.status.type) === "idle" && w.status !== "idle") {
            await fetchAndCache(w); setStatus(name, "idle"); pushEvent(`!ev ${name} done`)
          }
          // Also session.idle event
          else if (type === "session.idle" && w.status !== "idle") {
            await fetchAndCache(w); setStatus(name, "idle"); pushEvent(`!ev ${name} done`)
          }
        }
      }
    } catch { await Bun.sleep(2000) }
  }
}

// ── Tools ───────────────────────────────────────────────

const toolDefs = {

  worker_create: tool({
    description: "Tạo worker (openode serve). agent: build (đủ tool, mặc định) | plan (chỉ đọc).",
    args: {
      name: tool.schema.string().describe("Tên worker"),
      model: tool.schema.string().optional().describe(`Model`),
      agent: tool.schema.string().optional().describe("build|plan"),
    },
    async execute(args, ctx) {
      const name = args.name
      if (workers.has(name)) throw new Error(`Worker '${name}' exists`)
      if (workers.size >= MAX_WORKERS) throw new Error(`Max ${MAX_WORKERS}`)
      const port = nextPort(); const pid = await startServe(port)
      const agent = args.agent || "build"; const sid = await createSession(port, name, agent)
      const w = { name, port, pid, sessionId: sid, model: args.model || DEFAULT_MODEL, status: "running" }
      workers.set(name, w); setStatus(name, "running")
      monitorSSE(name, port, sid).catch(() => {})
      return `+${name}`
    },
  }),

  worker_send: tool({
    description: "Gửi task (non-blocking). Manager đợi !ev done rồi gọi worker_result.",
    args: { name: tool.schema.string().describe("Tên worker"), task: tool.schema.string().describe("Nhiệm vụ") },
    async execute(args, ctx) {
      const w = workers.get(args.name); if (!w) throw new Error(`Worker '${args.name}' not found`)
      const [p, m] = w.model.includes("/") ? w.model.split("/") : ["opencode", w.model]
      await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/prompt_async`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ parts: [{ type: "text", text: args.task }], model: { providerID: p, modelID: m } }),
      })
      setStatus(args.name, "running"); return "+"
    },
  }),

  worker_result: tool({
    description: "Đọc kết quả worker. Gọi SAU !ev done. Fetch từ serve nếu cache trống.",
    args: { name: tool.schema.string().describe("Tên worker") },
    async execute(args, ctx) {
      const w = workers.get(args.name); if (!w) return "(không tìm thấy)"
      if (w.lastResult) return w.lastResult
      const text = await fetchAndCache(w)
      return text || "(chưa có kết quả)"
    },
  }),

  worker_allow: tool({
    description: "Duyệt permission cho worker.",
    args: { name: tool.schema.string().describe("Tên worker") },
    async execute(args, ctx) {
      const w = workers.get(args.name); if (!w) throw new Error("not found")
      if (!w.pendingPermission) throw new Error("No pending permission")
      const r = await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/permissions/${w.pendingPermission}`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "allow" }),
      })
      if (!r.ok) throw new Error(`Allow failed: HTTP ${r.status}`)
      w.pendingPermission = undefined; setStatus(args.name, "running"); return "ok"
    },
  }),

  worker_kill: tool({
    description: "Hủy worker.",
    args: { name: tool.schema.string().describe("Tên worker") },
    async execute(args, ctx) {
      const w = workers.get(args.name); if (!w) throw new Error("not found")
      try { await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`, { method: "POST" }) } catch {}
      try { process.kill(w.pid) } catch {}; try { process.kill(w.pid, "SIGKILL") } catch {}
      workers.delete(args.name); return `-${args.name}`
    },
  }),

  worker_killall: tool({
    description: "Hủy tất cả worker.",
    args: {},
    async execute(args, ctx) {
      const names = [...workers.keys()]
      for (const n of names) { const w = workers.get(n); try { process.kill(w.pid) } catch {} }
      workers.clear(); return String(names.length)
    },
  }),

  worker_status: tool({
    description: "Xem trạng thái worker. Chỉ khi user hỏi.",
    args: { name: tool.schema.string().optional() },
    async execute(args, ctx) {
      if (args.name) { const w = workers.get(args.name); return w ? w.status : "dead" }
      if (workers.size === 0) return "(none)"
      return [...workers.entries()].map(([n, w]) => `${n} ${w.status}`).join("\n")
    },
  }),
}

export const AgentTeamwork = async ({ client, $ }) => {
  _client = client
  return {
    dispose: async () => {
      for (const [n, w] of workers) { try { process.kill(w.pid) } catch {} }
      workers.clear()
      try { require("fs").rmSync(statusDir, { recursive: true, force: true }) } catch {}
    },
    tool: toolDefs,
  }
}
