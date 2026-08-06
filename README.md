# anu-agentic-stack

A personal agent stack that runs on a small aarch64 board: [Hermes
Agent](https://github.com/NousResearch/hermes-agent) on top,
[OpenCode](https://opencode.ai) underneath as the coding harness,
[zeromem](https://github.com/ptaranat/zeromem) for memory that costs no tokens, and a local
router that picks the cheapest model on [NeuralWatt](https://neuralwatt.com) that can still do
the job.

```
  you ── CLI / chat ──►  Hermes Agent
                           ├─ memory: zeromem      (Rust core, SQLite, zero LLM calls)
                           └─ skill:  opencode     (delegates coding tasks)
                                     │
                                     ▼
                           OpenCode  (coding harness)
                                     │
           both point at ────────────┤  OpenAI-compatible, 127.0.0.1
                                     ▼
                           wattrouter  (Rust)
                             heuristics → sticky tier → embed → score → tier
                                     │  pooled HTTPS, streaming passthrough
                                     ▼
                           api.neuralwatt.com/v1
```

## The four pieces

**Hermes Agent** is the thing you talk to. It holds the conversation, keeps long-term memory,
and delegates. It is not the coding agent.

**OpenCode** is the coding harness. Hermes drives it through its bundled `opencode` skill —
one-shot `opencode run` for bounded tasks, a background PTY session for iterative work.

**zeromem** is the memory provider. Its point is in the name: indexing and retrieval are
deterministic, so remembering something costs zero tokens. It keeps raw conversation turns
with provenance rather than LLM-written summaries, which means recall returns what was
actually said, not a paraphrase of it.

**wattrouter** is a local proxy that scores each prompt for difficulty and routes it to the
cheapest tier that can handle it. It speaks the OpenAI wire protocol in both directions, so
anything that can talk to OpenAI can sit in front of it.

## Routing

| Tier | Model | Context | Used for |
|------|-------|---------|----------|
| `heavy` | `kimi-k3` | 1M | Architecture, multi-file reasoning, debugging |
| `code` | `kimi-k2.7-code` | 262K | Code-shaped work below the heavy threshold |
| `long` | `glm-5.2` | 1M | Anything over ~200K tokens of context |
| `mid` | `qwen3.6-35b-fast` | 131K | The working default: tool calls, structured output |
| `cheap` | `deepseek-v4-flash` | 1M | Lookups, short answers, chat |
| `aux` | `gemma-4-31b` | 262K | Background work: titles, summaries, compaction |

Two things make this fast enough to sit in a hot path. Most turns never reach the scorer — a
heuristic pass catches the obvious cases, and a follow-up turn reuses its session's tier
instead of re-scoring. When the scorer does run it embeds only the last user message truncated
to ~512 tokens, so routing costs the same whether the conversation is one turn or a hundred.

The router also picks along a second axis. NeuralWatt exposes `-fast` variants with thinking
disabled and `-flex` variants that are cheaper but held serially. Interactive traffic gets
`-fast`; only background and cron work gets `-flex`, because serialization would be felt
immediately in a live session.

Set `x-wattrouter-tier` on a request to override the decision entirely.

## Resource floor

The stack is built for generic aarch64 Linux. Memory is what binds, and the deciding factor is
whether zeromem runs its ONNX embedder or falls back to hashing.

| RAM | Embedder | Notes |
|-----|----------|-------|
| 8GB+ | ONNX bge-small-en-v1.5 | Recommended. Best recall quality. |
| 4GB | Hash fallback (`use_model: false`) | Skips the 130MB model. Lower recall, much lower RSS. |

The router and zeromem share one model cache directory, so the model is downloaded once rather
than once per process.

## Credentials

One: `NEURALWATT_API_KEY`. Supply it through the environment or a systemd `EnvironmentFile` —
never a tracked file. See `.env.example`.

## Getting started

```sh
just toolchain                        # are the required tools present
cargo build --release --manifest-path router/Cargo.toml
sudo NEURALWATT_API_KEY=nw-... deploy/bootstrap-pi.sh
deploy/install-zeromem.sh             # memory; compiles a Rust extension
NEURALWATT_API_KEY=nw-... scripts/verify-stack.sh
```

The router runs without a scoring head, taking the policy's unscored path. To fit
one:

```sh
uv run --with datasets python train/fetch_dataset.py
cargo run --release --manifest-path router/Cargo.toml --bin train-head \
  -- train/prompts.jsonl > ~/.hermes/memory/zeromem-models/head.json
```

The head carries thresholds calibrated against its own score distribution, so
they cannot drift apart from the weights that produced them.

## Credits

The routing approach follows [RouteLLM](https://github.com/lm-sys/RouteLLM) (Ong et al.,
LMSYS) — win-rate scoring against a strong/weak model pair, with thresholds calibrated to a
target traffic split. The implementation here is independent: it embeds locally instead of
calling a hosted embedding API, and it thresholds into several tiers rather than two.

Memory is [zeromem](https://github.com/ptaranat/zeromem), an implementation of Zero-Mem (Xiao
et al., arXiv:2607.29377).

## License

MIT.
