#!/usr/bin/env python3
"""Generate Vector unit tests (TOML) from sanitized journal fixtures.

Each fixture line is injected into the `parse` transform of
collector/vector.toml; expectations assert the classified event and the exact
extracted fields (including live timing values). Metric probes additionally
assert metric names and tags. (Metric payload values are not visible to Vector
test conditions; exact end-to-end values are validated live by
tests/test_integration.sh against the exporter.)

Single source of truth: the fixture files. Expectations reference lines by
(file, 1-based line number) so the tested string is always the fixture line.
"""

import pathlib
import re
import sys

FIXTURES = pathlib.Path(__file__).parent / "fixtures"

# (fixture, lineno, name, parse_assertions, [(transform, metric_name, tags...)])
# The last element lists metric probes: (transform, metric_name, {tag: value})
CASES = [
    # --- lifecycle ---------------------------------------------------------
    ("lifecycle.log", 1, "slot launch sets active",
     'assert_eq!(.event, "slot_launch")\nassert_eq!(.slot, "0")\nassert_eq!(.active, 1)',
     [("mt_slot_state", "ollama_slot_active", {("slot", "0")})]),
    ("lifecycle.log", 2, "new prompt carries logical prompt size",
     'assert_eq!(.event, "new_prompt")\nassert_eq!(.slot, "0")\nassert_eq!(.total_tokens, 34)',
     [("mt_new_prompt", "ollama_live_prompt_total_tokens", {("slot", "0")}),
      ("mt_new_prompt", "ollama_prompt_tokens_submitted_total", {})]),
    ("lifecycle.log", 3, "slot release zeroes state",
     'assert_eq!(.event, "slot_release")\nassert_eq!(.slot, "0")\nassert_eq!(.active, 0)\nassert_eq!(.phase_decode, 0)\n'
     'assert_eq!(.tg3, 0.0)\nassert_eq!(.tg, 0.0)\nassert_eq!(.generated, 0)\n'
     'assert_eq!(.progress, 0.0)\nassert_eq!(.processed, 0)\nassert_eq!(.total_tokens, 0)',
     [("mt_slot_state", "ollama_slot_active", {("slot", "0")})]),
    ("lifecycle.log", 4, "all slots idle event",
     'assert_eq!(.event, "slots_idle")',
     [("mt_slots_idle", "ollama_slots_idle", {})]),

    # --- prefill -----------------------------------------------------------
    ("prefill.log", 1, "big prompt size parsed",
     'assert_eq!(.event, "new_prompt")\nassert_eq!(.total_tokens, 66059)',
     []),
    ("prefill.log", 2, "prefill progress line exact values",
     'assert_eq!(.event, "prompt_processing")\nassert_eq!(.slot, "0")\n'
     'assert_eq!(.processed, 3328)\nassert_eq!(.progress, 0.05)\n'
     'assert_eq!(.elapsed, 3.10)\nassert_eq!(.tps, 1072.67)\n'
     'assert_eq!(.phase_prefill, 1)\nassert_eq!(.phase_decode, 0)\nassert_eq!(.active, 1)',
     [("mt_prompt_processing", "ollama_live_prompt_tokens_per_second", {("slot", "0")})]),
    ("prefill.log", 3, "prefill task-spec example exact values",
     'assert_eq!(.event, "prompt_processing")\nassert_eq!(.processed, 3840)\n'
     'assert_eq!(.progress, 0.19)\nassert_eq!(.elapsed, 3.72)\nassert_eq!(.tps, 1033.56)',
     []),

    # --- decode ------------------------------------------------------------
    ("decode.log", 1, "n_gen decode line parsed",
     'assert_eq!(.event, "live_decode")\nassert_eq!(.slot, "0")\n'
     'assert_eq!(.generated, 100)\nassert_eq!(.tg, 25.77)\nassert_eq!(.tg3, 26.03)',
     []),
    ("decode.log", 2, "task-spec decode example exact values",
     'assert_eq!(.event, "live_decode")\nassert_eq!(.generated, 1466)\n'
     'assert_eq!(.tg, 22.55)\nassert_eq!(.tg3, 22.31)\n'
     'assert_eq!(.phase_decode, 1)\nassert_eq!(.phase_prefill, 0)\nassert_eq!(.active, 1)',
     [("mt_live_decode", "ollama_live_decode_tokens_per_second_3s", {("slot", "0")}),
      ("mt_live_decode", "ollama_live_generated_tokens", {("slot", "0")})]),
    ("decode.log", 3, "legacy n_decoded variant supported",
     'assert_eq!(.event, "live_decode")\nassert_eq!(.slot, "0")\n'
     'assert_eq!(.generated, 512)\nassert_eq!(.tg, 24.10)\nassert_eq!(.tg3, 24.02)',
     []),

    # --- final timings -----------------------------------------------------
    ("final_timings.log", 1, "final prompt eval exact values",
     'assert_eq!(.event, "final_prompt_eval")\nassert_eq!(.slot, "0")\nassert_eq!(.tokens, 66059)\n'
     'assert_eq!(.tps, 813.55)\nassert_eq!(.sec, 81.1985)',
     [("mt_final_prompt_eval", "ollama_prompt_evaluated_tokens_total", {})]),
    ("final_timings.log", 2, "final eval exact values",
     'assert_eq!(.event, "final_eval")\nassert_eq!(.slot, "0")\nassert_eq!(.tokens, 2048)\n'
     'assert_eq!(.tps, 22.52)\nassert_eq!(.sec, 90.9135)',
     [("mt_final_eval", "ollama_decode_tokens_per_second", {})]),
    ("final_timings.log", 3, "total time exact values",
     'assert_eq!(.event, "final_total")\nassert_eq!(.slot, "0")\nassert_eq!(.tokens, 68107)\n'
     'assert_eq!(.sec, 172.112)',
     [("mt_final_total", "ollama_compute_tokens_total", {})]),
    ("final_timings.log", 4, "graphs reused is not a timing event",
     'assert_eq!(.event, "other")', []),

    # --- cache -------------------------------------------------------------
    ("cache.log", 1, "cache state zeroed",
     'assert_eq!(.event, "cache_state")\nassert_eq!(.entries, 0)\n'
     'assert_eq!(.bytes, 0.0)', []),
    ("cache.log", 2, "cache state parsed to entries and bytes",
     'assert_eq!(.event, "cache_state")\nassert_eq!(.entries, 3)\n'
     'assert_eq!(.bytes, 7669.352 * 1048576.0)',
     [("mt_cache_state", "ollama_prompt_cache_entries", {})]),
    ("cache.log", 3, "cache update fast",
     'assert_eq!(.event, "cache_update")\nassert_eq!(.sec, 0.00001)', []),
    ("cache.log", 4, "cache update slow exact value",
     'assert_eq!(.event, "cache_update")\nassert!(abs((to_float(.sec) ?? 0.0) - 4.23206) < 0.000001)',
     [("mt_cache_update", "ollama_prompt_cache_update_duration_seconds", {})]),
    ("cache.log", 5, "forced full reprocessing counted",
     'assert_eq!(.event, "cache_full_reprocess")',
     [("mt_cache_full_reprocess", "ollama_prompt_cache_full_reprocess_total", {})]),
    ("cache.log", 6, "cache eviction counted",
     'assert_eq!(.event, "cache_eviction")',
     [("mt_cache_eviction", "ollama_prompt_cache_evictions_total", {})]),

    # --- http --------------------------------------------------------------
    ("http_requests.log", 1, "gin embed request",
     'assert_eq!(.event, "gin")\nassert_eq!(.status, "200")\n'
     'assert_eq!(.method, "POST")\nassert_eq!(.path, "/api/embed")\n'
     'assert_eq!(.dur_s, 8.867819513)', []),
    ("http_requests.log", 2, "gin openai chat completions",
     'assert_eq!(.event, "gin")\nassert_eq!(.path, "/v1/chat/completions")\n'
      'assert_eq!(.method, "POST")\nassert_eq!(.status, "200")\n'
      'assert_eq!(.dur_s, 2.344185985)',
      [("mt_gin", "ollama_http_requests_total",
        {("method", "POST"), ("path", "/v1/chat/completions"), ("status", "200")})]),
    ("http_requests.log", 3, "gin microseconds duration",
     'assert_eq!(.event, "gin")\nassert_eq!(.path, "/api/tags")\n'
     'assert_eq!(.dur_s, 0.000457156)', []),
    ("http_requests.log", 4, "gin plain seconds duration",
     'assert_eq!(.event, "gin")\nassert_eq!(.path, "/api/ps")\n'
     'assert!(abs((to_float(.dur_s) ?? 0.0) - 0.000017546) < 0.000000000001)', []),
    ("http_requests.log", 5, "gin minutes duration",
     'assert_eq!(.event, "gin")\nassert_eq!(.path, "/api/chat")\n'
     'assert_eq!(.dur_s, 114.0)',
     [("mt_gin", "ollama_http_requests_total",
       {("method", "POST"), ("path", "/api/chat"), ("status", "200")})]),
    ("http_requests.log", 6, "gin milliseconds duration and status",
     'assert_eq!(.event, "gin")\nassert_eq!(.status, "500")\n'
      'assert_eq!(.dur_s, 0.045293)', []),
     ("http_requests.log", 7, "dynamic blob path is normalized",
      'assert_eq!(.event, "gin")\nassert_eq!(.status, "404")\n'
      'assert_eq!(.method, "GET")\nassert_eq!(.path, "/api/blobs/:digest")',
      [("mt_gin", "ollama_http_requests_total",
        {("method", "GET"), ("path", "/api/blobs/:digest"), ("status", "404")})]),
     ("http_requests.log", 8, "arbitrary path becomes other",
      'assert_eq!(.event, "gin")\nassert_eq!(.status, "404")\n'
      'assert_eq!(.method, "GET")\nassert_eq!(.path, "other")',
      [("mt_gin", "ollama_http_requests_total",
        {("method", "GET"), ("path", "other"), ("status", "404")})]),
     ("http_requests.log", 9, "unknown method becomes other",
      'assert_eq!(.event, "gin")\nassert_eq!(.method, "OTHER")\n'
      'assert_eq!(.path, "/api/version")',
      [("mt_gin", "ollama_http_requests_total",
        {("method", "OTHER"), ("path", "/api/version"), ("status", "405")})]),

    # --- unmatched ---------------------------------------------------------
    ("unmatched.log", 1, "ollama structured log unmatched",
     'assert_eq!(.event, "other")', []),
    ("unmatched.log", 4, "llama startup line unmatched",
     'assert_eq!(.event, "other")', []),
]


