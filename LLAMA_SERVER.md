# Running TurboCode with llama-server

TurboCode works with any local inference server that speaks the OpenAI chat
completions API: llama-server, MLX VLM, LM Studio, Ollama, vLLM and others.
For the best experience, use **llama-server** from
[llama.cpp](https://github.com/ggml-org/llama.cpp).

## Why llama-server

llama-server answers `GET /props`, and TurboCode reads it so that nothing has
to be configured by hand:

- **Context window.** `default_generation_settings.n_ctx` is the context the
  model was loaded with. TurboCode sizes the conversation to it and follows a
  reload with a different `-c`.
- **Reasoning.** `chat_template_caps.reasoning_effort_levels` lists the levels
  the model's chat template accepts (for example `none`, `minimal`, `low`,
  `medium`, `high`, `max`). The composer offers exactly those levels and
  changes them live, per request, without restarting the server.
- **Image input.** `modalities.vision` says whether a vision projector is
  loaded, so images are offered only when the model can see them.
- **Automatic compaction.** Because the context window is known, TurboCode
  compacts the conversation before the next message once it passes a
  threshold (80% by default, **Settings → Agents → Context**), with the same
  summary as `/compact`.

## Recommended models

The model is your choice: TurboCode works with any model your server can run
with tool calls. These are suggestions.

On a Mac, mixture-of-experts (MoE) models give the best balance of quality and
speed, because only a few billion parameters are active for each token. Good
choices are:

- **Qwen3.6-35B-A3B**, for a Mac with 32 GB or more
- **SenseNova**, with its looped transformer
- **Inkling-2-Mini**, described below

### Inkling-2-Mini

Inkling-2-Mini is a recent model, released in November 2026. It drew
attention right away for its looped transformer: the intermediate layers
(the middle 12 of 24) run three times for each token, which adds depth
without adding weights. In my experience it is on par with the
dense Qwen3.8-27B.

