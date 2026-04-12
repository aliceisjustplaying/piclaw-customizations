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
# This patch is idempotent and only touches the provided repo root.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $(basename "$0") <repo-root>" >&2
  exit 1
fi

REPO_ROOT="$1"
TOP_LEVEL_LOADER="${REPO_ROOT}/node_modules/@mariozechner/pi-coding-agent/dist/core/extensions/loader.js"
NESTED_LOADER="${REPO_ROOT}/node_modules/piclaw/node_modules/@mariozechner/pi-coding-agent/dist/core/extensions/loader.js"

LOADER_PATHS=()
[ -f "${TOP_LEVEL_LOADER}" ] && LOADER_PATHS+=("${TOP_LEVEL_LOADER}")
[ -f "${NESTED_LOADER}" ] && LOADER_PATHS+=("${NESTED_LOADER}")

if [ "${#LOADER_PATHS[@]}" -eq 0 ]; then
  echo "No pi-coding-agent loader.js found under ${REPO_ROOT}" >&2
  exit 1
fi

declare -A seen_inodes
UNIQUE_PATHS=()
for p in "${LOADER_PATHS[@]}"; do
  inode="$(stat -c '%i' "$p")"
  if [ -z "${seen_inodes[$inode]:-}" ]; then
    seen_inodes[$inode]=1
    UNIQUE_PATHS+=("$p")
  fi
done

PATCHED=0
for loader in "${UNIQUE_PATHS[@]}"; do
  needs_patch=0

  if grep -q 'import { getAgentDir, isBunBinary }' "$loader" 2>/dev/null; then
    needs_patch=1
  fi

  if grep -q 'isBunBinary ? { virtualModules: VIRTUAL_MODULES, tryNative: false } : { alias: getAliases() }' "$loader" 2>/dev/null; then
    needs_patch=1
  fi

  if [ "$needs_patch" -eq 0 ]; then
    if grep -q 'isBunRuntime.*tryNative.*false' "$loader" 2>/dev/null && \
       grep -q 'isBunBinary, isBunRuntime' "$loader" 2>/dev/null; then
      echo "Already patched: $loader"
      continue
    fi
  fi

  tmp="$(mktemp)"
  cp "$loader" "$tmp"

  sed -i 's|import { getAgentDir, isBunBinary }|import { getAgentDir, isBunBinary, isBunRuntime }|' "$tmp"
  sed -i 's|isBunBinary ? { virtualModules: VIRTUAL_MODULES, tryNative: false } : { alias: getAliases() }|isBunBinary ? { virtualModules: VIRTUAL_MODULES, tryNative: false } : { alias: getAliases(), ...(isBunRuntime \&\& { tryNative: false }) }|' "$tmp"

  cp "$tmp" "$loader" 2>/dev/null || sudo cp --preserve=mode,ownership "$tmp" "$loader"
  rm -f "$tmp"
  echo "Patched: $loader"
  PATCHED=$((PATCHED + 1))
done

echo "Done. Patched $PATCHED file(s)."
