# Metrics Reference

The collector deliberately keeps three kinds of measurements separate:

1. Live engine telemetry from llama.cpp status lines. These gauges describe the
   current slot and are zeroed on release.
2. Completed compute work from final per-request timing lines. These counters
   count work the engine actually completed.
3. Logical submitted prompt size from `task.n_tokens`. This includes tokens
   that the prompt cache may serve without re-evaluation.

## Live Metrics

| Metric | Meaning |
| --- | --- |
| `ollama_slot_active{slot}` | Slot is processing a task. |
| `ollama_slot_phase_prefill{slot}` | Prompt processing phase is active. |
| `ollama_slot_phase_decode{slot}` | Token generation phase is active. |
| `ollama_slots_idle` | Whole-server idle safety signal. |
| `ollama_live_prompt_total_tokens{slot}` | Logical submitted prompt size. |
| `ollama_live_prompt_processed_tokens{slot}` | Prompt tokens processed so far. |
| `ollama_live_prompt_progress_ratio{slot}` | llama.cpp prompt progress. |
| `ollama_live_prompt_tokens_per_second{slot}` | Current prefill speed. |
| `ollama_live_prompt_elapsed_seconds{slot}` | Current prefill elapsed time. |
| `ollama_live_generated_tokens{slot}` | Generated tokens so far. |
| `ollama_live_decode_tokens_per_second{slot}` | `tg`, request-average decode speed. |
| `ollama_live_decode_tokens_per_second_3s{slot}` | `tg_3s`, llama.cpp's trailing three-second decode speed. |

`tg_3s` is the authoritative live decode value. Do not derive live decode
speed from a rate over `ollama_generated_tokens_total`; that counter is updated
only when a request finishes.

## Completed Metrics

| Metric | Meaning |
| --- | --- |
| `ollama_prompt_tokens_submitted_total` | Logical prompt tokens submitted, including cache hits. |
| `ollama_prompt_evaluated_tokens_total` | Prompt tokens actually evaluated by the engine. |
| `ollama_prompt_eval_seconds_total` | Completed prompt evaluation time. |
| `ollama_prompt_eval_tokens_per_second` | Per-request completed prefill histogram. |
| `ollama_generated_tokens_total` | Completed generated tokens, including reasoning tokens. |
| `ollama_decode_seconds_total` | Completed decode time. |
| `ollama_decode_tokens_per_second` | Per-request completed decode-speed histogram. |
| `ollama_compute_seconds_total` | Completed llama.cpp total time. |
| `ollama_compute_tokens_total` | Evaluated prompt tokens plus generated tokens. |
| `ollama_http_requests_total{method,path,status}` | Passive count from Ollama GIN access lines; `path` is a normalized endpoint label. |
| `ollama_http_request_duration_seconds` | Passive GIN request-duration histogram. |

Completed counters do not include a request until its final timing lines are
written. The prompt distinction is intentional: a warm request can submit a
large logical context while the engine evaluates only the uncached suffix.

## Prompt Cache

| Metric | Source |
| --- | --- |
| `ollama_prompt_cache_entries` | `cache state` line. |
| `ollama_prompt_cache_bytes` | `cache state` line, converted from MiB. |
| `ollama_prompt_cache_update_duration_seconds` | Prompt-cache update latency. |
| `ollama_prompt_cache_full_reprocess_total` | Forced full prompt reprocessing events. |
| `ollama_prompt_cache_evictions_total` | Oldest-entry eviction events. |

## HTTP Label Bounds

The collector never exports the raw GIN path. Known routes retain their fixed
path, including `/v1/chat/completions`, `/api/chat`, `/api/generate`,
`/api/embed`, `/api/embeddings`, `/api/ps`, `/api/tags`, `/api/show`,
`/api/pull`, `/api/push`, `/api/create`, `/api/delete`, `/api/copy`, and
`/api/version`. The OpenAI-compatible `/v1/models` and `/v1/embeddings` routes
are also recognized on the verified server.

The dynamic `/api/blobs/<value>` route becomes `/api/blobs/:digest`; every
other route becomes `other`. Methods are limited to `GET`, `POST`, `PUT`,
`PATCH`, `DELETE`, `HEAD`, `OPTIONS`, and `OTHER`. Status remains a three-digit
status label. This keeps request-path metrics useful without allowing arbitrary
caller strings or unbounded path cardinality.

## Collector Health

* `ollama_journal_lines_seen_total` counts every line received from
  `ollama.service`.
* `ollama_journal_events_matched_total{event}` counts explicit parser event
  categories such as `slot_launch`, `prompt_processing`, `live_decode`,
  `final_eval`, `final_total`, and `gin`.
* `ollama_journal_last_event_timestamp_seconds` records the last relevant
  event timestamp.

A large unmatched share after an Ollama upgrade is an upgrade alarm. The
  parser uses explicit variants and drops lines it cannot fully parse rather
  than emitting guessed values.

## Model Labels and GPU

The task timing lines do not contain a trustworthy model name. When more than
one model runner is loaded, the journal-derived metrics may be aggregated.
`./bin/doctor` and `./bin/status` warn when `/api/ps` reports multiple loaded
models. The project does not poll Ollama from the metric source to manufacture
model labels.

NVIDIA metrics are supplied by the optional `nvidia-gpu-exporter` service. Core
journal metrics remain useful without it; GPU-only dashboard panels simply have
no samples when the profile is disabled.
