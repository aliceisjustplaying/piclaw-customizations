# PiClaw Source Patches

These patches are applied to the piclaw source **before building**.
They must be re-applied after every `git pull` / source update.

## Patches

| # | File | Purpose |
|---|------|---------|
| 01 | `runtime/src/agent-pool/session.ts` | Load `~/.pi/agent/SYSTEM.md` as system prompt override |
| 02 | `runtime/src/runtime/bootstrap.ts` | Wire `broadcastEvent` to `globalThis.__PICLAW_BROADCAST_EVENT__` for extension widgets |
| ~~03~~ | — | Removed (was a subset of 04) |
| 04 | `runtime/src/channels/web/http/dispatch-agent.ts`, `runtime/web/src/ui/app-extension-status.ts`, `runtime/web/src/ui/app-sidepanel-orchestration.ts`, `runtime/web/src/ui/app-main-action-composition.ts` | Add `POST /agent/codex/stop` and `POST /agent/codex/dismiss` endpoints with correct chat targeting, NixOS-safe `tmux` lookup, web UI action routing with local panel dismissal, and thread `setExtensionStatusPanels` through the action composition layer |
| 05 | `runtime/web/src/components/compose-box.ts` | Add `/update` and `/fast` to slash command autocomplete |
| 06 | `runtime/web/src/panes/terminal-pane.ts`, `runtime/web/src/ui/app-main-shell-render.ts`, `runtime/web/static/css/editor.css` | Improve terminal dock sizing/layout and standalone dock fill. Keep this as the only terminal patch for now; it improves viewport behavior but still has tradeoffs. |
| ~~07~~ | — | Removed (merged upstream as PR #25) |
| ~~08~~ | — | Removed (merged upstream as PR #23) |
| ~~09~~ | — | Removed (merged upstream as PR #24) |
| ~~10~~ | — | Removed (merged upstream as commit `4fcd82d`) |
| 11 | `runtime/src/db/connection.ts` | Lazily initialize the DB on first `getDb()` access so Jiti-loaded extension module graphs share a working DB handle |
| ~~12~~ | — | Removed (merged upstream as commit `071e2f4c`) |
| ~~13~~ | — | Removed (merged upstream as PR #27) |
| ~~14~~ | — | Removed (merged upstream) |
| 15 | `runtime/web/src/components/compose-box.ts` | Add `/rebuild` to slash command autocomplete |
| ~~16~~ | — | Removed locally. Reusing the dock terminal instance across hide/show broke reopen semantics. |
| ~~17~~ | — | Removed locally. Listener detach on reopen introduced garbled/stale redraw behavior. |
| ~~18~~ | — | Removed (merged upstream as PR #31) |
| ~~19~~ | — | Removed locally. Reconnect-on-reopen path was too invasive and not worth keeping. |

## Terminal patch outcomes

- **06** is the only terminal patch still in active use. It improves dock sizing/viewport behavior, but it is not a perfect fix.
- **16** was retired after testing because preserving the dock terminal instance across hide/show broke reopen semantics.
- **17** was retired after testing because it caused garbled/stale redraw artifacts after reopening.
- **19** was retired after testing because the reconnect-on-reopen path was too invasive and did not produce a keeper.
- Keep numbering stable. The next new terminal patch should be **20**.

## Apply all patches

```bash
cd /path/to/piclaw-source
for p in /workspace/patches/[0-9]*.patch; do
  sed 's/\.orig\t/\t/g; s/\.bak\t/\t/g' "$p" | patch -p0
done
```

## Verify against latest upstream

```bash
/workspace/patches/verify-patches.sh
```

## Regenerate server-side patches from the live install

```bash
/workspace/patches/regenerate-patches.sh
```

Note: web-source patches (like 04, 05, 06, and 15) are verified against upstream source but cannot be regenerated from the compiled installed bundle.

## Workflow

1. `git pull` (or clone fresh)
2. Apply patches (above)
3. `bun install --ignore-scripts`
4. `bun run build`
5. `bun run build:web`
6. `bun pm pack` → install globally

The update script at `scripts/piclaw-update.sh` automates this.

## Post-install patches

Scripts in `post-install/` run **after** `bun install -g` to patch installed dependencies.

| # | Script | Purpose |
|---|--------|---------|
| 01 | `01-jiti-trynative-bun-runtime.sh` | Fix `pi-coding-agent` jiti extension loader for Bun runtime — adds missing `isBunRuntime` import and sets `tryNative: false` |

These are idempotent and run automatically via `apply_post_install_patches()` in the update script.
