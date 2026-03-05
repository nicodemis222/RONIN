# RONIN — Context Window Guide

## The Problem

LM Studio defaults to `n_ctx = 4096` tokens. A 1-hour meeting generates ~9,000 words (~12,000 tokens) of transcript alone. Adding the system prompt, notes, and output tokens pushes the total to ~15,000+ tokens — far exceeding the default context window. This causes HTTP 400 errors (`n_keep >= n_ctx`) and blank copilot responses.

## Quick Fix (Do This First)

### Increase n_ctx in LM Studio

1. Open **LM Studio**
2. Go to the **Local Server** tab (left sidebar)
3. Click the **gear icon** next to your loaded model
4. Find **Context Length** (n_ctx) slider
5. Set it to **16384** (16K) minimum — **32768** (32K) recommended
6. Restart the model / reload

**CLI alternative:**
```bash
lms load --context-length 32768 <model-identifier>
```

### Memory Requirements by Mac Configuration

| Mac RAM | Recommended n_ctx | KV Cache Memory | Notes |
|---------|------------------|-----------------|-------|
| 16 GB  | 8,192 – 16,384   | ~1.5–3 GB       | Works with 8B Q4 models |
| 24 GB  | 16,384 – 32,768  | ~3–6 GB         | Comfortable for most meetings |
| 32 GB  | 32,768 – 49,152  | ~6–9 GB         | Can handle very long meetings |
| 64 GB+ | 65,536 – 131,072 | ~12–24 GB       | Full 2-hour meetings easily |

> **Tip:** Enable **Flash Attention** in LM Studio (GPU settings) to reduce KV cache memory by ~50%.

### Model Recommendations

| Model | Context | Active Params | Best For |
|-------|---------|---------------|----------|
| Qwen3-8B (Q4_K_M) | 32K native | 8B | 16GB Macs, good quality |
| Qwen3-30B-A3B (Q4) | 32K native | ~3B active | Fast inference, MoE architecture |
| Qwen3-14B (Q4_K_M) | 32K native | 14B | 24GB+ Macs, best quality |
| Qwen3-4B (Q4) | 32K native | 4B | Constrained hardware, decent quality |

## How RONIN Manages Context (Built-In Safeguards)

RONIN has three layers of defense against context overflow:

### Layer 1: Transcript Truncation
- **Copilot** (live): Keeps only the most recent ~6,000 chars (tail-only)
- **Summary** (end of meeting): Keeps 25% from the start + 75% from the end

### Layer 2: Retry with Halving
If the LLM returns a 400 error, RONIN automatically:
1. Halves the transcript budget (6K → 3K → 1.5K for copilot)
2. Retries up to 3 times
3. Returns empty suggestions on final failure (never crashes)

### Layer 3: Auto-Detection (NEW)
RONIN now queries LM Studio at startup to detect the loaded model's context length and automatically calibrates its transcript budgets:

| Detected n_ctx | Copilot Budget | Summary Budget | 1-hr Meeting? |
|---------------|---------------|----------------|---------------|
| 4,096          | ~5,700 chars   | ~11,500 chars  | ⚠️ Heavy truncation |
| 8,192          | ~11,500 chars  | ~23,000 chars  | 🟡 Partial (37%) |
| 16,384         | ~23,000 chars  | ~46,000 chars  | 🟡 Most content (73%) |
| 32,768+        | 30,000 chars   | 60,000 chars   | ✅ Full meeting |

## Architecture for Long Meetings

For meetings exceeding 1 hour, the system uses a **sliding window** approach:

```
┌──────────────────────────────────────────────────┐
│                Full Transcript (RAM)              │
│  [saved to ~/Library/Logs/Ronin/transcripts/]    │
├──────────────────────────────────────────────────┤
│  Copilot sees: last N chars of transcript        │
│  (real-time, tail-only window)                   │
├──────────────────────────────────────────────────┤
│  Summary sees: first 25% + last 75%             │
│  (captures intro context + recent decisions)     │
└──────────────────────────────────────────────────┘
```

The full transcript is **always** preserved on disk regardless of what the LLM sees. Export includes the complete untruncated transcript with speaker labels.

## Troubleshooting

### "Copilot suggestions go blank"
1. Check LM Studio — is a model loaded?
2. Check n_ctx — increase to at least 16K
3. Check RONIN debug console (Cmd+D) for error messages
4. Backend logs: `~/Library/Logs/Ronin/backend.log`

### "Summary generation failed"
1. Usually means n_ctx is too small for the full transcript
2. RONIN will retry with smaller windows automatically
3. Transcript is always saved regardless — check `~/Library/Logs/Ronin/transcripts/`

### CPU spikes during meeting
1. Increase `llm_debounce_seconds` in backend config (default: 10s)
2. Use a smaller/faster model (Qwen3-30B-A3B MoE is excellent)
3. Enable Flash Attention in LM Studio GPU settings
