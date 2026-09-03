#!/usr/bin/env bash
# Passive acceptance test for traffic initiated by an external Ollama client.
# This script never sends an inference request. The operator starts the client
# request during the observation window.
set -uo pipefail
cd "$(dirname "$0")/.." || exit

MODE="${1:-generic}"
TIMEOUT="${OLLAMA_OBSERVE_TIMEOUT:-300}"
COLLECTOR="${OLLAMA_MONITORING_COLLECTOR_URL:-http://127.0.0.1:9598/metrics}"
PASS=0
FAIL=0

ok()   { printf '  [ OK ] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  [WARN] %s\n' "$1"; }

if ! [[ "${TIMEOUT}" =~ ^[0-9]+$ ]] || [[ "${TIMEOUT}" -lt 1 ]]; then
  echo "ERROR: OLLAMA_OBSERVE_TIMEOUT must be a positive number of seconds" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: curl and python3 are required for the observer" >&2
  exit 1
fi

fetch_snapshot() {
  local metrics
  metrics="$(curl -sf -m 5 "${COLLECTOR}")" || return 1
  printf '%s\n' "${metrics}" | python3 tests/metrics_snapshot.py
}

declare -A BEFORE_PATHS=()
declare -A AFTER_PATHS=()

# Set S_* scalar fields and populate the named HTTP path map from a snapshot.
# shellcheck disable=SC2034
load_snapshot() {
  local snapshot="$1"
  local path_map_name="$2"
  local -n path_map="${path_map_name}"
  local kind key value

  S_launch=0; S_release=0; S_idle=0; S_new_prompt=0
  S_prefill_events=0; S_decode_events=0; S_final_prompt=0
  S_final_eval=0; S_final_total=0; S_gin=0
  S_eval_tokens=0; S_generated_tokens=0; S_compute_tokens=0
  S_compute_seconds=0; S_prompt_submitted=0; S_decode_sum=0
  S_decode_count=0; S_active=0; S_prefill=0; S_decode=0
  S_live_tg=0; S_live_tg3=0; S_http_series=0; S_http_total=0
  path_map=()

  while IFS=$'\t' read -r kind key value; do
    [[ -n "${kind}" ]] || continue
    case "${kind}:${key}" in
      event:slot_launch) S_launch="${value}" ;;
      event:slot_release) S_release="${value}" ;;
      event:slots_idle) S_idle="${value}" ;;
      event:new_prompt) S_new_prompt="${value}" ;;
      event:prompt_processing) S_prefill_events="${value}" ;;
      event:live_decode) S_decode_events="${value}" ;;
      event:final_prompt_eval) S_final_prompt="${value}" ;;
      event:final_eval) S_final_eval="${value}" ;;
      event:final_total) S_final_total="${value}" ;;
      event:gin) S_gin="${value}" ;;
      metric:eval_tokens) S_eval_tokens="${value}" ;;
      metric:generated_tokens) S_generated_tokens="${value}" ;;
      metric:compute_tokens) S_compute_tokens="${value}" ;;
      metric:compute_seconds) S_compute_seconds="${value}" ;;
      metric:prompt_submitted) S_prompt_submitted="${value}" ;;
      metric:decode_sum) S_decode_sum="${value}" ;;
      metric:decode_count) S_decode_count="${value}" ;;
      metric:http_total) S_http_total="${value}" ;;
      gauge:active) S_active="${value}" ;;
      gauge:prefill) S_prefill="${value}" ;;
      gauge:decode) S_decode="${value}" ;;
      gauge:live_tg) S_live_tg="${value}" ;;
      gauge:live_tg3) S_live_tg3="${value}" ;;
      meta:http_series) S_http_series="${value}" ;;
      http:*) path_map["${key}"]="${value}" ;;
    esac
  done <<< "${snapshot}"
}

greater_than() {
  python3 - "$1" "$2" <<'PY'
import sys
try:
    sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)
except (ValueError, TypeError):
    sys.exit(1)
PY
}

nonzero() {
  greater_than "$1" 0
}

less_than() {
  greater_than "$2" "$1"
}

delta() {
  python3 - "$1" "$2" <<'PY'
import sys
try:
    print(float(sys.argv[1]) - float(sys.argv[2]))
except (ValueError, TypeError):
    print("0")
PY
}

