# Ollama Monitoring

Durable local monitoring for native-WSL Ollama + RTX 3090, via Docker Compose:
Prometheus metrics from a transparent Ollama API proxy, NVIDIA GPU telemetry,
and an auto-provisioned Grafana dashboard.

## Quick start

```bash
cd ~/workspace/ollama-monitoring
./bin/up        # start everything (also fixes the WSL IP if it changed)
```

Open **http://localhost:3000** — the Ollama dashboard is the Grafana home page.
Login: see `.env` (defaults: `admin` / `ollama`).

## Commands

| Command | Purpose |
|---|---|
| `./bin/up` | Start / heal the stack. Resolves the current WSL IP into `.env` and recreates containers whose config changed. Safe to re-run anytime. |
| `./bin/status` | Health overview: containers, WSL IP match, all four endpoints, Prometheus scrape targets. |
| `./bin/test` | Full end-to-end validation (including real OpenAI-compatible streaming/non-streaming traffic, native regression, dashboards, GPU, and persistence). `--skip-persistence` for a quicker run. |
| `./bin/down` | Stop. Keeps all data. Never uses `down -v`. |

## URLs / ports

| URL | Service | Exposure |
|---|---|---|
| `http://localhost:11434` | **Ollama API via metrics proxy** — use this as your normal Ollama endpoint | Windows + LAN (see below) |
| `http://localhost:3000` | Grafana | localhost only |
| `http://localhost:9090` | Prometheus UI | localhost only |
| `http://127.0.0.1:11435` | Native Ollama (bypasses metering) | WSL/Windows localhost only, not LAN |

**Point all clients at `:11434`.** Only traffic through the proxy is metered;
requests sent directly to `:11435` are invisible to token accounting.

## Architecture

```
clients / trusted LAN
        |
        v
:11434  ollama-proxy (local build of NorskHelsenett/ollama-metrics)
        |      in-memory Prometheus counters + transparent API forwarding
        v
:11435  native Ollama 0.33.1 (systemd service in WSL, NOT containerized)

Prometheus (v3.14.0) scrapes:
  - ollama-proxy:8080/metrics   every 5s  (job "ollama")
  - nvidia-gpu-exporter:9835    every 10s (job "nvidia-gpu")
  - itself                      every 15s

Grafana 13.0.8 -> Prometheus, datasource + dashboard auto-provisioned from
./grafana/. GPU metrics via utkuozdemir/nvidia_gpu_exporter:1.15.0 running
with `gpus: all` (nvidia-smi is injected by WSL2 GPU passthrough; DCGM does
not work on WSL2, which is why this exporter is used).
```

## Persistent data

All durable state lives in **`./data/`** (bind mounts, survives container
recreation, Docker Desktop restarts, WSL restarts):

- `./data/prometheus/` — Prometheus TSDB (90-day retention)
- `./data/grafana/`   — Grafana DB, users, plugins

Both are excluded from Git via `.gitignore`.

## Dynamic WSL addressing

The Ollama backend listens on the WSL distro's NAT address (e.g.
`172.22.x.x`), which changes on Windows/WSL restarts. `host.docker.internal`
does **not** reach it (it points at the Docker Desktop VM/Windows side).

Solution: `bin/up` reads the current WSL IP (`ip route get 1.1.1.1`) and writes
it to `.env` as `WSL_HOST_IP`; `compose.yaml` passes it to the proxy as
`OLLAMA_HOST`. When the IP changes, re-running `./bin/up` rewrites `.env` and
Compose automatically recreates only the proxy container. No IP is ever baked
into tracked config (`bin/test` checks this).

## Token accounting — exact semantics

The proxy exposes `ollama_prompt_tokens_total` / `ollama_generated_tokens_total`
as **in-memory cumulative counters**. Prometheus handles counter resets, and
the design keeps residual error small and bounded:

- **Planned restarts** (`bin/up`, `bin/down` + `bin/up`, boot-time start):
  effectively **exact**. No traffic flows while the proxy starts, so the first
  scrape observes the fresh counter and Prometheus records the reset. Verified:
  `increase()` matched the true request counts exactly.
- **Restart + request completing within one 5 s scrape window** (the only
  masking case): if the post-restart counter value is >= the last pre-restart
  scrape, Prometheus cannot see that a reset happened and `increase()`
  undercounts by the pre-restart total. Verified by deliberately racing the
  scrape (lost 23 of 60 prompt tokens in a test). This matters only shortly
  after a fresh proxy start, when cumulative values are still small; after a
  long uptime the cumulative total exceeds any single request, so resets are
  always detected.
- **Requests in flight during a crash**: lost (at most ~5 s of traffic).
  Inherent to any scrape-based design.

The 5 s scrape interval on the `ollama` job keeps all these windows small.
There is no billing-grade exactness here; daily/weekly/monthly answers from
`increase(metric[24h])` etc. are reliable for personal use.

### OpenAI-compatible chat completions

