#!/usr/bin/env bash
# Verify all patches apply cleanly to the latest piclaw source.
# Run this before any update to catch drift early.
set -euo pipefail

REPO_URL="https://github.com/rcarmo/piclaw.git"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

patch_strip_level() {
  local patch_file="$1"
  if grep -qE '^(diff --git a/|--- a/)' "$patch_file"; then
    echo 1
  else
    echo 0
  fi
}

git_apply_patch() {
  local patch_file="$1"
  shift

  local strip_level
  strip_level="$(patch_strip_level "$patch_file")"
  git apply -p"$strip_level" --recount --unidiff-zero "$@" "$patch_file"
}

echo "[verify-patches] Cloning latest source..."
git clone --depth=1 --quiet "$REPO_URL" "$WORK_DIR/piclaw"

cd "$WORK_DIR/piclaw"
all_ok=true
for p in "$PATCH_DIR"/[0-9]*.patch; do
  [ -f "$p" ] || continue
  name="$(basename "$p")"
  if git_apply_patch "$p" --check >/dev/null 2>&1; then
    git_apply_patch "$p" >/dev/null
    echo "  ✅ $name"
  else
    echo "  ❌ $name — FAILED to apply"
    git_apply_patch "$p" --check 2>&1 | head -5
    all_ok=false
  fi
done

if $all_ok; then
  echo "[verify-patches] All patches clean ✅"
  exit 0
else
  echo "[verify-patches] SOME PATCHES FAILED ❌"
  exit 1
fi
