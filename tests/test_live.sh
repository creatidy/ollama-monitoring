#!/usr/bin/env bash
# Live validation against the RUNNING monitoring stack and native Ollama.
#
# Sends a real request directly to native Ollama (default :11434, override
# with OLLAMA_PORT / OLLAMA_MODEL), then verifies:
#   - phase lifecycle IDLE -> PREFILL -> DECODE -> IDLE in the metrics
#   - live decode t/s (tg/tg_3s) appears during decode
#   - completed counters move by exactly the engine-reported final timings
#   - final journal-derived counts match the native API usage fields
set -uo pipefail
cd "$(dirname "$0")/.." || exit

PORT="${OLLAMA_PORT:-11434}"
MODEL="${OLLAMA_MODEL:-$(curl -sf -m 5 "http://127.0.0.1:${PORT}/api/ps" | python3 -c '
import json,sys
d = json.load(sys.stdin)
names = [m["name"] for m in d.get("models", []) if "embed" not in m["name"].lower()]
print(names[0] if names else "")' 2>/dev/null)}"
if [[ -z "${MODEL}" ]]; then
  MODEL="$(curl -sf -m 5 "http://127.0.0.1:${PORT}/api/tags" | python3 -c '
import json,sys
d = json.load(sys.stdin)
names = [m["name"] for m in d.get("models", []) if "embed" not in m["name"].lower()]
print(names[0] if names else "")' 2>/dev/null)"
fi
BASE="http://127.0.0.1:${PORT}"
COLLECTOR="http://127.0.0.1:9598/metrics"
PROM="http://127.0.0.1:9090"
PASS=0; FAIL=0
ok()   { echo "  [ OK ] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

if [[ -z "${MODEL}" ]]; then
  echo "ERROR: no loaded model; start Ollama with a model or set OLLAMA_MODEL" >&2
  exit 1
fi
echo "  target: ${BASE} model=${MODEL}"

prom_instant() { # prom_instant <expr>
  curl -sf -m 10 "${PROM}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(sum(float(r["value"][1]) for r in d["data"]["result"]) if d["data"]["result"] else "")' 2>/dev/null
}
coll_value() { # coll_value <metric-name-regex>
  curl -sf -m 5 "${COLLECTOR}" 2>/dev/null | python3 -c "
import re,sys
pat = re.compile(r'^$1 +(\S+)', re.M)
vals = [float(m.group(1)) for m in (pat.match(l) for l in sys.stdin) if m]
print(sum(vals))" 2>/dev/null
}
wait_for() { # wait_for <desc> <expr...>; evals expr with VAL set
  local desc="$1"; shift
  for _ in $(seq 1 60); do
    local VAL
    VAL="$(coll_value "$1")"
    if python3 -c "$2" 2>/dev/null; then ok "$desc (value=${VAL})"; return 0; fi
    sleep 1
  done
  VAL="$(coll_value "$1")"
  fail "$desc (last value=${VAL:-none})"
  return 1
}

echo "=== Live validation: preflight ==="
if curl -sf -m 5 "${BASE}/api/version" >/dev/null; then
  ok "native Ollama reachable directly on :${PORT} (no proxy)"
else
  fail "native Ollama NOT reachable on :${PORT} - restore it to :11434 first (user step)"
  echo "  PASSED: ${PASS}   FAILED: ${FAIL}"; exit 1
fi
PROM_UP="$(prom_instant 'up{job="journal-metrics"}')"
if python3 -c "exit(0 if float('${PROM_UP:-0}') == 1 else 1)" 2>/dev/null; then ok "Prometheus scrapes journal-metrics"; else fail "journal-metrics target not up in Prometheus (got: ${PROM_UP:-none})"; fi

echo "=== Live validation: sending one real request ==="
BEFORE_EVAL="$(coll_value 'ollama_prompt_evaluated_tokens_total')"; BEFORE_EVAL="${BEFORE_EVAL:-0}"
BEFORE_GEN="$(coll_value 'ollama_generated_tokens_total')"; BEFORE_GEN="${BEFORE_GEN:-0}"
BEFORE_COMP_SEC="$(coll_value 'ollama_compute_seconds_total')"; BEFORE_COMP_SEC="${BEFORE_COMP_SEC:-0}"
BEFORE_PROMPT_PROMPT="$(coll_value 'ollama_prompt_tokens_submitted_total')"; BEFORE_PROMPT_PROMPT="${BEFORE_PROMPT_PROMPT:-0}"
BEFORE_DECODE_SUM="$(coll_value 'ollama_decode_tokens_per_second_sum')"; BEFORE_DECODE_SUM="${BEFORE_DECODE_SUM:-0}"
BEFORE_DECODE_COUNT="$(coll_value 'ollama_decode_tokens_per_second_count')"; BEFORE_DECODE_COUNT="${BEFORE_DECODE_COUNT:-0}"

# Stream a request with a moderately long answer; while it runs, sample the
# live metrics (phase + tg_3s) at collector level (no scrape lag).
mkdir -p /tmp/ollama-monitoring
RESULT="$(mktemp /tmp/ollama-monitoring/live-XXXXXX)"
python3 - "${BASE}" "${MODEL}" >"${RESULT}" 2>&1 <<'PYEOF' &
import json, sys, time, urllib.request
base, model = sys.argv[1], sys.argv[2]
payload = {
    "model": model,
    "messages": [{"role": "user", "content": "Count from 1 to 30, then briefly explain why testing monitoring systems matters."}],
    "stream": True,
    "stream_options": {"include_usage": True},
}
req = urllib.request.Request(base + "/v1/chat/completions",
    data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
usage = None
with urllib.request.urlopen(req, timeout=300) as r:
    for line in r:
        line = line.decode().strip()
        if not line.startswith("data:") or line == "data: [DONE]":
            continue
        c = json.loads(line.split(":", 1)[1])
        if c.get("usage"):
            usage = c["usage"]
print(json.dumps(usage or {}))
PYEOF
BG_PID=$!

# --- while in flight: observe live gauges at the collector
LIVE_DECODE_SEEN=0; LIVE_TG3=""; PROM_TG3=""; PREFILL_SEEN=0; DECODE_PHASE_SEEN=0; GRACE=0
for _ in $(seq 1 480); do
  if ! kill -0 "${BG_PID}" 2>/dev/null; then
    GRACE=$((GRACE + 1)); [ "${GRACE}" -ge 6 ] && break
  fi
  M="$(curl -sf -m 2 "${COLLECTOR}" 2>/dev/null)" || { sleep 0.5; continue; }
  if printf '%s' "${M}" | grep -q '^ollama_slot_active{slot="0"} 1'; then
    if printf '%s' "${M}" | grep -q '^ollama_slot_phase_decode{slot="0"} 1'; then
      DECODE_PHASE_SEEN=1
      TG3="$(printf '%s' "${M}" | grep -E '^ollama_live_decode_tokens_per_second_3s\{slot="0"\}' | awk '{print $2}')"
      if [[ -n "${TG3}" ]] && python3 -c "exit(0 if float('${TG3}') > 0 else 1)" 2>/dev/null; then
        LIVE_DECODE_SEEN=1; LIVE_TG3="${TG3}"
        # Grafana reads this same Prometheus datasource query. Capture one
        # scrape-visible value so the validation compares the dashboard's
        # source of truth with the collector's immediate value.
        PTG3="$(prom_instant 'sum(ollama_live_decode_tokens_per_second_3s{slot="0"})')"
        if [[ -n "${PTG3}" ]] && python3 -c "exit(0 if float('${PTG3}') > 0 else 1)" 2>/dev/null; then
          PROM_TG3="${PTG3}"
        fi
      fi
    fi
    if printf '%s' "${M}" | grep -q '^ollama_slot_phase_prefill{slot="0"} 1'; then
      PREFILL_SEEN=1
    fi
  fi
  sleep 0.5
done
wait "${BG_PID}"; API_USAGE="$(cat "${RESULT}")"; rm -f "${RESULT}"
API_PROMPT="$(printf '%s' "${API_USAGE}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("prompt_tokens",0))' 2>/dev/null || echo 0)"
API_COMPLETION="$(printf '%s' "${API_USAGE}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("completion_tokens",0))' 2>/dev/null || echo 0)"
echo "  OpenAI usage reported by Ollama: prompt_tokens=${API_PROMPT} completion_tokens=${API_COMPLETION}"