It is a 26.4B mixture-of-experts model with 3.4B active parameters, text and
image input, Apache-2.0 license. Since its release I have often used
TurboCode with this model, in the
[AtomicChat GGUF build](https://huggingface.co/AtomicChat/Inkling-2-Mini-GGUF),
which needs llama.cpp b12600 or newer.

| Mac memory | File | Size |
|---|---|---|
| 32 GB or more (recommended) | a larger `Inkling-2-Mini-AD-*` quantization, such as `AD-Q4_K` | 16.5 GB |
| 16 GB | `Inkling-2-Mini-AD-IQ2_M.gguf` | 8.7 GB |

For image input, also download `mmproj-Inkling-2-Mini-BF16.gguf` (642 MB).

Prefer the `AD-` files; the model card lists which other files load on
which llama.cpp build.

## Mac or a dedicated server

A model running on the same Mac shares memory and GPU with everything else
you do. A machine on your local network that serves the model is better when
you have one: the Mac stays responsive, and the server can keep a larger
quantization or context loaded. The first-launch setup finds a server on
another machine when you type its address under **Another machine**.

## Ready-to-use script

[`Scripts/turbocode-llama-server.sh`](Scripts/turbocode-llama-server.sh)
starts llama-server with the configuration below. It is opinionated on
purpose: one fixed set of flags gives a reproducible result, so a problem can
be compared against a known setup.

```bash
MODEL=~/models/Inkling-2-Mini-AD-IQ2_M.gguf Scripts/turbocode-llama-server.sh
```

```bash
MODEL=~/models/Inkling-2-Mini-AD-IQ2_M.gguf MMPROJ=~/models/mmproj-Inkling-2-Mini-BF16.gguf Scripts/turbocode-llama-server.sh
```

| Variable | Default | Meaning |
|---|---|---|
| `MODEL` | required | GGUF model file |
| `MMPROJ` | unset | Vision projector; set it to enable image input |
| `LLAMA_SERVER` | `llama-server` from `PATH` | The llama-server binary |
| `HOST` | `127.0.0.1` | Listen address; `0.0.0.0` serves the whole local network |
| `PORT` | `8080` | Listen port, one of those TurboCode probes on first launch |
| `CTX` | `32768` | Context window in tokens |
| `KV` | `q4_0` | KV cache type for K and V |
| `EFFORT` | `low` | Starting reasoning effort |

Arguments after `--` are passed to llama-server and override the defaults,
for example `-- --temp 0.8`. `DRY_RUN=1` prints the command without starting
the server.

`HOST=0.0.0.0` makes the server reachable by every device on your network,
with no authentication. Use it only on a network you trust.

## Recommended flags

These are the flags the script passes and why.

| Flag | Why |
|---|---|
| `--jinja` | Runs the model's own chat template. Required for tool calls and for the reasoning levels in `/props`. |
| `-c 32768` | 32K fits a 16 GB Mac with the IQ2_M model. Raise it if memory allows. |
| `-np 1` | One slot: the whole context belongs to one conversation and its prompt cache survives between turns. |
| `-fa on` | Flash attention, required for a quantized KV cache. |
| `--cache-type-k q4_0 --cache-type-v q4_0` | Cuts the KV cache to about a quarter of `f16`. `q8_0` keeps more quality where memory allows. |
| `--reasoning on` | Enables the model's thinking. |
| `--reasoning-preserve` | Keeps earlier reasoning in the history for templates that support it. It is llama-server's default; stated for clarity. |
| `--reasoning-effort low` | The starting level. TurboCode sends the composer's level with each request. |
| `--temp 0.6 --top-k 20 --top-p 1 --min-p 0.0` | The sampling I use. The model's own generation config uses temperature 1.0. |
| `--presence-penalty 0.0 --repeat-penalty 1.0` | No penalties: they disturb code and tool-call arguments. |
| `--load-mode none` | Reads the whole model into memory at startup instead of memory-mapping it. |
| `--metrics` | Enables `GET /metrics` (see below). |
| `--no-mmproj` / `--mmproj FILE` | Vision off, or on with the given projector. |

`--props` is not needed and the script leaves it out. TurboCode only reads
`GET /props`, which always works; `--props` enables `POST /props`, which lets
any client change the server's global settings.

## Other servers

TurboCode tells three kinds of server apart, both on first launch and in
**Settings → Providers → Local Server**. Every kind must answer
`GET /v1/models`; what else it answers decides the kind.

| Server | Recognized by | Context window | Image input |
|---|---|---|---|
| llama-server | `GET /props` with `n_ctx` | Read from the server, follows a reload | Read from `/props` |
| MLX VLM (`mlx_vlm.server`) | `GET /health` with `loaded_model`, `model_ready` and `apc_enabled` | Chosen by you | On |
| Any other OpenAI-compatible server (LM Studio, Ollama, vLLM, …) | Neither of the above | Chosen by you | Off |

### MLX VLM

[MLX VLM](https://github.com/Blaizzy/mlx-vlm) runs models with Apple's MLX
framework. TurboCode recognizes its server from the `/health` response:

- **Loaded model.** `/health` names the model in memory, and TurboCode
  preselects it. `/v1/models` may also list other cached models that are not
  loaded.
- **Image input** is on, because every model `mlx_vlm.server` serves goes
  through a vision processor.
- **Context window** is chosen by you. MLX VLM reports the model's
  theoretical maximum (524K for SenseNova), not what fits in memory, so
  TurboCode never takes it from the server.
- **Reasoning levels** are not read: MLX VLM has no `/props`.

## Server endpoints

llama-server exposes more than TurboCode uses today. All of them are plain
`GET` requests on the server address.

- **`/props`** — always on. Besides the context window, reasoning levels and
  vision, it reports the chat template's capabilities (`supports_tool_calls`,
  `supports_parallel_tool_calls`, `supports_system_role`,
  `supports_preserve_reasoning`), the default sampling settings, the loaded
  model file and quantization (`model_path`, `model_ftype`), the number of
  slots, the llama.cpp build (`build_info`), and which optional endpoints are
  enabled (`endpoint_slots`, `endpoint_metrics`).
- **`/slots`** — on by default. Per slot: context size, whether it is
  processing, prompt tokens, how many were reused from the cache
  (`n_prompt_tokens_cache`), tokens decoded, and the sampling and reasoning
  settings of the current request.
- **`/metrics`** — needs `--metrics`. Prometheus counters since the server
  started: prompt tokens processed and reused from the cache, tokens
  generated, time spent on each, average prompt and generation throughput,
  requests processing and deferred, the longest sequence seen, and
  speculative decoding acceptance.
- **`/health`** — `{"status":"ok"}` once the model is loaded.

Every chat completion response also carries a `timings` object with the
prompt and generation token counts, cached tokens and tokens per second for
that single request.
