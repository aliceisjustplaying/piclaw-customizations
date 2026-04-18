#!/usr/bin/env bash
#
# piclaw-tmp-gc.sh — prune stale worktrees and scratch dirs under
# /workspace/.tmp and /workspace/tmp, plus piclaw update-lock debris.
#
# Policy (all tunable via env):
#   MAX_AGE_DAYS  — stale age threshold (default 2)
#   DRY_RUN       — when 1, report actions without deleting
#   KEEP_NAMES    — colon-separated basenames to always preserve
#                   (default: locket)
#
# Exit codes:
#   0 success, 1 fatal error. Soft failures (one worktree stuck, etc.)
#   are logged but do not abort the sweep.

set -euo pipefail

MAX_AGE_DAYS="${MAX_AGE_DAYS:-2}"
DRY_RUN="${DRY_RUN:-0}"
KEEP_NAMES="${KEEP_NAMES:-locket}"
SWEEP_HOST_TMP="${SWEEP_HOST_TMP:-1}"
# names under host /tmp that must never be removed
HOST_TMP_KEEP_NAMES="${HOST_TMP_KEEP_NAMES:-piclaw-bun-cache:node-compile-cache:jiti}"

ROOTS=(
  /workspace/.tmp
  /workspace/tmp
)

REPOS_FOR_WORKTREE_PRUNE=(
  /workspace/src/piclaw-live
  /workspace/src/piclaw-live.previous
  /workspace/src/piclaw-fork
  /workspace/src/piclaw-customizations
  /workspace/src/pix
  /workspace/.cache/piclaw-fork
  /workspace/.cache/piclaw-upstream
)

log() { printf '[piclaw-tmp-gc] %s\n' "$*"; }

should_keep() {
  local name="$1"
  local kept
  IFS=':' read -r -a kept <<<"$KEEP_NAMES"
  for k in "${kept[@]}"; do
    [ "$name" = "$k" ] && return 0
  done
  return 1
}

df_root_free_mb() {
  df --output=avail -B1M / 2>/dev/null | tail -1 | tr -d ' '
}

prune_worktrees() {
  local repo
  for repo in "${REPOS_FOR_WORKTREE_PRUNE[@]}"; do
    [ -d "$repo/.git" ] || continue
    if [ "$DRY_RUN" = "1" ]; then
      log "would prune worktrees in $repo"
      git -C "$repo" worktree list || true
    else
      git -C "$repo" worktree prune -v || true
    fi
  done
}

