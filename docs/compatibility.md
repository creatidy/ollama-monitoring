# Compatibility

`ollama-monitoring` reads the non-public llama.cpp/Ollama log format emitted in
the native `ollama.service` journal. A parser match is not an Ollama API
guarantee. When the format changes, the collector's `lines_seen` counter can
continue while parsed event counters go quiet.

## Current Matrix

| Environment or feature | Status | Evidence or limitation |
| --- | --- | --- |
| WSL2 with Ubuntu and systemd | Verified | Tested locally with native Ollama 0.33.1 and Docker Desktop. |
| Ollama 0.33.1 | Verified | Fixtures and live tests cover the current llama.cpp timing shapes. |
| Standard Linux with systemd | Expected, not locally verified here | The collector uses normal journald files and numeric group permissions; add host evidence before claiming a specific distro. |
| Native Windows or macOS Ollama | Not supported by this collector | The collector depends on the native Linux systemd journal. |
| Ollama in Docker | Not primary supported mode | This project expects native Ollama on `:11434` and a host `ollama.service`. |
| NVIDIA telemetry | Optional | The `nvidia` Compose profile is enabled automatically when host and Docker GPU checks succeed. |
| AMD telemetry | Not supported | No AMD exporter is included in this project. |
| Multiple loaded model runners | Limited | Journal timing lines do not carry a trustworthy model name; metrics may be aggregated. |

The standard Linux row describes the intended architecture, not a claim that
every distribution has been tested. Contributions should add exact distro,
kernel, systemd, Docker, and Ollama evidence.

## Checking a New Ollama Version

1. Run `./bin/doctor` and record the Ollama version and journal source.
2. Run `./bin/test` for Vector validation and parser fixtures.
3. Run `./bin/test --live` against a running native Ollama instance.
4. Check `ollama_journal_lines_seen_total` and
   `ollama_journal_events_matched_total{event=...}` in the collector.
5. Add sanitized timing lines as fixtures and extend `tests/gen_tests.py` when
   the format is a deliberate compatible variant.

Future passive model attribution is a roadmap item only. It should be added
when Ollama exposes a reliable identity in the same journal event stream; do
not infer labels by polling or guessing from request order.
