# ollama-monitoring

Passive performance monitoring for native Ollama on WSL2 with an NVIDIA GPU.

> **Ollama stays on its normal port.** Monitoring is passive: a collector reads
> llama.cpp performance telemetry emitted by Ollama into the systemd journal and
> exposes it to Prometheus. Clients do not route through the monitoring stack —
> nothing sits between them and `:11434`.

```text
Kilo / other clients
        |
        v
Native Ollama on WSL :11434          (systemd service, NOT containerized)
        |
        +---- systemd journal / llama.cpp timing logs
                          |
                          v
               journal metrics collector        (Vector, container)
                          |
                          v
                     Prometheus
                      /      \
          NVIDIA GPU exporter  Grafana
```

## Why journald

Ollama runs its inference through llama.cpp (`llama-server`). Every request
produces live engine telemetry in the `ollama.service` journal:

```text
slot print_timing: id 0 | task 13429 | prompt processing, n_tokens = 3840, progress = 0.19, t = 3.72 s / 1033.56 tokens per second
slot print_timing: id 0 | task 13429 | n_gen = 1466, tg = 22.55 t/s, tg_3s = 22.31 t/s
slot print_timing: id 0 | task 13429 | prompt eval time = 298.31 ms / 28 tokens (10.65 ms per token, 93.86 tokens per second)
slot print_timing: id 0 | task 13429 |        eval time = 8974.02 ms / 322 tokens (27.89 ms per token, 35.77 tokens per second)
slot print_timing: id 0 | task 13429 |       total time = 9272.34 ms / 350 tokens
```

This is the *actual compute engine* speaking. It reports live prefill speed and
live decode speed (`tg`, `tg_3s`) while a request is running — something the
previous HTTP-proxy architecture could never measure (it only saw terminal
usage counters, and deriving decode speed from `rate(token_counter)` measures
completion booking, not decode). It also exposes prompt-cache behavior that is
invisible at the HTTP layer.

An earlier iteration of this project used an HTTP proxy in the inference path
to reconstruct metrics from OpenAI usage fields. That architecture was removed
entirely: it metered only proxied traffic, could not see live t/s, complicated
streaming, and forced Ollama onto a nonstandard port.

## Components (all monitoring in Docker Compose)

| Service            | Image                            | Purpose                                        |
|--------------------|----------------------------------|------------------------------------------------|
| `journal-metrics`  | `timberio/vector:0.49.0-debian`  | Reads host journal, exports Prometheus metrics |
| `prometheus`       | `prom/prometheus:v3.14.0`        | Scrapes collector (2s) and GPU exporter (10s)  |
| `grafana`          | `grafana/grafana:13.0.8`         | Dashboards                                     |
| `nvidia-gpu-exporter` | `utkuozdemir/nvidia_gpu_exporter:1.15.0` | GPU power/utilization/VRAM/temp    |

There is no proxy service. Port 11434 belongs exclusively to native Ollama.

## Supported environment

* WSL2 with systemd enabled (Ubuntu), Ollama installed as a native systemd
  service (`ollama.service`), listening on `:11434`.
* Docker Desktop (or docker engine) in WSL; NVIDIA GPU passthrough for
  `nvidia-smi`.
* The collector image is the stock Vector image: it already ships the
  `journalctl` binary that Vector's journald source requires (verified for the
  pinned tag). No custom image build is needed.

## Journal access from the collector container

The collector reads the **host** journal read-only with minimum privilege:

* `/var/log/journal` → read-only (this WSL instance keeps a persistent journal
  here; adjust if yours only has `/run/log/journal`, which is also mounted).
* `/etc/machine-id` → read-only (lets `journalctl` find the right journal).
* The container runs as `user: "1000:1000"` with `group_add: ["999"]` — the
  host gid of `systemd-journal` (check with `getent group systemd-journal`).
  Journal files are `root:systemd-journal` mode `0640`, so the group grant is
  sufficient. No `--privileged`, no Docker socket, no host PID namespace, no
  writable host paths.
