# PiClaw Source Patches

Applied to the piclaw source **before building** via `git apply` (strict mode, no fuzzy matching).
The update script handles this automatically.

## Active patches

| # | File(s) | Purpose |
|---|---------|---------|
| 01 | `runtime/src/agent-pool/session.ts` | Load `~/.pi/agent/SYSTEM.md` as system prompt override |
| 02 | `runtime/src/runtime/bootstrap.ts` | Wire `broadcastEvent` to `globalThis` for extension widgets |
| 04 | `dispatch-agent.ts`, `app-extension-status.ts`, `app-sidepanel-orchestration.ts`, `app-main-action-composition.ts` | Codex stop/dismiss endpoints, web UI action handlers, `setExtensionStatusPanels` plumbing |
| 05 | `compose-box.ts` | Add `/update` and `/fast` to slash command autocomplete |
| 06 | `terminal-pane.ts`, `app-main-shell-render.ts`, `editor.css` | Terminal dock sizing/layout and standalone dock fill |
| 11 | `runtime/src/db/connection.ts` | Lazy DB init for Jiti-loaded extension module graphs |
| 15 | `compose-box.ts` | Add `/rebuild` to slash command autocomplete |

## Retired patches

Numbering preserved — next new patch is **20**.

| # | Status | Reason |
|---|--------|--------|
| ~~03~~ | Removed | Subset of 04 |
| ~~07–10~~ | Merged upstream | PRs #25, #23, #24; commit `4fcd82d` |
| ~~12–14~~ | Merged upstream | Commit `071e2f4c`, PRs #27, other |
| ~~16~~ | Retired | Dock terminal instance reuse broke reopen |
| ~~17~~ | Retired | Listener detach caused garbled redraw |
| ~~18~~ | Merged upstream | PR #31 |
| ~~19~~ | Retired | Reconnect-on-reopen too invasive |

## Terminal patch outcomes

- **06** is the only active terminal patch. Improves dock sizing but is not a perfect fix.
- **16** broke reopen by preserving the terminal instance across hide/show.
- **17** caused stale/garbled redraw artifacts after reopening.
- **19** was too invasive and did not produce a keeper.

## Verify patches

```bash
./patches/verify-patches.sh
```

## Post-install patches

In `post-install/`. Applied after `bun install` to patch dependencies (not PiClaw source).

| # | Script | Purpose |
|---|--------|---------|
| 01 | `01-jiti-trynative-bun-runtime.sh` | Disable jiti `tryNative` under Bun (fixes extension module resolution) |
| 02 | `02-context-usage-from-session-context.sh` | Context usage from session context |
