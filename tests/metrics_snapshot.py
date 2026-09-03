#!/usr/bin/env python3
"""Reduce Prometheus text exposition to fields used by the passive observer."""

import json
import re
import sys
from collections import defaultdict


METRIC_LINE = re.compile(
    r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{([^}]*)\})?\s+([-+0-9.eE]+)(?:\s+\S+)?$"
)
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"')
EVENTS = (
    "slot_launch",
    "slot_release",
    "slots_idle",
    "new_prompt",
    "prompt_processing",
    "live_decode",
    "final_prompt_eval",
    "final_eval",
    "final_total",
    "cache_state",
    "cache_update",
    "cache_full_reprocess",
    "cache_eviction",
    "gin",
)


def labels(raw: str | None) -> dict[str, str]:
    if not raw:
        return {}
    result = {}
    for match in LABEL.finditer(raw):
        try:
            result[match.group(1)] = json.loads('"' + match.group(2) + '"')
        except json.JSONDecodeError:
            continue
    return result


def main() -> int:
    values: dict[str, list[tuple[dict[str, str], float]]] = defaultdict(list)
    for line in sys.stdin:
        match = METRIC_LINE.match(line.strip())
        if not match:
            continue
        try:
            value = float(match.group(3))
        except ValueError:
            continue
        values[match.group(1)].append((labels(match.group(2)), value))

    def total(name: str, wanted: dict[str, str] | None = None) -> float:
        return sum(
            value
            for item_labels, value in values.get(name, [])
            if wanted is None or all(item_labels.get(k) == v for k, v in wanted.items())
        )

    def maximum(name: str) -> float:
        samples = [value for _, value in values.get(name, [])]
        return max(samples, default=0.0)

    def emit(kind: str, key: str, value: object) -> None:
        print(f"{kind}\t{key}\t{value}")

    for event in EVENTS:
        emit("event", event, total("ollama_journal_events_matched_total", {"event": event}))

    metric_names = {
        "eval_tokens": "ollama_prompt_evaluated_tokens_total",
        "generated_tokens": "ollama_generated_tokens_total",
        "compute_tokens": "ollama_compute_tokens_total",
        "compute_seconds": "ollama_compute_seconds_total",
        "prompt_submitted": "ollama_prompt_tokens_submitted_total",
        "decode_sum": "ollama_decode_tokens_per_second_sum",
        "decode_count": "ollama_decode_tokens_per_second_count",
    }
    for key, name in metric_names.items():
        emit("metric", key, total(name))

    gauges = {
        "active": ("ollama_slot_active", "sum"),
        "prefill": ("ollama_slot_phase_prefill", "sum"),
        "decode": ("ollama_slot_phase_decode", "sum"),
        "live_tg": ("ollama_live_decode_tokens_per_second", "max"),
        "live_tg3": ("ollama_live_decode_tokens_per_second_3s", "max"),
    }
    for key, (name, operation) in gauges.items():
        emit("gauge", key, total(name) if operation == "sum" else maximum(name))

    # The collector's path label is already normalized to a finite endpoint
    # classification; never reconstruct or print a raw request path here.
    http_values = values.get("ollama_http_requests_total", [])
    emit("meta", "http_series", len(http_values))
    emit("metric", "http_total", sum(value for _, value in http_values))
    for item_labels, value in http_values:
        if "path" in item_labels:
            emit("http", item_labels["path"], value)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