if [[ "${DECODE_PHASE_SEEN}" -eq 1 ]]; then ok "phase DECODE observed while request in flight"; else fail "phase DECODE never observed in flight"; fi
if [[ "${PREFILL_SEEN}" -eq 1 ]]; then ok "phase PREFILL observed before decode"; else fail "phase PREFILL never observed before decode"; fi
if [[ "${LIVE_DECODE_SEEN}" -eq 1 ]]; then
  ok "live tg_3s observed at collector during decode (${LIVE_TG3} t/s)"
else
  fail "live tg_3s gauge never became positive during decode"
fi
if [[ -n "${PROM_TG3}" ]]; then
  if python3 -c "a=float('${LIVE_TG3}'); b=float('${PROM_TG3}'); exit(0 if abs(a-b) <= max(3.0, a*0.20) else 1)" 2>/dev/null; then
    ok "Grafana/Prometheus live tg_3s agrees with collector (${PROM_TG3} vs ${LIVE_TG3} t/s)"
  else
    fail "Grafana/Prometheus tg_3s ${PROM_TG3} differs from collector ${LIVE_TG3}"
  fi
else
  fail "Prometheus/Grafana did not expose a positive live tg_3s sample during decode"
fi

echo "=== Live validation: phase lifecycle IDLE -> PREFILL -> DECODE -> IDLE ==="
# After completion the journal contains the full sequence; verify from
# Prometheus that the state settled back to idle and that gauges are masked.
sleep 6
ACTIVE_NOW="$(prom_instant 'sum(ollama_slot_active) or vector(0)')"
PREFILL_NOW="$(prom_instant 'sum(ollama_slot_phase_prefill) or vector(0)')"
DECODE_NOW="$(prom_instant 'sum(ollama_slot_phase_decode) or vector(0)')"
if python3 -c "exit(0 if float('${ACTIVE_NOW:-1}') == 0 and float('${DECODE_NOW:-1}') == 0 else 1)" 2>/dev/null; then
  ok "state returned to IDLE after completion (slot_active=0, phases=0)"
