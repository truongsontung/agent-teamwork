// Agent Teamwork Plugin
// Manager tạo worker → send → wait → kill. Không SSE, không !ev.
import { z } from "zod"
function tool(def) { return def }
tool.schema = z

const PORT_BASE = 4091
const DEFAULT_MODEL = "deepseek/deepseek-v4-pro"
const MAX_WORKERS = 5
const DEFAULT_TIMEOUT = 120

const workers = new Map()
const statusDir = `${process.env.PROJECT_DIR || process.cwd()}/.worker`

// ── Helpers ─────────────────────────────────────────────

function nextPort() {
  let p = PORT_BASE
  while ([...workers.values()].some(w => w.port === p)) p++
  return p
}

function setStatus(n, s) {
  const w = workers.get(n); if (w) w.status = s
  try { require("fs").mkdirSync(statusDir, { recursive: true }) } catch {}
  require("fs").writeFileSync(`${statusDir}/_${n}.status`, s)
}

async function startServe(port) {
  const proc = Bun.spawn(["opencode", "serve", "--port", String(port), "--hostname", "127.0.0.1"], { stdout: "pipe", stderr: "pipe" })
  for (let i = 0; i < 30; i++) {
    try { await fetch(`http://127.0.0.1:${port}/session/status`, { signal: AbortSignal.timeout(2000) }); return proc.pid }
    catch {}
    await Bun.sleep(1000)
  }
  proc.kill()
  throw new Error(`Serve not ready`)
}

async function createSession(port, name, agent) {
  const res = await fetch(`http://127.0.0.1:${port}/session`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: name, agent }),
  })
  return (await res.json()).id
}

function extractText(data) {
  const msgs = Array.isArray(data) ? data : [data]
  return msgs.flatMap(m => {
    const parts = m.parts || (Array.isArray(m) ? m : [m])
    return parts.filter(p => p && p.type === "text").map(p => p.text)
  }).join("\n").trim()
}

async function fetchResult(w) {
  const res = await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/message`)
  const text = extractText(await res.json())
  if (text) {
    w.lastResult = text
    try { require("fs").mkdirSync(statusDir, { recursive: true }) } catch {}
    require("fs").writeFileSync(`${statusDir}/_${w.name}.result`, text)
  }
  return text
}

async function pollWait(w, timeout) {
  const start = Date.now()
  while (Date.now() - start < timeout * 1000) {
    try {
      const res = await fetch(`http://127.0.0.1:${w.port}/session/status`)
      const json = await res.json()
      const st = json[w.sessionId] && json[w.sessionId].type
      if (st === "idle" || !json[w.sessionId]) {
        setStatus(w.name, "idle")
        return await fetchResult(w)
      }
    } catch {}
    await new Promise(r => setTimeout(r, 2000))
  }
  throw new Error(`Timeout waiting for ${w.name}`)
}

// ── Tools ───────────────────────────────────────────────

