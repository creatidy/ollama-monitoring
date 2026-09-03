#!/usr/bin/env bash
# Offline portability, profile, dashboard, and tracked-file hygiene checks.
set -uo pipefail
cd "$(dirname "$0")/.." || exit

PASS=0
FAIL=0
ok() { printf '  [ OK ] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "${name}"; else fail "${name}"; fi
}

echo "=== Offline portability/profile checks ==="
check "all shell scripts parse" bash -n bin/*.sh bin/* tests/*.sh
check "Python helpers compile" python3 -m py_compile tests/*.py

COMPOSE_ENV=(
  COLLECTOR_UID=1234
  COLLECTOR_GID=1234
  JOURNAL_GID=2345
  JOURNAL_DIR="$PWD"
  GRAFANA_ADMIN_PASSWORD=ci-only-not-a-password
)

if CORE_CONFIG="$(env "${COMPOSE_ENV[@]}" docker compose config --format json 2>/dev/null)"; then
  ok "core Compose config renders without NVIDIA profile"
else
  fail "core Compose config renders without NVIDIA profile"
  CORE_CONFIG="{}"
fi

if GPU_CONFIG="$(env "${COMPOSE_ENV[@]}" docker compose --profile nvidia config --format json 2>/dev/null)"; then
  ok "NVIDIA Compose profile renders"
else
  fail "NVIDIA Compose profile renders"
  GPU_CONFIG="{}"
fi

if python3 - "${CORE_CONFIG}" "${GPU_CONFIG}" <<'PY'
import json
import sys

core = json.loads(sys.argv[1])
gpu = json.loads(sys.argv[2])
core_services = core.get("services", {})
gpu_services = gpu.get("services", {})
assert "journal-metrics" in core_services
assert "prometheus" in core_services
assert "grafana" in core_services
assert "nvidia-gpu-exporter" not in core_services
assert "nvidia-gpu-exporter" in gpu_services
assert "gpus" not in core_services["journal-metrics"]
mounts = core_services["journal-metrics"].get("volumes", [])
journal_mounts = [m for m in mounts if m.get("target") == "/var/log/journal"]
assert len(journal_mounts) == 1
journal_mount = journal_mounts[0]
assert journal_mount.get("read_only") is True
machine_mounts = [m for m in mounts if m.get("target") == "/etc/machine-id"]
assert len(machine_mounts) == 1
assert machine_mounts[0].get("read_only") is True
PY
then
  ok "core has no GPU requirement and journal binds are safe"
else
  fail "core has no GPU requirement and journal binds are safe"
fi

check "Compose does not depend on both host journal paths" bash -c '! grep -qE "(/var/log/journal|/run/log/journal):/" compose.yaml'
check "journal and machine-id binds disable host path creation" bash -c 'grep -c "create_host_path: false" compose.yaml | grep -qx 2'
check "Compose has no fixed collector uid/gid assumptions" bash -c '! grep -qE "1000|999" compose.yaml'
check "example does not ship a reusable Grafana password" bash -c '! grep -q "GRAFANA_ADMIN_PASSWORD=ollama" .env.example'
check "local Grafana credentials file is ignored" git check-ignore -q .env
check "GIN endpoint and method labels are normalized" bash -c "grep -q 'endpoint = \"other\"' collector/vector.toml && grep -q '/api/blobs/:digest' collector/vector.toml && grep -q 'method = \"OTHER\"' collector/vector.toml"
check "startup gate includes every core service" bash -c "grep -q 'core_services=(journal-metrics prometheus grafana)' bin/up"

if python3 - <<'PY'
import json
from pathlib import Path

dashboard = json.loads(Path("grafana/dashboards/ollama.json").read_text())
gpu_panel_ids = {20, 21, 22, 23, 30, 31, 32, 33}
for panel in dashboard.get("panels", []):
    if panel.get("type") == "row":
        continue
    for target in panel.get("targets", []):
        if "nvidia_" in target.get("expr", "").lower():
            assert panel.get("id") in gpu_panel_ids, panel.get("title")
PY
then
  ok "dashboard core queries do not require NVIDIA metrics"
else
  fail "dashboard core queries do not require NVIDIA metrics"
fi

if git grep -nE '/home/[[:alnum:]_.-]+|/tmp/kilo|(^|[^[:alnum:]])ROG([^[:alnum:]]|$)|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY|XSECRET-[A-Za-z0-9-]{8,}' -- \
  ':(exclude).gitignore' \
  ':(exclude)tests/test_offline.sh' \
  ':(exclude)tests/test_security.sh' >/dev/null 2>&1; then
  fail "tracked files contain host paths, markers, or credential-shaped strings"
else
  ok "tracked files pass host-path and credential-shaped privacy scan"
fi

echo
echo "  offline checks: PASSED=${PASS} FAILED=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
