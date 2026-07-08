# Agent Configuration Examples

## Ví dụ 1: MiMo + OpenCode

```json
{
  "session_name": "mimo-opencode",
  "agents": {
    "A": {
      "name": "Manager",
      "role": "supervisor",
      "tool": "opencode",
      "model": "gpt-4",
      "mode": "plan",
      "description": "Giám sát"
    },
    "B": {
      "name": "Worker",
      "role": "executor", 
      "tool": "mimo",
      "model": "claude-3-opus",
      "mode": "build",
      "description": "Thực thi"
    }
  }
}
```

## Ví dụ 2: Hai OpenCode

```json
{
  "session_name": "dual-opencode",
  "agents": {
    "A": {
      "name": "Planner",
      "tool": "opencode",
      "model": "gpt-4",
      "mode": "plan"
    },
    "B": {
      "name": "Builder",
      "tool": "opencode", 
      "model": "gpt-4-turbo",
      "mode": "build"
    }
  }
}
```

## Ví dụ 3: Claude + MiMo

```json
{
  "session_name": "claude-mimo",
  "agents": {
    "A": {
      "name": "Supervisor",
      "tool": "claude",
      "model": "claude-3-opus",
      "mode": "plan"
    },
    "B": {
      "name": "Executor",
      "tool": "mimo",
      "model": "mimo-v2-pro",
      "mode": "build"
    }
  }
}
```

## Supported Tools

| Tool | Command | Notes |
|------|---------|-------|
| `opencode` | `opencode --model X --mode Y` | Supports plan/build modes |
| `mimo` | `mimo --model X` | MiMo agent |
| `claude` | `claude --model X` | Anthropic Claude |
| `codex` | `codex --model X` | OpenAI Codex |

## Supported Models

### OpenAI
- `gpt-4`
- `gpt-4-turbo`
- `gpt-4o`
- `gpt-3.5-turbo`

### Anthropic
- `claude-3-opus`
- `claude-3-sonnet`
- `claude-3-haiku`

### MiMo
- `mimo-v2-pro`
- `mimo-v2-lite`

## Modes

- `plan` - ReadOnly, design, analyze
- `build` - Full access, write code, execute
