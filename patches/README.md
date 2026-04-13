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
| 20 | `terminal-session-service.ts` | Harden terminal reopen lifecycle: reconnect grace, owner-scoped handoff reuse, exact websocket/session binding, and bounded output-history replay on reattach |
| 21 | `terminal-pane.ts`, `app-pane-runtime-orchestration.ts`, `app-branch-pane-lifecycle-actions.ts` | Switch terminal popout/return to backend session handoff only, block unsafe cross-window live transfer, fix dock reattach symmetry, and inline terminal return payloads |
| 22 | `dispatch-auth.ts`, `route-flags.ts` | Add a localhost-only, internal-secret-gated E2E auth bootstrap endpoint for local browser automation |
| 23 | `package.json`, Playwright scripts | Add terminal reopen repro/stress harnesses plus a reusable local auth bootstrap client |
| 24 | `package.json`, `bun.lock` | Pin `ghostty-web` vendoring to the forked commit that carries the upstream bootstrap/open-reset fix |

## Retired patches

Numbering preserved — next new patch is **25**.

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

- **06** improves dock sizing/layout and remains the terminal layout baseline.
- **20** is the decisive backend continuity fix: quick detach/reattach windows keep the same-owner shell alive and replay bounded PTY history on reattach.
- **21** is the pane/runtime-side fix: terminal popout/return uses backend handoff only, avoids unsafe cross-window DOM transfer, and feeds the dock reattach path correctly.
- The upstream `ghostty-web` source patch remains separate as `ghostty-web-bootstrap-blank-on-open-reset.patch`.
- **22** adds the localhost-only E2E auth bootstrap endpoint used by local browser automation.
- **23** adds the Playwright harnesses used to reproduce delayed-lock and fast-reopen races.
- **24** makes the upstream `ghostty-web` fix survive clean deploys by pinning Piclaw vendoring to the forked source commit until upstream merges.
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