sweep_root() {
  local root="$1"
  [ -d "$root" ] || return 0

  local entry name mtime age_days
  local now
  now="$(date +%s)"

  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    if should_keep "$name"; then
      continue
    fi

    # stat the entry itself, not its contents, so newly-touched inner files
    # don't keep an otherwise stale worktree alive.
    mtime="$(stat -c '%Y' "$entry" 2>/dev/null || echo 0)"
    age_days=$(( (now - mtime) / 86400 ))

    if [ "$age_days" -lt "$MAX_AGE_DAYS" ]; then
      continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      log "would remove $entry (age=${age_days}d)"
    else
      log "removing $entry (age=${age_days}d)"
      rm -rf --one-file-system "$entry" 2>/dev/null || \
        log "WARN: could not remove $entry"
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

sweep_host_tmp() {
  # piclaw runs with PrivateTmp=yes, so /tmp inside this process is the
  # service's namespaced view, not the real host /tmp. Reach the real one
  # via SSH to localhost (agent has passwordless sudo via wheel) and apply
  # the same age/keep filter, restricted to agent-owned entries to avoid
  # touching system service tmp dirs.

  if ! command -v ssh >/dev/null 2>&1; then
    log "sweep_host_tmp: ssh missing, skipping"
    return 0
  fi

  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 localhost true 2>/dev/null; then
    log "sweep_host_tmp: ssh to localhost failed, skipping"
    return 0
  fi

  # Build the find regex from the keep list.
  local keep_re=""
  local IFS=':'
  read -r -a keep_arr <<<"$HOST_TMP_KEEP_NAMES"
  unset IFS
  for k in "${keep_arr[@]}"; do
    [ -z "$k" ] && continue
    if [ -z "$keep_re" ]; then
      keep_re="$k"
    else
      keep_re="${keep_re}|${k}"
    fi
  done
  # always preserve user-runtime sockets and system marker dirs
  if [ -n "$keep_re" ]; then
    keep_re="${keep_re}|tmux-.*"
  else
    keep_re="tmux-.*"
  fi

  log "sweep_host_tmp: target=/tmp on host  age=>${MAX_AGE_DAYS}d  keep=${keep_re}"

  local before_mb after_mb action
  before_mb="$(ssh -o BatchMode=yes localhost "sudo du -sBM /tmp 2>/dev/null | awk '{print \$1}' | tr -d M" 2>/dev/null || echo 0)"

  if [ "$DRY_RUN" = "1" ]; then
    action="-print"
    log "sweep_host_tmp: DRY_RUN — listing only"
  else
    action="-delete"
  fi

  # -mtime +N matches files older than N+1 days. We use mtime > MAX_AGE_DAYS
  # but with -mtime +(N-1) so the boundary matches the local sweep_root
  # semantics of "strictly older than MAX_AGE_DAYS days".
  local mtime_arg=$(( MAX_AGE_DAYS > 0 ? MAX_AGE_DAYS - 1 : 0 ))

  # Use posix-egrep to negate the keep list. Top-level entries only.
  local find_cmd
  find_cmd="sudo find /tmp -maxdepth 1 -mindepth 1 -user agent -mtime +${mtime_arg} \
    -regextype posix-egrep ! -regex \".*/(${keep_re})\$\" \
    ${action}"

  if [ "$DRY_RUN" = "1" ]; then
    ssh -o BatchMode=yes localhost "$find_cmd" 2>/dev/null | sed 's|^|[piclaw-tmp-gc]   would remove |'
  else
    ssh -o BatchMode=yes localhost "$find_cmd" 2>&1 | tail -5 | sed 's|^|[piclaw-tmp-gc]   |'
  fi

  after_mb="$(ssh -o BatchMode=yes localhost "sudo du -sBM /tmp 2>/dev/null | awk '{print \$1}' | tr -d M" 2>/dev/null || echo 0)"
  local delta=$(( before_mb - after_mb ))
  log "sweep_host_tmp: host /tmp went ${before_mb} MB -> ${after_mb} MB (~${delta} MB freed)"
}

clean_update_lock() {
  local lock="/workspace/.state/piclaw-live.update.lock"
  [ -d "$lock" ] || return 0

  local mtime
  mtime="$(stat -c '%Y' "$lock" 2>/dev/null || echo 0)"
  local age_sec=$(( $(date +%s) - mtime ))
  # Only clean if older than 30 min — avoid racing a live update.
  if [ "$age_sec" -lt 1800 ]; then
    log "piclaw update lock present and recent (${age_sec}s); leaving alone"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "would remove stale update lock $lock (age=${age_sec}s)"
  else
    log "removing stale update lock $lock (age=${age_sec}s)"
    rmdir "$lock" 2>/dev/null || rm -rf "$lock" 2>/dev/null || \
      log "WARN: could not remove $lock"
  fi
}

main() {
  local before_mb
  before_mb="$(df_root_free_mb || echo 0)"
  log "start: free=${before_mb} MB  max_age_days=${MAX_AGE_DAYS}  dry_run=${DRY_RUN}"

  prune_worktrees

  local root
  for root in "${ROOTS[@]}"; do
    sweep_root "$root"
  done

  clean_update_lock

  if [ "$SWEEP_HOST_TMP" = "1" ]; then
    sweep_host_tmp
  fi

  local after_mb
  after_mb="$(df_root_free_mb || echo 0)"
  local delta=$(( after_mb - before_mb ))
  log "done: free=${after_mb} MB  reclaimed~${delta} MB"
}

main "$@"