* Filtering happens inside `journalctl` (`--unit=ollama.service`); the
  collector only sees Ollama's own unit, current boot only.

The Vector journald checkpoint (read cursor) is persisted in
`./data/vector`, so restarting or recreating the collector resumes where it
stopped instead of replaying the boot into the counters. On the very first
start (or after wiping `./data/vector`) the collector ingests the *current
boot's* backlog once; counters jump accordingly and Prometheus handles it as a
counter reset. This is local observability — not billing-grade persistence.

## Metric semantics

Three concepts are kept strictly apart:

1. **Live engine telemetry** — gauges from llama.cpp status lines, meaningful
   only while a request runs. They are zeroed on slot release, so an idle
   system shows zeros, never stale speeds.
2. **Completed compute work** — counters/histograms from final per-request
   timing lines (tokens/durations the engine actually computed).
3. **Logical/request token counts** — from `task.n_tokens`, the submitted
   prompt size *including* tokens served from cache.

### Token semantics (measured, not assumed)

Controlled warm/cold experiments (repeating an identical prompt) show:

| line                                      | cold run | warm repeat |
|-------------------------------------------|----------|-------------|
| `new prompt, task.n_tokens` (logical)     | 44       | 44          |
| `prompt eval time ... / N tokens` (engine)| 44       | 4           |

So `task.n_tokens` is the *submitted* prompt size, while the final prompt-eval
line counts only tokens the engine *actually evaluated*. Metric names encode
this: `ollama_prompt_tokens_submitted_total` (logical, includes cache hits and
embedding tasks) vs `ollama_prompt_evaluated_tokens_total` (real prefill
compute). Efficiency metrics use the *evaluated* number — cached tokens are
not counted as computation.

### Live metrics (gauges, per slot; `slot` is the finite llama.cpp slot id)

| metric                                        | source                                   |
|-----------------------------------------------|------------------------------------------|
| `ollama_slot_active{slot}`                    | 1 on `processing task`, 0 on `release`   |
| `ollama_slot_phase_prefill{slot}` / `..._decode{slot}` | phase gauges (0/1)               |
| `ollama_slots_idle`                           | 0/1 safety net from "all slots are idle" |
| `ollama_live_prompt_total_tokens{slot}`       | `task.n_tokens` (submitted size)         |
| `ollama_live_prompt_processed_tokens{slot}`   | `n_tokens` so far in prefill             |
| `ollama_live_prompt_progress_ratio{slot}`     | prefill `progress`                       |
| `ollama_live_prompt_tokens_per_second{slot}`  | prefill t/s                              |
| `ollama_live_prompt_elapsed_seconds{slot}`    | prefill elapsed `t`                      |
| `ollama_live_generated_tokens{slot}`          | `n_gen` (legacy `n_decoded` also parsed) |
| `ollama_live_decode_tokens_per_second{slot}`  | `tg` — request-average decode so far     |
| `ollama_live_decode_tokens_per_second_3s{slot}` | `tg_3s` — engine's trailing 3s decode  |

`tg_3s` is the authoritative live generation speed; `tg` is the request
average so far. Do **not** derive decode speed from
`rate(ollama_generated_tokens_total[...])` — that measures completion booking.

### Completed metrics (counters/histograms)

| metric                                          | meaning                                   |
|-------------------------------------------------|-------------------------------------------|
| `ollama_prompt_tokens_submitted_total`          | logical submitted prompt tokens           |
| `ollama_prompt_evaluated_tokens_total`          | prompt tokens actually evaluated          |
| `ollama_prompt_eval_seconds_total`              | time spent evaluating prompts             |
| `ollama_prompt_eval_tokens_per_second`          | per-request prefill t/s (histogram)       |
| `ollama_generated_tokens_total`                 | generated tokens (incl. reasoning tokens) |
| `ollama_decode_seconds_total`                   | decode time                               |
| `ollama_decode_tokens_per_second`               | per-request average decode t/s (histogram)|
| `ollama_compute_seconds_total`                  | llama.cpp "total time"                    |
| `ollama_compute_tokens_total`                   | evaluated + generated tokens              |
| `ollama_http_requests_total{method,path,status}`| passive count from Ollama's GIN log lines |
| `ollama_http_request_duration_seconds`          | request duration (histogram)              |

