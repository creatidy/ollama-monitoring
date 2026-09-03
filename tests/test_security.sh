#!/usr/bin/env bash
# Security / privacy validation (stack must be running).
#
#  - no prompt or response text appears in the collector's /metrics output
#  - journal and config mounts are read-only
#  - no Docker socket, no privileged mode, no host PID namespace
set -uo pipefail
cd "$(dirname "$0")/.." || exit

PASS=0; FAIL=0
ok()   { echo "  [ OK ] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== Security: marker content must not leak into /metrics ==="
# Send a request containing a unique marker straight to native Ollama (if
# reachable); then check the collector /metrics for the marker.
PORT="${OLLAMA_PORT:-11434}"
MARKER="XSECRET-$(date +%s)-XMONITORING"
MODEL="${MODEL:-${OLLAMA_MODEL:-}}"
if [[ -z "${MODEL}" ]]; then
  MODEL="$(curl -sf -m 5 "http://127.0.0.1:${PORT}/api/ps" | python3 -c '
import json,sys
d = json.load(sys.stdin)
names = [m.get("name", "") for m in d.get("models", []) if "embed" not in m.get("name", "").lower()]
print(names[0] if names else "")' 2>/dev/null)"
fi
if [[ -z "${MODEL}" ]]; then
  MODEL="$(curl -sf -m 5 "http://127.0.0.1:${PORT}/api/tags" | python3 -c '
import json,sys
d = json.load(sys.stdin)
names = [m.get("name", "") for m in d.get("models", []) if "embed" not in m.get("name", "").lower()]
print(names[0] if names else "")' 2>/dev/null)"
fi
if [[ -n "${MODEL}" ]]; then
  curl -sf -m 120 "http://127.0.0.1:${PORT}/api/generate" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"Repeat this code and nothing else: ${MARKER}\",\"stream\":false,\"options\":{\"num_predict\":16}}" >/dev/null 2>&1 || true
else
  echo "  [WARN] no non-embedding model available; leak check uses current exporter state"
fi
sleep 2
METRICS="$(curl -sf -m 5 http://127.0.0.1:9598/metrics 2>/dev/null)"
if [[ -n "${METRICS}" ]] && ! printf '%s' "${METRICS}" | grep -q "${MARKER}"; then
  ok "no request marker in /metrics"
elif [[ -z "${METRICS}" ]]; then
  fail "collector /metrics unavailable"
else
  fail "request marker LEAKED into /metrics"
fi
if [[ -n "${METRICS}" ]] && ! printf '%s' "${METRICS}" | grep -qiE 'repeat this code|code and nothing'; then
  ok "no prompt text in /metrics"
else
  fail "prompt text found in /metrics"
fi

echo "=== Security: container isolation ==="
CHECKS="$(docker inspect ollama-journal-metrics --format '{{json .HostConfig}} {{json .Mounts}}' 2>/dev/null)"
if printf '%s' "${CHECKS}" | grep -q '"Privileged":false'; then
  ok "collector not privileged"
else
  fail "collector privileged flag not false"
fi
if ! printf '%s' "${CHECKS}" | grep -q 'docker.sock'; then
  ok "no Docker socket mounted"
else
  fail "Docker socket mounted"
fi
if printf '%s' "${CHECKS}" | grep -q '"PidMode":""'; then
  ok "no host PID namespace"
else
  fail "host PID namespace in use"
fi
RO_BAD="$(docker inspect ollama-journal-metrics --format '{{range .Mounts}}{{.Source}}:{{.RW}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '/var/log/journal|/etc/machine-id|/run/log/journal' | grep ':true' || true)"
if [[ -z "${RO_BAD}" ]]; then
  ok "journal/machine-id mounts are read-only"
else
  fail "journal mounts writable: ${RO_BAD}"
fi

echo
echo "  security checks: PASSED=${PASS} FAILED=${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
