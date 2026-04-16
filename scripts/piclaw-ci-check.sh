#!/usr/bin/env bash
# piclaw-ci-check.sh
#
# Regression gate for the customization stack. Runs `bun test` in the
# directories we actually touch with customizations (agent-pool, web,
# channels/web, runtime/*, db). Everything outside those dirs is pre-existing
# baseline territory (vendoring scripts, extension discovery, etc.) and has
# its own failure profile that's unrelated to customizations — we don't gate
# on it here.
#
# Usage:
#   piclaw-ci-check.sh [--live DIR] [--verbose]
#
# Defaults to /workspace/src/piclaw-live as the tree to test against. For
# pre-deploy use, point it at a candidate checkout with --live.
#
# Exit codes:
#   0  all patch-area tests passed
#   1  one or more patch-area tests failed
#   2  bun not found, tree missing, or other environment error

set -euo pipefail

LIVE_DIR="/workspace/src/piclaw-live"
VERBOSE=0

# Directories whose tests we gate on. These are the paths customizations
# have ever touched. If you add a new customization that touches a
# previously-unguarded path, add it here.
PATCH_AREA_DIRS=(
  "runtime/test/agent-pool"
  "runtime/test/web"
  "runtime/test/channels/web"
  "runtime/test/runtime"
  "runtime/test/db"
)

usage() {
  cat <<'EOF'
Usage: piclaw-ci-check.sh [--live DIR] [--verbose]

Options:
  --live DIR   Tree to test against (default: /workspace/src/piclaw-live)
  --verbose    Stream raw bun test output instead of just the summary
  -h, --help   Show this help

Runs bun test in the customization touch-areas only. Pre-existing
baseline failures elsewhere in the tree (vendoring, extension discovery,
etc.) are excluded from the gate.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --live)
      shift
      [ "$#" -gt 0 ] || { echo "--live requires a directory argument" >&2; exit 2; }
      LIVE_DIR="$1"
      ;;
    --verbose|-v)
      VERBOSE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v bun >/dev/null 2>&1; then
  echo "[ci-check] ERROR: bun not found in PATH" >&2
  exit 2
fi

if [ ! -d "${LIVE_DIR}" ]; then
  echo "[ci-check] ERROR: live tree not found: ${LIVE_DIR}" >&2
  exit 2
fi

missing=()
for dir in "${PATCH_AREA_DIRS[@]}"; do
  [ -d "${LIVE_DIR}/${dir}" ] || missing+=("${dir}")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[ci-check] ERROR: missing test directories in ${LIVE_DIR}:" >&2
  for dir in "${missing[@]}"; do echo "  - ${dir}" >&2; done
  exit 2
fi

echo "[ci-check] Running patch-area test suite"
echo "[ci-check] Tree: ${LIVE_DIR}"
echo "[ci-check] Areas:"
for dir in "${PATCH_AREA_DIRS[@]}"; do
  echo "  - ${dir}"
done
echo

cd "${LIVE_DIR}"

tmpout="$(mktemp)"
trap 'rm -f "${tmpout}"' EXIT

if [ "${VERBOSE}" -eq 1 ]; then
  bun test "${PATCH_AREA_DIRS[@]}" 2>&1 | tee "${tmpout}"
else
  bun test "${PATCH_AREA_DIRS[@]}" >"${tmpout}" 2>&1 || true
fi

summary_line="$(grep -E '^ *[0-9]+ (pass|fail|skip)' "${tmpout}" | tail -n 5 || true)"
total_line="$(grep -E '^Ran [0-9]+ tests' "${tmpout}" | tail -n 1 || true)"

# Bun prints "(fail) <title>" for individual failures. Pull them out so the
# operator sees exactly what broke.
failures="$(grep -E '^\(fail\) ' "${tmpout}" || true)"

echo
echo "[ci-check] ==== summary ===="
if [ -n "${summary_line}" ]; then
  printf '%s\n' "${summary_line}"
fi
if [ -n "${total_line}" ]; then
  printf '%s\n' "${total_line}"
fi

# Determine pass/fail by parsing "N fail" from summary.
fail_count="$(grep -oE '[0-9]+ fail' "${tmpout}" | tail -n 1 | awk '{print $1}')"
fail_count="${fail_count:-0}"

if [ "${fail_count}" -eq 0 ]; then
  echo "[ci-check] PASS — no patch-area regressions"
  exit 0
fi

echo
echo "[ci-check] FAIL — ${fail_count} patch-area test(s) failing:"
if [ -n "${failures}" ]; then
  printf '%s\n' "${failures}" | sed 's/^/  /'
else
  echo "  (see full output above or rerun with --verbose)"
fi
exit 1
