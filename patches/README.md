# PiClaw Source Patches

These patches are applied to the piclaw source **before building**.
They must be re-applied after every `git pull` / source update.

## Patches

| # | File | Purpose |
|---|------|---------|
| 01 | `runtime/src/agent-pool/session.ts` | Load `~/.pi/agent/SYSTEM.md` as system prompt override |
| 02 | `runtime/src/runtime/bootstrap.ts` | Wire `broadcastEvent` to `globalThis.__PICLAW_BROADCAST_EVENT__` for extension widgets |
| 03 | `runtime/src/channels/web/http/dispatch-agent.ts` | Add `POST /agent/codex/stop` and `POST /agent/codex/dismiss` endpoints |
| 04 | `runtime/web/src/ui/app-extension-status.ts` | Route `codex.stop` and `codex.dismiss` panel actions to the web endpoints |
| 05 | `runtime/web/src/components/compose-box.ts` | Add `/update` and `/fast` to slash command autocomplete (used by the installed `@benvargas/pi-openai-fast` package) |
| 06 | `runtime/web/src/panes/terminal-pane.ts`, `runtime/web/src/ui/app-main-shell-render.ts`, `runtime/web/src/ui/app-pane-runtime-orchestration.ts`, `runtime/web/static/css/editor.css` | Fix terminal dock sizing/rendering, make standalone dock fill the sidebar, and make popout→dock reattach reliable |
| 07 | `runtime/src/dream.ts`, `runtime/src/task-scheduler.ts` | Read `PICLAW_DREAM_MODEL` env var to override the model used for nightly Dream maintenance; add model switching to internal task path so Dream actually runs on the specified model (defaults to session model when unset) |
| 08 | `runtime/src/channels/web/auth/webauthn-enrol-page.ts` | Fix regex syntax error in passkey enrolment inline script — `\+` and `\/` inside the template literal lose their backslash, producing invalid `/+/g` and `///g` in the browser |
| 09 | `runtime/src/channels/web/terminal/terminal-session-service.ts` | Resolve `script` and `bash` from PATH instead of hardcoding `/usr/bin/` — fixes terminal on NixOS and other non-FHS distros |
| 10 | `runtime/src/channels/web/theming/ui-bridge.ts` | Show structured extension UI errors as readable details instead of `[object Object]` |

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

Note: web-source patches (like 04, 05, 06) are verified against upstream source but cannot be regenerated from the compiled installed bundle.

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
