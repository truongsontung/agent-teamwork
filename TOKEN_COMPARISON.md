# Token Comparison: Original vs Optimized

## Original Prompts

### Agent A (Original)
- System prompt: ~800 tokens
- Response format: ~200 tokens
- Rules/examples: ~400 tokens
- **Total prompt: ~1400 tokens**
- Response per task: ~200 tokens

### Agent B (Original)
- System prompt: ~1000 tokens
- Response format: ~300 tokens
- Rules/examples: ~500 tokens
- **Total prompt: ~1800 tokens**
- Response per task: ~500 tokens

---

## Optimized Prompts

### Agent A (Optimized)
- System prompt: ~150 tokens
- Response format: ~50 tokens
- Rules: ~100 tokens
- **Total prompt: ~300 tokens** (↓79%)
- Response per task: ~30 tokens (↓85%)

### Agent B (Optimized)
- System prompt: ~200 tokens
- Response format: ~80 tokens
- Rules: ~100 tokens
- **Total prompt: ~380 tokens** (↓79%)
- Response per task: ~100 tokens (↓80%)

---

## Per-Task Token Usage

| Component | Original | Optimized | Savings |
|-----------|----------|-----------|---------|
| Agent A prompt | 1400 | 300 | -79% |
| Agent A response | 200 | 30 | -85% |
| Agent B prompt | 1800 | 380 | -79% |
| Agent B response | 500 | 100 | -80% |
| **Total per task** | **3900** | **810** | **-79%** |

---

## Cost Example (GPT-4, 100 tasks)

| Metric | Original | Optimized |
|--------|----------|-----------|
| Total tokens | 390,000 | 81,000 |
| Cost @ $0.03/1K | $11.70 | $2.43 |
| **Savings** | - | **$9.27 (79%)** |
