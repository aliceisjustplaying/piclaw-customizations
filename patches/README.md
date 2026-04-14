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
| 11 | `runtime/src/db/connection.ts` | Lazy DB init for Jiti-loaded extension module graphs |
| 15 | `compose-box.ts` | Add `/rebuild` to slash command autocomplete |
| 24 | `package.json`, `bun.lock` | Pin `ghostty-web` vendoring to the forked commit that carries the upstream bootstrap/open-reset fix |
| 27 | `agent-control-helpers.ts`, `handlers/model.ts`, `compose-box.ts`, `chat.css` | Provider-scoped `max` aliasing, provider-native cycle labels, and inline query notices for blank `/thinking`/`/effort`/`/model` |
| 28 | `provider-usage.ts`, `provider-usage.test.ts`, `compose-box.ts` | Anthropic OAuth provider usage: show 5h/week usage windows, fetch funded overage grant state, and keep extra-usage details in the model tooltip without adding them to the inline hint |

## Retired patches

Retired patches that are still useful for history/reference are kept under `patches/retired/`.
Numbering preserved — next new patch is **29**.

| # | Status | Reason |
|---|--------|--------|
| ~~03~~ | Removed | Subset of 04 |
| ~~06~~ | Folded into 21 | Frontend terminal dock sizing/layout now rides with the popout/handoff lane |
| ~~07–10~~ | Merged upstream | PRs #25, #23, #24; commit `4fcd82d` |
| ~~12–14~~ | Merged upstream | Commit `071e2f4c`, PRs #27, other |
| ~~16~~ | Retired | Dock terminal instance reuse broke reopen |
| ~~17~~ | Retired | Listener detach caused garbled redraw |
| ~~18~~ | Merged upstream | PR #31 |
| ~~19~~ | Retired | Reconnect-on-reopen too invasive |
| ~~20~~ | Merged upstream | PR #35; upstream commit `146ae81b` |
| ~~21~~ | Merged upstream | PR #36; upstream commit `653bf412` |
| ~~22~~ | Merged upstream | PR #33; upstream commit `10f724be` |
| ~~23~~ | Merged upstream | PR #34; upstream commit `dee1daa1` |
| ~~25~~ | Merged upstream | PR #37; upstream commit `610dda1c` |
| ~~26~~ | Merged upstream | PR #38; upstream commit `f66f1035` |

## Terminal patch outcomes

- **20–23** are merged upstream and retired from the local patch stack.
- The upstream `ghostty-web` source patch remains separate as `ghostty-web-bootstrap-blank-on-open-reset.patch`.
- **24** is still required locally because upstream PiClaw still points at `rcarmo/ghostty-web`; it keeps vendoring pinned to the forked bootstrap-fix commit until the `ghostty-web` PR lands and PiClaw updates its dependency.
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