const toolDefs = {

  worker_create: tool({
    description: "Tạo worker (openode serve riêng). Dùng agent build (đủ tool) hoặc plan (chỉ đọc).",
    args: {
      name: tool.schema.string().describe("Tên worker"),
      model: tool.schema.string().optional().describe(`Model, mặc định ${DEFAULT_MODEL}`),
      agent: tool.schema.string().optional().describe("build | plan. Mặc định build."),
    },
    async execute(args, ctx) {
      const name = args.name
      if (workers.has(name)) throw new Error(`Worker '${name}' already exists`)
      if (workers.size >= MAX_WORKERS) throw new Error(`Max ${MAX_WORKERS} workers`)
      const port = nextPort()
      const pid = await startServe(port)
      const agent = args.agent || "build"
      const sessionId = await createSession(port, name, agent)
      workers.set(name, { name, port, pid, sessionId, model: args.model || DEFAULT_MODEL, status: "running" })
      setStatus(name, "running")
      return `+${name}`
    },
  }),

  worker_send: tool({
    description: "Gửi task cho worker (non-blocking). Dùng worker_wait để lấy kết quả.",
    args: {
      name: tool.schema.string().describe("Tên worker"),
      task: tool.schema.string().describe("Nhiệm vụ chi tiết"),
    },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)
      const [provider, modelId] = w.model.includes("/") ? w.model.split("/") : ["opencode", w.model]
      await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/prompt_async`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ parts: [{ type: "text", text: args.task }], model: { providerID: provider, modelID: modelId } }),
      })
      setStatus(args.name, "running")
      return "+"
    },
  }),

  worker_wait: tool({
    description: "Đợi worker hoàn thành và trả kết quả. Blocking, có timeout.",
    args: {
      name: tool.schema.string().describe("Tên worker"),
      timeout: tool.schema.number().optional().describe(`Timeout giây, mặc định ${DEFAULT_TIMEOUT}`),
    },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)
      const result = await pollWait(w, args.timeout || DEFAULT_TIMEOUT)
      return result || "(không có kết quả)"
    },
  }),

  worker_allow: tool({
    description: "Duyệt permission cho worker.",
    args: { name: tool.schema.string().describe("Tên worker") },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)
      if (!w.pendingPermission) throw new Error("No pending permission")
      const res = await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/permissions/${w.pendingPermission}`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "allow" }),
      })
      if (!res.ok) throw new Error(`Allow failed: HTTP ${res.status}`)
      w.pendingPermission = undefined
      setStatus(args.name, "running")
      return "ok"
    },
  }),

  worker_deny: tool({
    description: "Từ chối permission cho worker.",
    args: { name: tool.schema.string().describe("Tên worker") },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)
      if (!w.pendingPermission) throw new Error("No pending permission")
      const res = await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/permissions/${w.pendingPermission}`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "deny" }),
      })
      if (!res.ok) throw new Error(`Deny failed: HTTP ${res.status}`)
      w.pendingPermission = undefined
      setStatus(args.name, "running")
      return "ok"
    },
  }),

  worker_kill: tool({
    description: "Hủy worker.",
    args: { name: tool.schema.string().describe("Tên worker") },
    async execute(args, ctx) {
      const w = workers.get(args.name)
      if (!w) throw new Error(`Worker '${args.name}' not found`)
      try { await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`, { method: "POST" }) } catch {}
      try { process.kill(w.pid) } catch {}
      try { process.kill(w.pid, "SIGKILL") } catch {}
      workers.delete(args.name)
      return `-${args.name}`
    },
  }),

  worker_killall: tool({
    description: "Hủy tất cả worker.",
    args: {},
    async execute(args, ctx) {
      const names = [...workers.keys()]
      for (const n of names) {
        const w = workers.get(n)
        try { await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`, { method: "POST" }) } catch {}
        try { process.kill(w.pid) } catch {}
      }
      const c = workers.size
      workers.clear()
      return String(c)
    },
  }),

  worker_status: tool({
    description: "Xem trạng thái worker (chỉ khi user hỏi).",
    args: { name: tool.schema.string().optional().describe("Tên worker") },
    async execute(args, ctx) {
      if (args.name) {
        const w = workers.get(args.name)
        return w ? w.status : "dead"
      }
      if (workers.size === 0) return "(none)"
      return [...workers.entries()].map(([n, w]) => `${n} ${w.status}`).join("\n")
    },
  }),
}

// ── Plugin entry ────────────────────────────────────────

export const AgentTeamwork = async ({ client, $ }) => {
  // SSE monitor riêng cho permission detection
  for (const [, w] of workers) {
    const port = w.port
    ;(async () => {
      while (workers.has(w.name)) {
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
            const lines = buf.split("\n"); buf = lines.pop() || ""
            for (const line of lines) {
              if (!line.startsWith("data: ")) continue
              let json; try { json = JSON.parse(line.slice(6)) } catch { continue }
              const props = json.properties || {}
              if (props.sessionID !== w.sessionId) continue
              if (json.type === "permission.asked") {
                w.pendingPermission = props.id
                setStatus(w.name, "permission")
                client.tui.appendPrompt({ body: { text: `!ev ${w.name} permission ${props.permission || "?"}` } }).catch(() => {})
                client.tui.submitPrompt().catch(() => {})
              }
            }
          }
        } catch { await Bun.sleep(2000) }
      }
    })().catch(() => {})
  }

  return {
    dispose: async () => {
      for (const [n, w] of workers) {
        try { await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`, { method: "POST" }) } catch {}
        try { process.kill(w.pid) } catch {}
      }
      workers.clear()
      try { require("fs").rmSync(statusDir, { recursive: true, force: true }) } catch {}
    },
    tool: toolDefs,
  }
}