The local proxy build also parses Ollama's OpenAI-compatible usage shape from
`/v1/chat/completions`:

- Non-streaming responses use `usage.prompt_tokens` and
  `usage.completion_tokens`.
- Streaming requests are forwarded as SSE immediately and the final usage
  event is parsed.
- For a streaming request that does not already set
  `stream_options.include_usage=true`, the proxy adds that option only on the
  upstream request. Ollama `0.33.1` then reports exact counts in its final
  usage-only SSE event.
- The proxy consumes that added usage-only event before forwarding the
  response, so clients that did not request usage receive the same normal
  chunks and `data: [DONE]` as before. If the client already requested usage,
  the event passes through unchanged.

The custom image source is under `./proxy/`. It is based on upstream
`NorskHelsenett/ollama-metrics` revision
`02911ce53b5b14cff172163cd5858854dd0148e3`, the source revision recorded by
the former pinned image
(`sha256:3dd32882666cf0e77272086446b5639c636fb090ac9ea629c11874200c629164`).
The upstream OpenAI usage changes are still unmerged, so the endpoint parser
and streaming handling are maintained as a narrow local patch. `bin/up` builds
this image through Compose; no manually built image is required.

## GPU metrics

`nvidia_smi_*` series (utilization ratio, memory used/total bytes, power watts,
temperature, fan) collected from `nvidia-smi -q` inside a `--gpus all`
container. Verified to react to real inference load (utilization to ~92 %,
power to ~300 W). `Model VRAM` on the dashboard is Ollama's `size_vram` from
`/api/ps` (exported as `ollama_model_ram_mb`).

Energy estimates: "GPU energy over range" = avg power x duration (includes
idle time); "tokens per kWh" panels divide token counts by that energy. These
are rough, clearly-labeled estimates — not billing data.

## Survivability

- All services have `restart: unless-stopped` → containers come back with the
  Docker engine (after `docker compose restart`, Docker Desktop restart, WSL
  restart — as long as Docker Desktop starts, which it does by default at
  Windows login).
- After a full Windows restart: start Docker Desktop (automatic), then run
  `./bin/up` once so the proxy picks up the new WSL IP.
- Ollama itself is a systemd service in WSL (`ollama.service`, enabled) and is
  not managed by this stack.

## Security notes

- 11434 is published on all interfaces: Docker Desktop binds it on the Windows
  host, and Docker Desktop's built-in firewall rules allow `com.docker.backend`
  on **Private** networks only (blocked on Public). Your LAN must be marked
  Private in Windows. To restrict further, run elevated PowerShell:
  `New-NetFirewallRule -DisplayName "Ollama proxy 11434" -Direction Inbound -Protocol TCP -LocalPort 11434 -RemoteAddress LocalSubnet -Action Allow`
  (plus disabling the broad Docker Desktop allow rule, if you want).
- 11435 (native Ollama) is bound inside WSL only; Windows NAT does not forward
  it to the LAN.
- Grafana/Prometheus bind `127.0.0.1` on the WSL + Windows side.
- The proxy and GPU-exporter images are distroless (no shell), so they cannot
  have in-container healthchecks; the two data services do (Prometheus uses
  `/-/ready`, which also gates Grafana startup).
- Prometheus and Grafana run as root inside their containers because the
  `./data` bind mounts are owned by the WSL user and there is no passwordless
  sudo to chown them to the images' UIDs. Acceptable for a localhost-bound
  personal stack.

## Upgrading images

Prometheus, Grafana, and the NVIDIA exporter remain pinned
(`prom/prometheus:v3.14.0`, `grafana/grafana:13.0.8`,
`nvidia_gpu_exporter:1.15.0`). The Ollama proxy is built locally from
`./proxy/` so its parser fix is reproducible. To upgrade:

1. `./bin/down`
2. Update the proxy source/Dockerfile under `proxy/` when intentionally
   rebasing the local patch onto a newer upstream revision.
3. `./bin/up && ./bin/test`

Data survives upgrades (it lives in `./data/`). If a new Grafana major version
migrates the DB, it cannot be trivially rolled back — back up first (below).

## Backups

```bash
cd ~/workspace/ollama-monitoring
./bin/down   # or leave running for a slightly less consistent copy
tar czf ollama-monitoring-data-$(date +%F).tar.gz data/
```

Restore: extract over `data/`, then `./bin/up`. Grafana state (users,
dashboards edited in the UI) and all Prometheus history are inside `data/`;
provisioned config lives in `grafana/` and `prometheus/` (in Git).

## Complete removal

`./bin/down` stops everything (containers removed; the proxy no longer holds
port 11434). To wipe monitoring **data** too: `rm -rf data/` — this deletes all
Prometheus history and Grafana state permanently. Uninstall = delete the
project directory; nothing else is installed system-wide.

Legacy leftover from earlier experiments (safe to delete, not used here):
`sudo rm -rf /var/lib/ollama-monitoring/`.
