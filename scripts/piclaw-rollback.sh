#!/usr/bin/env bash

set -euo pipefail

LIVE_DIR="/workspace/src/piclaw-live"
PREVIOUS_DIR="/workspace/src/piclaw-live.previous"
STATE_DIR="/workspace/.state"
LOCK_DIR="${STATE_DIR}/piclaw-live.update.lock"
LOCK_ACQUIRED=0

status() {
  printf '[piclaw-rollback] %s\n' "$*"
}

error() {
  printf '[piclaw-rollback] ERROR: %s\n' "$*" >&2
}

cleanup() {
  local exit_code=$?

  if [ "${LOCK_ACQUIRED}" -eq 1 ] && [ -d "${LOCK_DIR}" ]; then
    rmdir "${LOCK_DIR}" 2>/dev/null || true
  fi

  exit "${exit_code}"
}

trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Required command not found: $1"
    exit 1
  fi
}

acquire_lock() {
  mkdir -p "${STATE_DIR}"
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    LOCK_ACQUIRED=1
    return 0
  fi

  error "Another update or rollback is already running (${LOCK_DIR})"
  exit 1
}

wait_for_health() {
  local attempt
  for attempt in $(seq 1 30); do
    if sudo systemctl is-active piclaw.service >/dev/null 2>&1 && curl -fsS http://127.0.0.1:8080/login >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

main() {
  require_command sudo
  require_command curl
  require_command systemctl
  acquire_lock

  if [ ! -d "${PREVIOUS_DIR}" ]; then
    error "No previous checkout to roll back to (${PREVIOUS_DIR})"
    exit 1
  fi

  local swap_dir="${LIVE_DIR}.rollback.$(date +%s)"

  if [ -d "${LIVE_DIR}" ]; then
    mv "${LIVE_DIR}" "${swap_dir}"
  fi

  mv "${PREVIOUS_DIR}" "${LIVE_DIR}"

  if [ -d "${swap_dir}" ]; then
    mv "${swap_dir}" "${PREVIOUS_DIR}"
  fi

  status "Restarting piclaw service"
  sudo systemctl restart piclaw.service

  if ! wait_for_health; then
    error "PiClaw failed health checks after rollback"
    exit 1
  fi

  status "Rollback complete"
}

main "$@"
