#!/usr/bin/env bash
# patches/post-install/03-dream-prompt-open-items-feedback.sh
#
# Reinforce Dream's responsibility to:
#   1. Capture user corrections/steering cues into `notes/memory/feedback.md`.
#   2. Produce/refresh `notes/memory/open-items.md`, a cross-day roll-up of
#      still-unresolved items harvested from each daily note's "Open items"
#      section, with entries aged / closed when later notes mark them done.
#
# We splice an extra instruction block into buildDreamPrompt()'s output array
# in both the TypeScript source and the compiled JS. Idempotent; safe to run
# on every update.
#
# Argument: $1 — candidate source root (e.g. the staged piclaw-live tree).

set -euo pipefail

ROOT="${1:-}"
if [ -z "${ROOT}" ]; then
  echo "usage: $0 <source-root>" >&2
  exit 64
fi

TS_FILE="${ROOT}/runtime/src/agent-memory/dream-prompt.ts"
JS_FILE="${ROOT}/runtime/generated/dist/agent-memory/dream-prompt.js"

python3 - "$TS_FILE" "$JS_FILE" <<'PY'
import sys, pathlib

MARKER = "DREAM_PROMPT_EXTRA_OPEN_ITEMS_FEEDBACK_V1"
ANCHOR = '"Required outputs:",'

# Each bullet is a single JS string literal inside the array.
EXTRA_LINES = [
    '',
    f'Extra durable-memory requirements ({MARKER}):',
    '- `notes/memory/feedback.md`: capture user corrections, "do not do X" steering cues, and specific workflow preferences visible in the window. One bullet per cue, dated with the first day it appeared. Do not delete older cues unless contradicted by a newer explicit cue.',
    '- `notes/memory/open-items.md`: maintain a cross-day roll-up of unresolved items harvested from each daily note "Open items" section. Mark items resolved by date when a later daily note explicitly confirms resolution. Carry forward the rest. Keep it short and scannable; one bullet per item with a date tag and the day it was last mentioned.',
    '- Both files are model-owned. Create them if missing. Add them to `notes/index.md` and to `notes/memory/MEMORY.md` when you first materialize them.',
]

def splice(path_str: str) -> None:
    path = pathlib.Path(path_str)
    if not path.exists():
        print(f"skip: {path} missing")
        return

    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"already patched: {path}")
        return

    if ANCHOR not in text:
        print(f"WARN: anchor not found in {path}; skipping")
        return

    lines = text.splitlines(keepends=True)
    out = []
    spliced = False
    for line in lines:
        out.append(line)
        if not spliced and ANCHOR in line:
            # Match the indent of the anchor line so the splice looks native.
            indent = line[: len(line) - len(line.lstrip())]
            for entry in EXTRA_LINES:
                # JS string literal with comma suffix; keep entry as one line.
                escaped = entry.replace("\\", "\\\\").replace('"', '\\"')
                out.append(f'{indent}"{escaped}",\n')
            spliced = True

    new_text = "".join(out)

    if new_text.count(ANCHOR) != text.count(ANCHOR):
        print(f"ERROR: anchor count changed unexpectedly in {path}", file=sys.stderr)
        sys.exit(1)
    if MARKER not in new_text:
        print(f"ERROR: marker missing after splice in {path}", file=sys.stderr)
        sys.exit(1)

    path.write_text(new_text, encoding="utf-8")
    print(f"patched: {path}")

for arg in sys.argv[1:]:
    splice(arg)

print("Done.")
PY