# Vector's Prometheus process-lifetime counters can reset if the collector is
# recreated while an operator is testing. Keep the acceptance window useful by
# treating the first post-reset snapshot as a new zero baseline rather than
# reporting negative deltas.
reset_baseline_if_needed() {
  if less_than "${S_launch}" "${BEFORE_launch}" ||
    less_than "${S_release}" "${BEFORE_release}" ||
    less_than "${S_idle}" "${BEFORE_idle}" ||
    less_than "${S_new_prompt}" "${BEFORE_new_prompt}" ||
    less_than "${S_prefill_events}" "${BEFORE_prefill}" ||
    less_than "${S_decode_events}" "${BEFORE_decode}" ||
    less_than "${S_final_prompt}" "${BEFORE_final_prompt}" ||
    less_than "${S_final_eval}" "${BEFORE_final_eval}" ||
    less_than "${S_final_total}" "${BEFORE_final_total}" ||
    less_than "${S_gin}" "${BEFORE_gin}" ||
    less_than "${S_eval_tokens}" "${BEFORE_eval_tokens}" ||
    less_than "${S_generated_tokens}" "${BEFORE_generated_tokens}" ||
    less_than "${S_compute_tokens}" "${BEFORE_compute_tokens}" ||
    less_than "${S_compute_seconds}" "${BEFORE_compute_seconds}" ||
    less_than "${S_prompt_submitted}" "${BEFORE_prompt_submitted}" ||
    less_than "${S_decode_sum}" "${BEFORE_decode_sum}" ||
    less_than "${S_decode_count}" "${BEFORE_decode_count}" ||
    less_than "${S_http_total}" "${BEFORE_http_total}"; then
    echo "  observe: collector counters reset; restarting the observation baseline"
    BEFORE_launch=0; BEFORE_release=0; BEFORE_idle=0; BEFORE_new_prompt=0
    BEFORE_prefill=0; BEFORE_decode=0; BEFORE_final_prompt=0
    BEFORE_final_eval=0; BEFORE_final_total=0; BEFORE_gin=0
    BEFORE_eval_tokens=0; BEFORE_generated_tokens=0; BEFORE_compute_tokens=0
    BEFORE_compute_seconds=0; BEFORE_prompt_submitted=0; BEFORE_decode_sum=0
    BEFORE_decode_count=0; BEFORE_http_total=0
    BEFORE_PATHS=()
  fi
}

if [[ "${MODE}" == "kilo" ]]; then
  CLIENT_INSTRUCTION="Send one normal, moderately substantial task from Kilo now."
else
  CLIENT_INSTRUCTION="Send one normal, moderately substantial task from the external Ollama client now."
fi

echo "=== Passive external-client acceptance test ==="
echo "No inference request will be sent by this test."
echo "${CLIENT_INSTRUCTION}"
echo "Observation window: ${TIMEOUT}s; traffic is observed through journal-derived metrics."
echo "The journal does not expose a trustworthy client identity, so this proves activity during the declared window, not cryptographic client identity."

BEFORE="$(fetch_snapshot || true)"
if [[ -z "${BEFORE}" ]]; then
  echo "ERROR: collector metrics are unavailable at ${COLLECTOR}" >&2
  exit 1
fi
load_snapshot "${BEFORE}" BEFORE_PATHS
BEFORE_launch="${S_launch}"; BEFORE_release="${S_release}"; BEFORE_idle="${S_idle}"
BEFORE_new_prompt="${S_new_prompt}"; BEFORE_prefill="${S_prefill_events}"
BEFORE_decode="${S_decode_events}"; BEFORE_final_prompt="${S_final_prompt}"
BEFORE_final_eval="${S_final_eval}"; BEFORE_final_total="${S_final_total}"
BEFORE_gin="${S_gin}"; BEFORE_eval_tokens="${S_eval_tokens}"
BEFORE_generated_tokens="${S_generated_tokens}"; BEFORE_compute_tokens="${S_compute_tokens}"
BEFORE_compute_seconds="${S_compute_seconds}"; BEFORE_prompt_submitted="${S_prompt_submitted}"
BEFORE_decode_sum="${S_decode_sum}"; BEFORE_decode_count="${S_decode_count}"
BEFORE_http_total="${S_http_total}"

ACTIVITY_SEEN=0
IDLE_RETURNED=0
PREFILL_EVENT_SEEN=0
DECODE_EVENT_SEEN=0
LIVE_TG3_SEEN=0
PEAK_TG3=0
LATEST_TG3=0
PEAK_TG=0
LATEST_TG=0
LAST_PROGRESS=""
DEADLINE=$(( $(date +%s) + TIMEOUT ))