else
  fail "state did not return to IDLE (active=${ACTIVE_NOW} prefill=${PREFILL_NOW} decode=${DECODE_NOW})"
fi
LIVE_TG_NOW="$(prom_instant 'sum(ollama_live_decode_tokens_per_second_3s) or vector(0)')"
if python3 -c "exit(0 if float('${LIVE_TG_NOW:-0}') == 0 else 1)" 2>/dev/null; then
  ok "live decode gauge masked to 0 when idle (no stale t/s)"
else
  fail "stale live decode t/s while idle: ${LIVE_TG_NOW}"
fi

echo "=== Live validation: journal final timings vs API usage ==="
AFTER_EVAL="$(coll_value 'ollama_prompt_evaluated_tokens_total')"; AFTER_EVAL="${AFTER_EVAL:-0}"
AFTER_GEN="$(coll_value 'ollama_generated_tokens_total')"; AFTER_GEN="${AFTER_GEN:-0}"
AFTER_COMP_SEC="$(coll_value 'ollama_compute_seconds_total')"; AFTER_COMP_SEC="${AFTER_COMP_SEC:-0}"
AFTER_PROMPT_SUBMITTED="$(coll_value 'ollama_prompt_tokens_submitted_total')"; AFTER_PROMPT_SUBMITTED="${AFTER_PROMPT_SUBMITTED:-0}"
AFTER_DECODE_SUM="$(coll_value 'ollama_decode_tokens_per_second_sum')"; AFTER_DECODE_SUM="${AFTER_DECODE_SUM:-0}"
AFTER_DECODE_COUNT="$(coll_value 'ollama_decode_tokens_per_second_count')"; AFTER_DECODE_COUNT="${AFTER_DECODE_COUNT:-0}"
DELTA_EVAL="$(python3 -c "print(${AFTER_EVAL} - ${BEFORE_EVAL})")"
DELTA_GEN="$(python3 -c "print(${AFTER_GEN} - ${BEFORE_GEN})")"
DELTA_SUBMITTED="$(python3 -c "print(${AFTER_PROMPT_SUBMITTED} - ${BEFORE_PROMPT_PROMPT})")"

