#!/usr/bin/env bash
# Collector restart / journald cursor validation (stack must be running).
#
#  - counters survive a container restart without replaying the current boot
#    (journald cursor checkpoint in ./data/vector)
#  - new journal entries keep flowing after restart
#  - Prometheus resumes scraping the collector
set -uo pipefail
cd "$(dirname "$0")/.." || exit

PASS=0; FAIL=0
ok()   { echo "  [ OK ] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

coll_value() {
  curl -sf -m 5 http://127.0.0.1:9598/metrics 2>/dev/null | python3 -c "
import re,sys
pat = re.compile(r'^$1\s+(\S+)', re.M)
print(sum(float(m.group(1)) for m in (pat.match(l) for l in sys.stdin) if m))" 2>/dev/null
}

echo "=== Restart/cursor: baseline ==="
BEFORE_SEEN="$(coll_value 'ollama_journal_lines_seen_total')"; BEFORE_SEEN="${BEFORE_SEEN:-0}"
BEFORE_GEN="$(coll_value 'ollama_generated_tokens_total')"; BEFORE_GEN="${BEFORE_GEN:-0}"
echo "  seen lines: ${BEFORE_SEEN}, generated tokens counter: ${BEFORE_GEN}"

CURSOR_BEFORE="$(docker exec ollama-journal-metrics sh -c 'cat /var/lib/vector-data/ollama_journal/checkpoint.txt 2>/dev/null' | head -c 80)"
if [[ -n "${CURSOR_BEFORE}" ]]; then
  ok "journald cursor checkpoint exists (${CURSOR_BEFORE}...)"
else
  fail "no cursor checkpoint in ./data/vector"
fi

echo "=== Restarting collector container ==="
docker compose restart journal-metrics >/dev/null 2>&1
for _ in $(seq 1 40); do
  curl -sf -m 2 http://127.0.0.1:9598/metrics >/dev/null 2>&1 && break
  sleep 1
done
sleep 3

# A quiet journal is expected immediately after a restart. Generate a bounded,
# harmless GIN event and wait for journalctl + Vector to consume it. The
# request is retried because the journald source can take a few seconds to
# reconnect after the Vector process starts.
PORT="${OLLAMA_PORT:-11434}"
AFTER_SEEN=0
for _ in $(seq 1 60); do
  curl -sf --connect-timeout 2 --max-time 5 "http://127.0.0.1:${PORT}/api/version" >/dev/null 2>&1 || true
  sleep 1
  AFTER_SEEN="$(coll_value 'ollama_journal_lines_seen_total')"; AFTER_SEEN="${AFTER_SEEN:-0}"
  if python3 -c "exit(0 if ${AFTER_SEEN} > 0 else 1)" 2>/dev/null; then
    break
  fi
done
AFTER_GEN="$(coll_value 'ollama_generated_tokens_total')"; AFTER_GEN="${AFTER_GEN:-0}"
if python3 -c "exit(0 if ${AFTER_SEEN:-0} > 0 else 1)" 2>/dev/null; then
  ok "collector consuming journal again after restart (seen=${AFTER_SEEN%.*})"
else
  fail "collector sees no new journal lines after restart"
fi
REPLAYED="$(python3 -c "print(1 if ${AFTER_GEN:-0} > ${BEFORE_GEN:-0} + 100 else 0)" 2>/dev/null || echo 0)"
if [[ "${REPLAYED}" == "0" ]]; then
  ok "counters resumed from cursor (generated tokens ${BEFORE_GEN%.*} -> ${AFTER_GEN%.*}, no full-boot replay)"
else
  fail "counters jumped after restart: generated tokens ${BEFORE_GEN%.*} -> ${AFTER_GEN%.*} (replay?)"
fi

PROM_UP="$(curl -sf -m 10 http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=up{job="journal-metrics"}' 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["result"]; print(d[0]["value"][1] if d else "")' 2>/dev/null)"
if [[ "${PROM_UP}" == "1" ]]; then
  ok "Prometheus resumed scraping the collector"
else
  fail "Prometheus not scraping collector after restart"
fi

echo
echo "  restart checks: PASSED=${PASS} FAILED=${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