while [[ "$(date +%s)" -lt "${DEADLINE}" ]]; do
  SNAPSHOT="$(fetch_snapshot || true)"
  if [[ -z "${SNAPSHOT}" ]]; then
    sleep 1
    continue
  fi
  load_snapshot "${SNAPSHOT}" AFTER_PATHS
  reset_baseline_if_needed

  if greater_than "${S_launch}" "${BEFORE_launch}" || greater_than "${S_new_prompt}" "${BEFORE_new_prompt}" || greater_than "${S_decode_events}" "${BEFORE_decode}"; then
    ACTIVITY_SEEN=1
  fi
  if greater_than "${S_prefill_events}" "${BEFORE_prefill}" || greater_than "${S_final_prompt}" "${BEFORE_final_prompt}"; then
    PREFILL_EVENT_SEEN=1
  fi
  if greater_than "${S_decode_events}" "${BEFORE_decode}" || greater_than "${S_final_eval}" "${BEFORE_final_eval}"; then
    DECODE_EVENT_SEEN=1
  fi
  if nonzero "${S_live_tg3}"; then
    LIVE_TG3_SEEN=1
    LATEST_TG3="${S_live_tg3}"
    if greater_than "${S_live_tg3}" "${PEAK_TG3}"; then
      PEAK_TG3="${S_live_tg3}"
    fi
  fi
  if nonzero "${S_live_tg}"; then
    LATEST_TG="${S_live_tg}"
    if greater_than "${S_live_tg}" "${PEAK_TG}"; then
      PEAK_TG="${S_live_tg}"
    fi
  fi
  if [[ "${ACTIVITY_SEEN}" -eq 1 && "${IDLE_RETURNED}" -eq 0 ]] &&
    ! nonzero "${S_active}" && ! nonzero "${S_prefill}" && ! nonzero "${S_decode}"; then
    if greater_than "${S_release}" "${BEFORE_release}" || greater_than "${S_idle}" "${BEFORE_idle}"; then
      IDLE_RETURNED=1
    fi
  fi

  PROGRESS="activity=${ACTIVITY_SEEN} prefill=${PREFILL_EVENT_SEEN} decode=${DECODE_EVENT_SEEN} idle=${IDLE_RETURNED} tg_3s=${LATEST_TG3:-0}"
  if [[ "${PROGRESS}" != "${LAST_PROGRESS}" ]]; then
    echo "  observe: ${PROGRESS}"
    LAST_PROGRESS="${PROGRESS}"
  fi

  if [[ "${ACTIVITY_SEEN}" -eq 1 && "${IDLE_RETURNED}" -eq 1 && "${DECODE_EVENT_SEEN}" -eq 1 && "${LIVE_TG3_SEEN}" -eq 1 ]]; then
    # Give the final timing and GIN lines a couple of scrapes to arrive.
    sleep 2
    break
  fi
  sleep 0.5
done

AFTER="$(fetch_snapshot || true)"
if [[ -n "${AFTER}" ]]; then
  load_snapshot "${AFTER}" AFTER_PATHS
  reset_baseline_if_needed
fi

LAUNCH_DELTA="$(delta "${S_launch}" "${BEFORE_launch}")"
RELEASE_DELTA="$(delta "${S_release}" "${BEFORE_release}")"
IDLE_DELTA="$(delta "${S_idle}" "${BEFORE_idle}")"
PREFILL_DELTA="$(delta "${S_prefill_events}" "${BEFORE_prefill}")"
FINAL_PROMPT_DELTA="$(delta "${S_final_prompt}" "${BEFORE_final_prompt}")"
NEW_PROMPT_DELTA="$(delta "${S_new_prompt}" "${BEFORE_new_prompt}")"
DECODE_DELTA="$(delta "${S_decode_events}" "${BEFORE_decode}")"
FINAL_EVAL_DELTA="$(delta "${S_final_eval}" "${BEFORE_final_eval}")"
FINAL_TOTAL_DELTA="$(delta "${S_final_total}" "${BEFORE_final_total}")"
GIN_DELTA="$(delta "${S_gin}" "${BEFORE_gin}")"
EVAL_DELTA="$(delta "${S_eval_tokens}" "${BEFORE_eval_tokens}")"
GENERATED_DELTA="$(delta "${S_generated_tokens}" "${BEFORE_generated_tokens}")"
COMPUTE_TOKENS_DELTA="$(delta "${S_compute_tokens}" "${BEFORE_compute_tokens}")"
COMPUTE_SECONDS_DELTA="$(delta "${S_compute_seconds}" "${BEFORE_compute_seconds}")"
SUBMITTED_DELTA="$(delta "${S_prompt_submitted}" "${BEFORE_prompt_submitted}")"
DECODE_SUM_DELTA="$(delta "${S_decode_sum}" "${BEFORE_decode_sum}")"
DECODE_COUNT_DELTA="$(delta "${S_decode_count}" "${BEFORE_decode_count}")"
HTTP_DELTA="$(delta "${S_http_total}" "${BEFORE_http_total}")"