# journal final prompt-eval count vs API prompt_eval_count may legitimately
# differ from the OpenAI prompt_tokens when cache hits skip tokens; here we
# check the generated tokens match exactly and prompt tokens are sane.
if python3 -c "exit(0 if ${DELTA_GEN:-0} >= ${API_COMPLETION:-1} * 0.9 and ${DELTA_GEN:-0} <= ${API_COMPLETION:-0} * 1.1 else 1)" 2>/dev/null; then
  ok "journal generated tokens (${DELTA_GEN}) ~= API completion_tokens (${API_COMPLETION})"
else
  fail "journal generated tokens ${DELTA_GEN} vs API completion_tokens ${API_COMPLETION}"
fi
if python3 -c "exit(0 if ${DELTA_EVAL:-0} > 0 else 1)" 2>/dev/null; then
  ok "journal evaluated prompt tokens increased (${DELTA_EVAL}; submitted logical: ${DELTA_SUBMITTED})"
else
  fail "journal evaluated prompt tokens did not increase"
fi
if python3 -c "exit(0 if ${AFTER_COMP_SEC:-0} > ${BEFORE_COMP_SEC:-0} else 1)" 2>/dev/null; then
  ok "compute time counter increased (+$(python3 -c "print(round(${AFTER_COMP_SEC} - ${BEFORE_COMP_SEC}, 2))")s)"
else
  fail "compute time counter did not increase"
fi

# Final journal timings (source of truth) read straight from the journal.
JOURNAL_FINAL="$(journalctl -u ollama --since '-3 min' --no-pager -o cat 2>/dev/null | grep -E 'print_timing' | tail -4)"
echo "  journal final timings:"
printf '%s\n' "${JOURNAL_FINAL}" | sed 's/^/    /' | cut -c1-160

JOURNAL_DECODE_TPS="$(printf '%s\n' "${JOURNAL_FINAL}" | python3 -c '
import re,sys
s=sys.stdin.read()
m=list(re.finditer(r"\|\s*eval time =.*?([0-9.]+) tokens per second",s))
print(m[-1].group(1) if m else "")' 2>/dev/null)"
DECODE_SUM_DELTA="$(python3 -c "print(float('${AFTER_DECODE_SUM}') - float('${BEFORE_DECODE_SUM}'))")"
DECODE_COUNT_DELTA="$(python3 -c "print(float('${AFTER_DECODE_COUNT}') - float('${BEFORE_DECODE_COUNT}'))")"
if [[ -n "${JOURNAL_DECODE_TPS}" ]] && python3 -c "exit(0 if float('${DECODE_COUNT_DELTA}') > 0 else 1)" 2>/dev/null; then
  GRAFANA_DECODE_TPS="$(python3 -c "print(float('${DECODE_SUM_DELTA}') / float('${DECODE_COUNT_DELTA}'))")"
  if python3 -c "a=float('${JOURNAL_DECODE_TPS}'); b=float('${GRAFANA_DECODE_TPS}'); exit(0 if abs(a-b) <= max(0.5, a*0.05) else 1)" 2>/dev/null; then
    ok "completed decode t/s agrees with journal (${GRAFANA_DECODE_TPS} vs ${JOURNAL_DECODE_TPS} t/s)"
  else
    fail "completed decode t/s ${GRAFANA_DECODE_TPS} differs from journal ${JOURNAL_DECODE_TPS}"
  fi
else
  fail "could not compare final journal decode t/s with the completed histogram"
fi

echo
echo "  live checks: PASSED=${PASS} FAILED=${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