Completed counters only include requests the engine has *finished*; a range
that cuts through an in-flight request does not include it yet.

### Prompt-cache metrics

| metric                                        | source                              |
|-----------------------------------------------|-------------------------------------|
| `ollama_prompt_cache_entries`                 | `cache state: N prompts, ...`       |
| `ollama_prompt_cache_bytes`                   | `cache state: ..., X MiB`           |
| `ollama_prompt_cache_update_duration_seconds` | `prompt cache update took ... ms`   |
| `ollama_prompt_cache_full_reprocess_total`    | `forcing full prompt re-processing` |
| `ollama_prompt_cache_evictions_total`         | `removing oldest entry`             |

Speculative decoding: current Ollama/llama.cpp logs on this setup emit no
draft-acceptance lines, so no such metrics exist. If a future version adds
them, extend the parser deliberately (a new explicit variant), not permissively.

### Model labels

llama.cpp task lines do not carry a trustworthy model identity (only the
llama-server launch command does, with a blob hash). With
`OLLAMA_MAX_LOADED_MODELS=1`, slot-level metrics without a model label are
unambiguous in practice. Attaching a model name would require re-introducing
HTTP polling of Ollama; that trade-off was rejected on purpose.

## Collector self-observability

* `ollama_journal_lines_seen_total` — every ollama.service journal line seen.
* `ollama_journal_events_matched_total{event=...}` — parsed telemetry per
  category (lifecycle, timings, cache, http).
* `ollama_journal_last_event_timestamp_seconds` — last relevant event.

Unmatched rate ≈ `rate(lines_seen) - sum(rate(events_matched))`. A large
unmatched share after an Ollama upgrade usually means the llama.cpp log
format changed — the Grafana "Collector health" row visualizes this.

## The llama.cpp log format is not a stable API

The parser targets the exact line shapes Ollama 0.33.1 emits (verified). A
future Ollama/llama.cpp can reword them, in which case live/completed metrics
go quiet while `lines_seen_total` keeps rising — that asymmetry is the
upgrade alarm. **After every major Ollama upgrade, run `./bin/test` and check
the collector health panels.** The parser intentionally uses explicit variants
(e.g. `n_gen` and legacy `n_decoded`) rather than one overly permissive regex,
and drops lines it cannot fully parse instead of emitting nonsense values.

## Usage

```bash
./bin/up        # start monitoring (config sanity checks included)
./bin/status    # health overview: containers, Ollama, collector, targets
./bin/down      # stop monitoring (keeps ./data)
./bin/test      # unit + static tests (no stack required)
./bin/test --live --security --restart   # full validation vs running stack
```

`.env` only holds Grafana credentials. Grafana: <http://localhost:3000>,
Prometheus: <http://localhost:9090>, collector: <http://localhost:9598/metrics>.

## Privacy

The collector parses only the operational/timing lines listed above. Prompt
text, responses, tool arguments, and raw logs are never exported or persisted;
no metric label carries user content (verified by `tests/test_security.sh`,
which sends a unique marker through Ollama and asserts it never appears in
`/metrics`). No Loki, no OpenTelemetry, no additional database.

## Security notes

Monitoring containers run localhost-only. Prometheus and Grafana run as root
inside their containers because `./data` bind mounts are owned by the WSL user
(no passwordless sudo to chown for the default uids) — acceptable for a
personal, loopback-bound stack. The collector runs as uid 1000 with only the
`systemd-journal` supplementary group; all host mounts are read-only.

## Data persistence

Prometheus (90d retention) and Grafana state live in `./data/` and survive
container recreation. The Vector journald cursor lives in `./data/vector/`.
