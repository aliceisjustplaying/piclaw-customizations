# PiClaw Source Patches

These patches are applied to the piclaw source **before building**.
They must be re-applied after every `git pull` / source update.

## Patches

| # | File | Purpose |
|---|------|---------|
| 01 | `runtime/src/agent-pool/session.ts` | Load `~/.pi/agent/SYSTEM.md` as system prompt override |
| 02 | `runtime/src/runtime/bootstrap.ts` | Wire `broadcastEvent` to `globalThis.__PICLAW_BROADCAST_EVENT__` for extension widgets |
| 03 | `runtime/src/channels/web/http/dispatch-agent.ts` | Add `POST /agent/codex/dismiss` endpoint |
| 04 | `runtime/web/src/ui/app-extension-status.ts` | Route `codex.dismiss` panel action to the dismiss endpoint |

## Apply all patches

```bash
cd /path/to/piclaw-source
for p in /workspace/patches/[0-9]*.patch; do
  sed 's/\.orig\t/\t/g' "$p" | patch -p0
done
```

## Workflow

1. `git pull` (or clone fresh)
2. Apply patches (above)
3. `bun install --ignore-scripts`
4. `bun run build`
5. `bun run build:web`
6. `bun pm pack` → install globally

The update script at `/workspace/migrated/piclaw-update.sh` automates this.

| 05 | `runtime/web/src/components/compose-box.ts` | Add `/update` to slash command autocomplete |
