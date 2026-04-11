#!/usr/bin/env bash
# patches/post-install/01-jiti-trynative-bun-runtime.sh
#
# Fix: jiti's tryNative must be false when running under Bun (not just
# compiled Bun binaries). Without this, Bun's native resolver handles
# imports before jiti can apply its alias map, breaking pi package
# extensions that import @mariozechner/* peer dependencies.
#
# Two changes needed:
# 1. Add isBunRuntime to the import from config.js
# 2. Add tryNative:false when isBunRuntime is true
#
# This patch is idempotent — safe to run on every update.

set -euo pipefail

LOADER_PATHS=(
  /home/agent/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/core/extensions/loader.js
)

# Also patch any cached versions
for cached in /home/agent/.bun/install/cache/@mariozechner/pi-coding-agent@*/dist/core/extensions/loader.js; do
  [ -f "$cached" ] && LOADER_PATHS+=("$cached")
done

# Also patch piclaw's nested copy
for nested in /home/agent/.bun/install/global/node_modules/piclaw/node_modules/@mariozechner/pi-coding-agent/dist/core/extensions/loader.js; do
  [ -f "$nested" ] && LOADER_PATHS+=("$nested")
done

# Deduplicate by inode so hardlinked files are only patched once
declare -A seen_inodes
UNIQUE_PATHS=()
for p in "${LOADER_PATHS[@]}"; do
  [ -f "$p" ] || continue
  inode=$(stat -c '%i' "$p")
  if [ -z "${seen_inodes[$inode]:-}" ]; then
    seen_inodes[$inode]=1
    UNIQUE_PATHS+=("$p")
  fi
done

PATCHED=0
for loader in "${UNIQUE_PATHS[@]}"; do
  needs_patch=0

  # Check 1: import line missing isBunRuntime
  if grep -q 'import { getAgentDir, isBunBinary }' "$loader" 2>/dev/null; then
    needs_patch=1
  fi

  # Check 2: createJiti call missing isBunRuntime tryNative
  if grep -q 'isBunBinary ? { virtualModules: VIRTUAL_MODULES, tryNative: false } : { alias: getAliases() }' "$loader" 2>/dev/null; then
    needs_patch=1
  fi

  if [ "$needs_patch" -eq 0 ]; then
    # Verify it's already fully patched
    if grep -q 'isBunRuntime.*tryNative.*false' "$loader" 2>/dev/null && \
       grep -q 'isBunBinary, isBunRuntime' "$loader" 2>/dev/null; then
      echo "Already patched: $loader"
      continue
    fi
  fi

  # Apply patches via temp file (files may be root-owned)
  tmp=$(mktemp)
  cp "$loader" "$tmp"

  # Patch 1: Add isBunRuntime to the import
  sed -i 's|import { getAgentDir, isBunBinary }|import { getAgentDir, isBunBinary, isBunRuntime }|' "$tmp"

  # Patch 2: Add tryNative:false for isBunRuntime
  sed -i 's|isBunBinary ? { virtualModules: VIRTUAL_MODULES, tryNative: false } : { alias: getAliases() }|isBunBinary ? { virtualModules: VIRTUAL_MODULES, tryNative: false } : { alias: getAliases(), ...(isBunRuntime \&\& { tryNative: false }) }|' "$tmp"

  sudo cp --preserve=mode,ownership "$tmp" "$loader"
  rm -f "$tmp"
  echo "Patched: $loader"
  PATCHED=$((PATCHED + 1))
done

echo "Done. Patched $PATCHED file(s)."
