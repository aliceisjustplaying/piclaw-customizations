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

  local after_mb
  after_mb="$(df_root_free_mb || echo 0)"
  local delta=$(( after_mb - before_mb ))
  log "done: free=${after_mb} MB  reclaimed~${delta} MB"
}

main "$@"
