// Agent Teamwork Plugin — event-driven, SSE reliable
import { z } from "zod"; function tool(def) { return def }; tool.schema = z

const PORT_BASE = 4091, MAX_WORKERS = 5
const DEFAULT_MODEL = "deepseek/deepseek-v4-pro"
let _client = null
const workers = new Map()

function nextPort(){let p=PORT_BASE;while([...workers.values()].some(w=>w.port===p))p++;return p}

// ── Serve ───────────────────────────────────────────────

async function startServe(port) {
  const p = Bun.spawn(["opencode","serve","--port",String(port),"--hostname","127.0.0.1"],{stdout:"pipe",stderr:"pipe"})
  for (let i=0;i<60;i++) {
    try { await fetch(`http://127.0.0.1:${port}/session/status`,{signal:AbortSignal.timeout(3000)}); return p.pid }
    catch { await Bun.sleep(1000) }
  }
  p.kill(); throw new Error("Serve not ready")
}

// ── Session ─────────────────────────────────────────────

async function createSession(port,name,agent) {
  const r = await fetch(`http://127.0.0.1:${port}/session`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({title:name,agent})})
  return (await r.json()).id
}

// ── Result ──────────────────────────────────────────────

function extractText(data) {
  const msgs = Array.isArray(data)?data:[data]
  return msgs.flatMap(m=>{const p=m.parts||(Array.isArray(m)?m:[m]);return p.filter(x=>x&&x.type==="text").map(x=>x.text)}).join("\n").trim()
}

async function fetchAndCache(w) {
  try {
    const r=await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/message`)
    const text=extractText(await r.json())
    if(text) w.lastResult=text
    return text||""
  }catch{return""}
}

// ── Event injection ─────────────────────────────────────

async function pushEvent(msg) {
  if(!_client)return
  try{await _client.tui.appendPrompt({body:{text:msg}});await _client.tui.submitPrompt()}catch{}
}

// ── SSE Monitor (1 per worker) ──────────────────────────

function monitor(name,port,sid) {
  (async()=>{
    while(true){
      const w=workers.get(name); if(!w||w._dead)return
      try{process.kill(w.pid,0)}catch{w._dead=true;return}
      try{
        const r=await fetch(`http://127.0.0.1:${port}/event`)
        if(!r.ok){await Bun.sleep(3000);continue}
        const reader=r.body.getReader();const d=new TextDecoder();let buf=""
        while(true){
          const{value,done}=await reader.read();if(done)break
          buf+=d.decode(value,{stream:true})
          const lines=buf.split("\n");buf=lines.pop()||""
          for(const line of lines){
            if(!line.startsWith("data: "))continue
            let ev;try{ev=JSON.parse(line.slice(6))}catch{continue}
            const p=ev.properties||{}
            if(p.sessionID&&p.sessionID!==sid)continue

            // ── Done ──
            if((ev.type==="session.status"&&p.status&&p.status.type==="idle")||ev.type==="session.idle"){
              if(w._done)continue; w._done=true
              await fetchAndCache(w); pushEvent(`!ev ${name} done`)
            }
            // ── Permission ──
            else if(ev.type==="permission.asked"){
              if(!w.pendingPermission){w.pendingPermission=p.id;pushEvent(`!ev ${name} permission ${p.permission||"?"}`)}
            }
            else if(ev.type==="permission.replied"){
              w.pendingPermission=undefined; w._done=false
            }
          }
        }
      }catch{await Bun.sleep(2000)}
    }
  })().catch(()=>{})
}

// ── Tools ───────────────────────────────────────────────

const tools={

worker_create:tool({description:"Tạo worker. agent: build (mặc định)|plan.",args:{name:tool.schema.string(),model:tool.schema.string().optional(),agent:tool.schema.string().optional()},async execute(args,ctx){const name=args.name;if(workers.has(name))throw new Error("exists");if(workers.size>=MAX_WORKERS)throw new Error("max");const port=nextPort();const pid=await startServe(port);const agent=args.agent||"build";const sid=await createSession(port,name,agent);workers.set(name,{name,port,pid,sessionId:sid,model:args.model||DEFAULT_MODEL,_dead:false,_done:false});monitor(name,port,sid);return`+${name}`}}),

worker_send:tool({description:"Gửi task (non-blocking).",args:{name:tool.schema.string(),task:tool.schema.string()},async execute(args,ctx){const w=workers.get(args.name);if(!w)throw new Error("not found");w._done=false;const[p,m]=w.model.includes("/")?w.model.split("/"):["opencode",w.model];await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/prompt_async`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({parts:[{type:"text",text:args.task}],model:{providerID:p,modelID:m}})});return"+"}}),

worker_result:tool({description:"Đọc kết quả.",args:{name:tool.schema.string()},async execute(args,ctx){const w=workers.get(args.name);if(!w)return"(không tìm thấy)";if(w.lastResult)return w.lastResult;const t=await fetchAndCache(w);return t||"(chưa có kết quả)"}}),

worker_allow:tool({description:"Duyệt permission.",args:{name:tool.schema.string()},async execute(args,ctx){const w=workers.get(args.name);if(!w)throw new Error("not found");const perm=w.pendingPermission;if(!perm)return"(đã auto-resolve)";try{const r=await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/permissions/${perm}`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action:"allow"})});if(!r.ok){w.pendingPermission=undefined;w._done=false;return`(HTTP ${r.status}, đã bỏ qua)`}}catch{}w.pendingPermission=undefined;w._done=false;return"ok"}}),

worker_kill:tool({description:"Hủy worker.",args:{name:tool.schema.string()},async execute(args,ctx){const w=workers.get(args.name);if(!w)return"-";try{await fetch(`http://127.0.0.1:${w.port}/session/${w.sessionId}/abort`,{method:"POST"})}catch{}try{process.kill(w.pid)}catch{}workers.delete(args.name);return`-${args.name}`}}),

worker_killall:tool({description:"Hủy tất cả.",args:{},async execute(args,ctx){const n=[...workers.keys()];for(const k of n){const w=workers.get(k);try{process.kill(w.pid)}catch{}}const c=workers.size;workers.clear();return String(c)}}),

worker_status:tool({description:"Trạng thái.",args:{name:tool.schema.string().optional()},async execute(args,ctx){const st=w=>w.pendingPermission?"permission":w._done?"idle":"running";if(args.name){const w=workers.get(args.name);return w?st(w):"dead"};if(workers.size===0)return"(none)";return[...workers.entries()].map(([n,w])=>`${n} ${st(w)}`).join("\n")}}),
}

// ── Plugin ──────────────────────────────────────────────

export const AgentTeamwork=async({client,$})=>{_client=client;return{dispose:async()=>{for(const[,w]of workers)try{process.kill(w.pid)}catch{};workers.clear()},tool:tools}}
