# Danh sách Model theo Tool

## OpenCode (`opencode/...`)

| Model | Type | Mô tả |
|-------|------|--------|
| `opencode/gpt-5` | GPT | General |
| `opencode/gpt-5.1` | GPT | Faster |
| `opencode/gpt-5.5` | GPT | Latest |
| `opencode/gpt-5.5-pro` | GPT | Best quality |
| `opencode/claude-opus-4-8` | Claude | Best reasoning |
| `opencode/claude-sonnet-5` | Claude | Balanced |
| `opencode/deepseek-v4-flash` | DeepSeek | Fast & cheap |
| `opencode/deepseek-v4-pro` | DeepSeek | High quality |
| `opencode/gemini-3.5-flash` | Gemini | Fast |
| `opencode/mimo-v2.5-free` | MiMo | Free |
| `opencode/kimi-k2.7-code` | Kimi | Code-focused |
| `opencode/qwen3.6-plus` | Qwen | Good balance |

## Mimo (`mimo/...`)

| Model | Mô tả |
|-------|--------|
| `mimo/mimo-v2.5-pro` | Pro version |
| `mimo/mimo-v2.5-free` | Free version |
| `mimo/mimo-auto` | Auto select |

## Config Templates

### Combo 1: MiMo + OpenCode (Recommended)
```json
{
  "A": {"tool": "opencode", "model": "opencode/gpt-5.5", "mode": "plan"},
  "B": {"tool": "mimo", "model": "mimo/mimo-v2.5-pro", "mode": "build"}
}
```

### Combo 2: Dual OpenCode
```json
{
  "A": {"tool": "opencode", "model": "opencode/gpt-5.5", "mode": "plan"},
  "B": {"tool": "opencode", "model": "opencode/claude-opus-4-8", "mode": "build"}
}
```

### Combo 3: Cheap (Free models)
```json
{
  "A": {"tool": "opencode", "model": "opencode/deepseek-v4-flash", "mode": "plan"},
  "B": {"tool": "opencode", "model": "opencode/mimo-v2.5-free", "mode": "build"}
}
```
