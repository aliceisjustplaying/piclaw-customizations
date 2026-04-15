# PiClaw Source Patches

Applied to the piclaw source **before building** via `git apply` (strict mode, no fuzzy matching).
The update script handles this automatically.

Automation helpers in this directory:
- `audit-upstream.sh` — classify every active patch as `needed`, `upstreamed`, `drifted`, or `blocked`
- `watch-upstream-prs.sh` — poll only opt-in upstream PRs from `manifest.json` and rerun the audit when one merges
- `manifest.json` — patch metadata; `track_upstream` is opt-in so patches with no upstream intent stay out of PR polling
- `.state/` — ignored local cache of last-seen upstream SHA and PR states

## Active patches

| # | File(s) | Purpose |
|---|---------|---------|
| 01 | `runtime/src/agent-pool/session.ts` | Load `~/.pi/agent/SYSTEM.md` as system prompt override |
| 02 | `runtime/src/runtime/bootstrap.ts` | Wire `broadcastEvent` to `globalThis` for extension widgets |
| 04 | `dispatch-agent.ts`, `app-extension-status.ts`, `app-sidepanel-orchestration.ts`, `app-main-action-composition.ts` | Codex stop/dismiss endpoints, web UI action handlers, `setExtensionStatusPanels` plumbing |
| 05 | `compose-box.ts` | Add `/update`, `/rebuild`, and `/fast` to slash command autocomplete |
| 11 | `runtime/src/db/connection.ts` | Lazy DB init for Jiti-loaded extension module graphs |
| 24 | `package.json`, `bun.lock` | Pin `ghostty-web` vendoring to the forked commit that carries the upstream bootstrap/open-reset fix |
| 28 | `provider-usage.ts`, `provider-usage.test.ts`, `compose-box.ts` | Local-only Anthropic OAuth provider usage: show 5h/week usage windows, fetch funded overage grant state, and keep extra-usage details in the model tooltip without adding them to the inline hint |
| 29 | `agent-pool.ts`, `branch-manager.ts`, `branch-seeding.ts`, `session-manager.ts`, startup/bootstrap web callers, related tests | Consolidated thread-startup performance work: reduce branch/thread switch latency, defer branch seeding, prioritize current/default chat warmup, and keep the extension-binding regression test with the session startup lane |
| 30 | `dispatch-agent.ts`, push routes/store/service, `use-notifications.ts`, `sw.js`, push client/server tests, docs | Consolidated web push and notification delivery: subscription/storage foundation, outbound delivery, Bun-safe request generation, real VAPID subject, reply notifications, source markers, and per-device per-chat delivery coordination |
| 31 | `agent-status.ts`, `channel-endpoint-facade-service.ts`, `content-endpoints.ts`, `server-timing.ts`, `request-router-service.ts`, `api.ts`, `app-perf-tracing.ts`, related tests | Correlated backend timing for hot web paths: add `Server-Timing` and request-id capture so browser-visible traces can separate backend work from client latency |
| 32 | `app-resume.ts`, `use-sse-connection.ts`, related web tests | Consolidated iOS Safari share-sheet mitigation: guarded return-to-app detection and SSE wake/focus reconnect suppression |
| 45 | `provider-usage.ts`, `runtime-facade.ts`, related tests | Fast-path `/agent/models` responses during thread opens by serving provider usage stale-while-revalidate on top of the local provider-usage patch |
| 46 | `app-chat-refresh-lifecycle.ts`, `app-refresh-coordination.ts`, related tests | Coalesce overlapping thread-switch refresh work so duplicate foreground refresh bundles collapse into one unit |
| 47 | `app-main-surface-state.ts`, related tests | Stabilize root chat resolution for direct branch opens so wrong-root route replay does not churn the UI |
| 48 | `app-agent-status-lifecycle.ts`, `app-auth-bootstrap.ts`, boot/timeline refresh orchestration files, `app-timeline-cache.ts`, related tests | Remaining local-only cold-open UI work: initial-connect gating, post-first-paint hydration ordering, bounded recent-thread timeline cache/prewarm, and the perf trace/runtime contract glue around that flow |

## Retired patches

Retired patches that are still useful for history/reference are kept under `patches/retired/`.
Numbering preserved — next new patch is **49**.

Historical note:
- the pre-consolidation split patches `29` through `44` were retired into `patches/retired/` on 2026-04-15 and first replaced by consolidated active patches `29` through `32`
- the upstreamable subset of that consolidated perf lane was then re-split on 2026-04-15 into active patches `31`, `45`, `46`, and `47`, leaving active patch `48` as the remaining local-only cold-open UI layer

| # | Status | Reason |
|---|--------|--------|
| ~~03~~ | Removed | Subset of 04 |
| ~~06~~ | Folded into 21 | Frontend terminal dock sizing/layout now rides with the popout/handoff lane |
| ~~07–10~~ | Merged upstream | PRs #25, #23, #24; commit `4fcd82d` |
| ~~12–14~~ | Merged upstream | Commit `071e2f4c`, PRs #27, other |
| ~~15~~ | Folded into 05 | Slash-command autocomplete now ships as one compose-box patch |
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
| ~~27~~ | Merged upstream | Upstream commit `581830a` |

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

## Audit upstream drift / retirement

```bash
./patches/audit-upstream.sh
./patches/audit-upstream.sh --dry-run --json
```

Behavior:
- `needed` — patch still applies forward and should stay active
- `upstreamed` — patch applies in reverse and is a retire candidate
- `drifted` — patch needs manual refresh
- `blocked` — an earlier patch drifted, so later results are intentionally withheld

## Watch tracked upstream PRs

```bash
./patches/watch-upstream-prs.sh
./patches/watch-upstream-prs.sh --dry-run --json
```

`watch-upstream-prs.sh` only polls patches marked with `"track_upstream": true` in `manifest.json`.
Use that for patches we actually intend to upstream; leave local-only patches at `false`.
When a tracked PR transitions to merged, the watcher reruns `audit-upstream.sh` immediately.
`--dry-run` skips state writes; on the PR watcher it also implies `--no-audit`.

## Post-install patches

In `post-install/`. Applied after `bun install` to patch dependencies (not PiClaw source).

| # | Script | Purpose |
|---|--------|---------|
| 01 | `01-jiti-trynative-bun-runtime.sh` | Disable jiti `tryNative` under Bun (fixes extension module resolution) |
| 02 | `02-context-usage-from-session-context.sh` | Context usage from session context |
