# ollama-monitoring

[![CI](https://github.com/creatidy/ollama-monitoring/actions/workflows/ci.yml/badge.svg)](https://github.com/creatidy/ollama-monitoring/actions/workflows/ci.yml)

> **See what Ollama's inference engine is actually doing, live, without putting anything in the request path.**

Passive Ollama observability with real llama.cpp performance telemetry. No
proxy and no client reconfiguration: native Ollama stays on `:11434`, while a
small Vector collector reads its `ollama.service` journal.

## Why This Is Different

The stack exposes measurements that an HTTP proxy or API usage counter cannot
provide by itself:

* live prefill tokens/s;
* live llama.cpp decode `tg` and `tg_3s`;
* submitted prompt tokens versus tokens actually evaluated;
* prompt-cache behavior and update cost;
* GPU power, VRAM, utilization, and temperature when NVIDIA is available;
* Prometheus history and a Grafana dashboard;
* no interception of Ollama traffic.

## Quick Start

Requirements: Linux with systemd and journald, Docker Compose, and native
Ollama on `:11434`. WSL2 Ubuntu with systemd is verified. NVIDIA is optional.

```bash
git clone https://github.com/creatidy/ollama-monitoring.git
cd ollama-monitoring
./bin/doctor
./bin/up
```

Open Grafana at <http://localhost:3000>. The generated Grafana credentials are
stored in the ignored `.env`; `./bin/up` creates a random password only when
`.env` does not already exist. Prometheus is at <http://localhost:9090> and
collector metrics are at <http://localhost:9598/metrics>.

`./bin/up` detects the host UID/GID, the journal directory, and NVIDIA Docker
access. Override unusual environments with `COLLECTOR_UID`, `COLLECTOR_GID`,
`JOURNAL_GID`, `JOURNAL_DIR`, or `OLLAMA_MONITORING_GPU=auto|nvidia|none`.

## Architecture

```text
Ollama clients
(Kilo, Open WebUI, curl, SDKs, ...)
        |
        v
native Ollama :11434
        |
    journald
        |
        v
Vector collector ---> Prometheus ---> Grafana
                         ^
                         |
              NVIDIA exporter (optional)
```

The monitoring stack is outside the inference path. It does not proxy, poll,
rewrite, or reconfigure Ollama requests. NVIDIA support is an optional Compose
profile; the core journal panels work without it.

## Commands

```bash
./bin/doctor             # preflight: can this host run the stack?
./bin/up                 # detect, configure, and start the stack
./bin/status             # running-stack health and model-attribution warning
./bin/down               # stop containers and keep ./data
./bin/test               # offline parser, static, privacy, and profile tests
./bin/test --live        # local native-Ollama request validation
./bin/test --security    # live privacy/isolation checks
./bin/test --restart     # live cursor/restart checks
./bin/test --observe-client # passive operator-driven client acceptance test
./bin/test --kilo        # same passive test with Kilo instructions
```

The external-client tests never send an inference request. They establish
metric baselines, tell the operator to start a task, and wait for a complete
observed lifecycle. See [Compatibility](docs/compatibility.md) for the
honest limitation that journal telemetry cannot prove client identity.
Set `OLLAMA_OBSERVE_TIMEOUT=900` before either observer command to use a longer
window.

## What Gets Measured

The collector keeps live engine state, completed compute work, and logical
submitted prompt size separate. In particular, warm-cache requests can submit
many prompt tokens while llama.cpp evaluates only a smaller uncached suffix.

Read the full metric names, token semantics, cache signals, and dashboard
queries in [docs/metrics.md](docs/metrics.md).

## Compatibility

The parser uses explicit branches for a non-public llama.cpp/Ollama log format.
It is currently verified with Ollama 0.33.1 on WSL2 Ubuntu. Standard systemd
Linux is architecturally expected but not falsely claimed as tested across all
distributions. Native Windows/macOS Ollama and Ollama-in-Docker are not the
primary supported modes. Multiple simultaneously loaded model runners are not
reliably attributed because timing lines do not carry a trustworthy model
name. See the [compatibility matrix](docs/compatibility.md).

## Privacy And Security

Only known operational, timing, cache, and GIN access-log shapes are parsed.
Prompt text, responses, tool arguments, raw journal messages, and user content
are not exported or persisted by the collector. Metric labels contain bounded
operational values such as slot, endpoint, method, and status. All published
ports bind to localhost, host journal and machine-id mounts are read-only, and
the collector has no Docker socket, host PID namespace, or privileged mode.

Run `./bin/test --security` against the local stack for the live marker and
container-isolation checks. Review [CONTRIBUTING.md](CONTRIBUTING.md) before
submitting journal evidence.

## Components

| Component | Role |
| --- | --- |
| Vector 0.49.0 | Reads `ollama.service` journald and parses llama.cpp telemetry. |
| Prometheus 3.14.0 | Scrapes and retains metrics for 90 days. |
| Grafana 13.0.8 | Local dashboard and exploration. |
| nvidia_gpu_exporter 1.15.0 | Optional NVIDIA power and device telemetry. |

## Persistence

Prometheus and Grafana data, plus the Vector journal cursor, live under
`./data/` and are ignored by Git. The cursor lets a collector restart resume
from its last journal position instead of replaying the boot into counters.
This is local observability, not billing-grade accounting.

## Contributing And License

Parser compatibility work is especially valuable as Ollama evolves. The
[contribution guide](CONTRIBUTING.md) explains how to sanitize journal shapes,
add fixtures, and report exact environment evidence. The project is licensed
under the [Apache License 2.0](LICENSE).

## Acknowledgements

The journal approach was motivated by public llama.cpp monitoring experiments;
no code is copied from those experiments. This project uses and acknowledges
Vector, Prometheus, Grafana, `nvidia_gpu_exporter`, Ollama, and llama.cpp.