def toml_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> int:
    out = []
    probes = []  # test-only filter transforms isolating a single metric event
    probe_seq = 0
    for fixture, lineno, name, parse_assert, metric_checks in CASES:
        lines = (FIXTURES / fixture).read_text().splitlines()
        try:
            line = lines[lineno - 1]
        except IndexError:
            print(f"ERROR: {fixture}:{lineno} out of range", file=sys.stderr)
            return 1
        out.append("[[tests]]")
        out.append(f"name = {toml_str(f'{fixture}:{lineno} {name}')}")
        out.append("[[tests.inputs]]")
        out.append('insert_at = "parse"')
        out.append('type = "log"')
        out.append("[tests.inputs.log_fields]")
        out.append(f"message = {toml_str(line)}")
        out.append('timestamp = "2026-09-03T12:00:00Z"')
        out.append("[[tests.outputs]]")
        out.append('extract_from = "parse"')
        out.append("[[tests.outputs.conditions]]")
        out.append('type = "vrl"')
        out.append(f"source = '''\n{parse_assert}\n'''")
        # log_to_metric transforms emit one event per metric; Vector unit-test
        # conditions must match ALL events of the extracted transform, so each
        # probe isolates exactly one metric by name and asserts its tags.
        for transform, metric, tags in metric_checks:
            pid = f"test_probe_{probe_seq}"
            probe_seq += 1
            tag_conds = "".join(
                f'\nassert_eq!(.tags.{t}, "{v}")' for t, v in tags
            )
            probes.append(
                f'[transforms.{pid}]\ntype = "filter"\ninputs = ["{transform}"]\n'
                f'[transforms.{pid}.condition]\ntype = "vrl"\n'
                f"source = '.name == \"{metric}\"'\n"
            )
            out.append("[[tests.outputs]]")
            out.append(f'extract_from = "{pid}"')
            out.append("[[tests.outputs.conditions]]")
            out.append('type = "vrl"')
            out.append(
                f"source = '''\nassert_eq!(.name, \"{metric}\"){tag_conds}\n'''"
            )
        out.append("")

    target = pathlib.Path(__file__).parent / "generated_tests.toml"
    target.write_text("\n".join(probes) + "\n" + "\n".join(out))
    print(f"wrote {len(CASES)} tests and {probe_seq} probes -> {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