echo
echo "=== External lifecycle evidence ==="
if greater_than "${LAUNCH_DELTA}" 0 && greater_than "${NEW_PROMPT_DELTA}" 0; then
  ok "new inference/task lifecycle observed (launch=${LAUNCH_DELTA}, new_prompt=${NEW_PROMPT_DELTA})"
else
  fail "no new inference/task lifecycle observed"
fi
if greater_than "${PREFILL_DELTA}" 0 || greater_than "${FINAL_PROMPT_DELTA}" 0; then
  ok "PREFILL evidence observed (prompt progress=${PREFILL_DELTA}, final prompt eval=${FINAL_PROMPT_DELTA})"
else
  fail "no parsed PREFILL evidence observed"
fi
if greater_than "${DECODE_DELTA}" 0; then ok "DECODE activity observed from live journal events (live=${DECODE_DELTA}, final=${FINAL_EVAL_DELTA})"; else fail "no live DECODE event observed"; fi
if [[ "${LIVE_TG3_SEEN}" -eq 1 ]]; then
  ok "live tg_3s became positive (peak=${PEAK_TG3} t/s, latest=${LATEST_TG3} t/s)"
else
  fail "live tg_3s never became positive during the observation window"
fi
if (greater_than "${RELEASE_DELTA}" 0 || greater_than "${IDLE_DELTA}" 0) && ! nonzero "${S_active}" && ! nonzero "${S_prefill}" && ! nonzero "${S_decode}"; then
  ok "returned to IDLE (release=${RELEASE_DELTA}, idle=${IDLE_DELTA}, gauges clear)"
else
  fail "did not observe a completed return to IDLE"
fi
if greater_than "${GENERATED_DELTA}" 0; then ok "completed generated-token counter increased (+${GENERATED_DELTA})"; else fail "completed generated-token counter did not increase"; fi
if greater_than "${FINAL_TOTAL_DELTA}" 0 && greater_than "${COMPUTE_TOKENS_DELTA}" 0 && greater_than "${COMPUTE_SECONDS_DELTA}" 0; then
  ok "completed compute counters/timing increased (requests=${FINAL_TOTAL_DELTA}, tokens=+${COMPUTE_TOKENS_DELTA}, seconds=+${COMPUTE_SECONDS_DELTA})"
else
  fail "completed compute counters/timing did not increase"
fi

if [[ "${S_http_series}" -gt 0 ]]; then
  if greater_than "${HTTP_DELTA}" 0; then
    ok "passive GIN HTTP request counter increased (+${HTTP_DELTA}; parsed gin events +${GIN_DELTA})"
  else
    fail "GIN request metrics are available but no passive HTTP counter increase was observed"
  fi
else
  warn "GIN request metrics are unavailable; HTTP-count validation was skipped"
fi

echo
echo "=== Observation summary ==="
REQUESTS="${FINAL_TOTAL_DELTA}"
echo "  requests observed: ${REQUESTS}"
echo "  evaluated prompt tokens: ${EVAL_DELTA}"
echo "  submitted prompt tokens: ${SUBMITTED_DELTA}"
echo "  generated tokens: ${GENERATED_DELTA}"
if greater_than "${DECODE_COUNT_DELTA}" 0; then
  COMPLETED_AVG="$(python3 - "${DECODE_SUM_DELTA}" "${DECODE_COUNT_DELTA}" <<'PY'
import sys
print(round(float(sys.argv[1]) / float(sys.argv[2]), 3))
PY
)"
else
  COMPLETED_AVG="n/a"
fi
echo "  peak/latest live tg/tg_3s: ${PEAK_TG:-0}/${LATEST_TG:-0} / ${PEAK_TG3:-0}/${LATEST_TG3:-0} t/s"
echo "  completed average decode t/s: ${COMPLETED_AVG}"

if ((${#AFTER_PATHS[@]} > 0)); then
  ENDPOINTS=""
  for path in "${!AFTER_PATHS[@]}"; do
    BEFORE_PATH_VALUE="${BEFORE_PATHS[${path}]:-0}"
    PATH_DELTA="$(delta "${AFTER_PATHS[${path}]}" "${BEFORE_PATH_VALUE}")"
    if greater_than "${PATH_DELTA}" 0; then
      ENDPOINTS="${ENDPOINTS:+${ENDPOINTS}, }${path} (+${PATH_DELTA})"
    fi
  done
  if [[ -n "${ENDPOINTS}" ]]; then
    echo "  endpoint(s) observed: ${ENDPOINTS}"
  else
    echo "  endpoint(s) observed: no path delta reported"
  fi
else
  echo "  endpoint(s) observed: no parsed GIN paths"
fi

echo
echo "  observer checks: PASSED=${PASS} FAILED=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
