#!/usr/bin/env bash
# Shared host/runtime detection for the command-line helpers.
# This file is sourced by the scripts in bin/ and is not intended to be run
# directly.

VECTOR_IMAGE="${VECTOR_IMAGE:-timberio/vector:0.49.0-debian}"
NVIDIA_IMAGE="${NVIDIA_IMAGE:-utkuozdemir/nvidia_gpu_exporter:1.15.0}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

is_wsl2() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] ||
    grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1
}

journal_file() {
  local dir="$1"
  local file
  for file in "$dir"/*/*.journal "$dir"/*/*.journal~ "$dir"/*.journal; do
    if [[ -f "${file}" ]]; then
      printf '%s\n' "${file}"
      return 0
    fi
  done
  return 1
}

journal_dir_has_files() {
  journal_file "$1" >/dev/null 2>&1
}

journal_dir_has_current_boot() {
  local dir="$1"
  local boots
  [[ -d "${dir}" ]] || return 1
  boots="$(journalctl --directory="${dir}" --list-boots --no-pager 2>/dev/null || true)"
  [[ -n "${boots}" ]] || return 1
  printf '%s\n' "${boots}" | awk '$1 == 0 { found = 1 } END { exit(found ? 0 : 1) }'
}

resolve_journal_dir() {
  local candidate

  # An explicit path is authoritative, but must already exist. In particular,
  # this prevents a Docker bind mount from creating a typo on the host.
  if [[ -n "${JOURNAL_DIR:-}" ]]; then
    [[ -d "${JOURNAL_DIR}" ]] || return 1
    export JOURNAL_DIR
    return 0
  fi

  # Prefer the source containing the current boot. This matters when a host
  # keeps old persistent journals while the current boot is still volatile.
  for candidate in /var/log/journal /run/log/journal; do
    if [[ -d "${candidate}" ]] && journal_dir_has_current_boot "${candidate}"; then
      JOURNAL_DIR="${candidate}"
      export JOURNAL_DIR
      return 0
    fi
  done

  # A newly started service may not have a current-boot entry yet. Prefer a
  # populated persistent source before falling back to a populated volatile one.
  for candidate in /var/log/journal /run/log/journal; do
    if [[ -d "${candidate}" ]] && journal_dir_has_files "${candidate}"; then
      JOURNAL_DIR="${candidate}"
      export JOURNAL_DIR
      return 0
    fi
  done

  return 1
}

valid_numeric_id() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

resolve_journal_gid() {
  local file group_gid dir_gid

  if [[ -n "${JOURNAL_GID:-}" ]]; then
    valid_numeric_id "${JOURNAL_GID}"
    return
  fi

  # The file group is the effective permission that matters. This also covers
  # systems whose journal files use a nonstandard group name.
  file="$(journal_file "${JOURNAL_DIR}" 2>/dev/null || true)"
  if [[ -n "${file}" ]]; then
    JOURNAL_GID="$(stat -c '%g' "${file}" 2>/dev/null || true)"
    if valid_numeric_id "${JOURNAL_GID}"; then
      export JOURNAL_GID
      return 0
    fi
  fi

  group_gid="$(getent group systemd-journal 2>/dev/null | awk -F: 'NR == 1 { print $3 }')"
  if valid_numeric_id "${group_gid}"; then
    JOURNAL_GID="${group_gid}"
    export JOURNAL_GID
    return 0
  fi

  dir_gid="$(stat -c '%g' "${JOURNAL_DIR}" 2>/dev/null || true)"
  if valid_numeric_id "${dir_gid}"; then
    JOURNAL_GID="${dir_gid}"
    export JOURNAL_GID
    return 0
  fi

  return 1
}

resolve_runtime_values() {
  local strict="${1:-1}"
  local fallback_dir

  COLLECTOR_UID="${COLLECTOR_UID:-$(id -u)}"
  COLLECTOR_GID="${COLLECTOR_GID:-$(id -g)}"
  if ! valid_numeric_id "${COLLECTOR_UID}" || ! valid_numeric_id "${COLLECTOR_GID}"; then
    return 1
  fi

  if ! resolve_journal_dir; then
    if [[ "${strict}" == "1" ]]; then
      return 1
    fi
    # Used only so `docker compose down` and status can still parse the file
    # when a host journal is unavailable. `bin/up` always runs strictly.
    fallback_dir="${JOURNAL_DIR:-/var/log/journal}"
    JOURNAL_DIR="${fallback_dir}"
  fi

  if ! resolve_journal_gid; then
    if [[ "${strict}" == "1" ]]; then
      return 1
    fi
    JOURNAL_GID="${JOURNAL_GID:-0}"
  fi

  export COLLECTOR_UID COLLECTOR_GID JOURNAL_DIR JOURNAL_GID
}

collector_journal_probe() {
  [[ -d "${JOURNAL_DIR}" && -f /etc/machine-id ]] || return 1
  docker image inspect "${VECTOR_IMAGE}" >/dev/null 2>&1 || return 2
  docker run --rm \
    --user "${COLLECTOR_UID}:${COLLECTOR_GID}" \
    --group-add "${JOURNAL_GID}" \
    -v "${JOURNAL_DIR}:/var/log/journal:ro" \
    -v /etc/machine-id:/etc/machine-id:ro \
    --entrypoint journalctl "${VECTOR_IMAGE}" \
    -u ollama.service -b -n 1 --no-pager -o cat >/dev/null 2>&1
}

docker_gpu_accessible() {
  local pull_policy="${1:-never}"
  local -a docker_gpu_command
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  nvidia-smi -L >/dev/null 2>&1 || return 1
  docker_gpu_command=(docker run --rm "--pull=${pull_policy}" --gpus all \
    --entrypoint nvidia-smi "${NVIDIA_IMAGE}" -L)
  if command -v timeout >/dev/null 2>&1; then
    timeout 45s "${docker_gpu_command[@]}" >/dev/null 2>&1
  else
    "${docker_gpu_command[@]}" >/dev/null 2>&1
  fi
}

ollama_model_count() {
  curl -sf -m 5 "http://127.0.0.1:${OLLAMA_PORT}/api/ps" |
    python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("models", [])))' 2>/dev/null
}

ollama_version() {
  curl -sf -m 5 "http://127.0.0.1:${OLLAMA_PORT}/api/version" |
    python3 -c 'import json, sys; print(json.load(sys.stdin).get("version", "unknown"))' 2>/dev/null
}
