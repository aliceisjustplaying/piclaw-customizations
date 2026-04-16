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
| 32 | `app-resume.ts`, `use-sse-connection.ts`, related web tests | Consolidated iOS Safari share-sheet mitigation: guarded return-to-app detection and SSE wake/focus reconnect suppression |
| 51 | `app-timeline-cache.ts`, `use-timeline.ts`, `app-main-timeline-composition.ts`, `app.ts`, related tests | Keep a bounded in-memory recent-thread timeline cache and best-effort nearby-thread prewarm for faster thread switches without synchronous storage writes |
| 52 | `branch-seeding.ts`, `branch-manager.ts`, `session-manager.ts`, related branch/session tests | Defer branch session seeding so branch creation persists fork context immediately and realizes the new session on first access or background warmup |
| 53 | `agent-pool.ts`, `db/messages.ts`, branch refresh endpoint/UI glue, related tests | Warm recent chats from branch refreshes so nearby chats start hydrating in the background after active-chat/branch list updates |
| 57 | `dispatch-agent.ts`, push store/routes, `use-notifications.ts`, `sw.js`, push foundation tests | Web Push subscription/storage foundation: persist subscriptions and VAPID keys, serve the service worker, and register/unregister push subscriptions from the web UI |
| 58 | presence service/routes, `notification-delivery-coordinator.ts`, `use-notifications.ts`, chat-pane/main-surface wiring, docs, related tests | Per-device per-chat notification routing: publish live client presence, elect exactly one hidden local notifier, and suppress same-chat duplicates on the active device |
| 59 | `agent-message-store.ts`, `web-push-service.ts`, `package.json`, `bun.lock`, related tests | Reply-delivery Web Push backend: add the `web-push` dependency, derive/send VAPID requests, and dispatch stored terminal replies as Web Push notifications |
| 60 | `dispatch-agent.ts`, `web-push-routes.ts`, `api.ts`, `use-notifications.ts`, route tests | Local-only push self-check endpoint: expose `/agent/push/test` and fire a one-shot confirmation notification when a device enables Web Push |
| 61 | `notification-delivery-coordinator.ts`, `app-perf-tracing.ts`, `app-timeline-cache.ts` | Replace silent catches with explicit debug logging in the remaining notification/perf helper paths so hygiene checks stay green without changing behavior |
| 62 | `agent-control-plane-service.ts` | Fix the queued-followup control-plane type so queue reorder calls still type-check after the lifecycle surface split |

## Upstream PR mapping

Snapshot:
- active stack currently first drifts at patch `52` against upstream `rcarmo/piclaw@8dec1ab`
- active patch audit status: `9 needed`, `0 upstreamed`, `1 drifted`, `6 blocked`
- open upstream PRs: `4`

| Patch | Scope | Upstream intent | PR | Status | Notes |
|---|---|---|---|---|---|
| 01 | SYSTEM.md override | Local-only | — | Active locally | Codex-at-home harness behavior; not for upstream |
| 02 | `broadcastEvent` bootstrap | Local-only | — | Active locally | Extension/widget plumbing |
| 04 | Codex web action handlers | Local-only | — | Active locally | Piclaw customization/UI integration |
| 05 | `/update` `/rebuild` `/fast` autocomplete | Local-only | — | Active locally | Custom slash commands |
| 11 | Lazy DB init for Jiti graph loading | Local-only | — | Active locally | Local runtime compatibility patch |
| 24 | Pin forked `ghostty-web` vendoring | Local-only for now | — | Active locally | Needed until upstream dependency changes |
| 28 | Anthropic OAuth provider usage | Local-only | — | Active locally | Intentionally never upstreamed |
| 32 | iOS share-sheet resume/SSE guards | Local-only for now | — | Active locally | Healthy patch, not currently in PR flow |
| 51 | Recent-thread timeline cache | Upstream | [#57](https://github.com/rcarmo/piclaw/pull/57) | Open | Standalone timeline-cache lane |
| 52 | Deferred branch session seeding | Upstream | [#51](https://github.com/rcarmo/piclaw/pull/51) | Open | Backend branch creation perf; first remaining drift in the local stack |
| 53 | Recent-branch warmup | Upstream | [#54](https://github.com/rcarmo/piclaw/pull/54) | Open | Backend/web warmup follow-up |
| 57 | Web Push subscription foundation | Upstream | [#58](https://github.com/rcarmo/piclaw/pull/58) | Open, mergeable | First patch of the web-push lane |
| 58 | Web notification presence routing | Upstream | — | Fork-stacked in [aliceisjustplaying/piclaw#13](https://github.com/aliceisjustplaying/piclaw/pull/13) | Depends on 57 conceptually; upstream PR intentionally deferred until 57 merges |
| 59 | Web Push reply delivery | Upstream | — | Fork-stacked in [aliceisjustplaying/piclaw#14](https://github.com/aliceisjustplaying/piclaw/pull/14) | Depends on 57, follows 58 operationally; upstream PR intentionally deferred |
| 60 | Push test endpoint | Local-only | — | Active locally | Diagnostic/self-check route, not marked for upstream |
| 61 | Notification/perf helper silent-catch logging cleanup | Upstream | — | Ready locally, not submitted | Narrow hygiene patch for the remaining helper paths after the PR-58 fix; no behavior change intended |
| 62 | Control-plane queue reorder type fix | Upstream | — | Ready locally, not submitted | Small compile-fix patch required after the control-plane service extraction |

## Retired patches

Retired patches that are still useful for history/reference are kept under `patches/retired/`.
Numbering preserved — next new patch is **63**.

Historical note:
- the pre-consolidation split patches `29` through `44` were retired into `patches/retired/` on 2026-04-15 and first replaced by consolidated active patches `29` through `32`
- the upstreamable subset of that consolidated perf lane was then re-split on 2026-04-15 into active patches `31`, `45`, `46`, and `47`
- the remaining cold-open UI lane was then fixed and re-split on 2026-04-15 into active patches `48`, `49`, `50`, and `51`
- the remaining consolidated startup/perf lane in active patch `29` was then retired and re-split on 2026-04-15 into active patches `52`, `53`, `54`, `55`, and `56`
- active patch `30` was then retired and re-split on 2026-04-16 into active patches `57`, `58`, `59`, and `60`
- active patch `47` then merged upstream via PR #48 and was retired on 2026-04-16
- active patch `48` was then subsumed upstream and retired on 2026-04-16
- active patch `49` then merged upstream via PR #49 and was retired on 2026-04-16
- active patch `50` then merged upstream via PR #50 and was retired on 2026-04-16
- active patch `54` then merged upstream via PR #56 and was retired on 2026-04-16
- active patch `55` then merged upstream via PR #55 and was retired on 2026-04-16
- active patch `56` then merged upstream via PR #52 and was retired on 2026-04-16
- active patch `31` then merged upstream via PR #42 and was retired on 2026-04-15
- active patch `46` then merged upstream via PR #45 and was retired on 2026-04-16
- active patch `45` then merged upstream via PR #43 and was retired on 2026-04-15

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
| ~~30~~ | Re-split | Replaced by active patches `57`, `58`, `59`, and `60`; monolith retained in `patches/retired/30-web-push-and-notification-delivery.patch` |
| ~~31~~ | Merged upstream | PR #42; upstream commit `63f3aae4` |
| ~~47~~ | Merged upstream | PR #48; upstream commit `97cae922` |
| ~~48~~ | Upstreamed/subsumed | Equivalent behavior landed on `main` by `62329116`; PR #53 left open |
| ~~49~~ | Merged upstream | PR #49; upstream commit `62329116` |
| ~~50~~ | Merged upstream | PR #50; upstream commit `054c1a62` |
| ~~54~~ | Merged upstream | PR #56; upstream commit `8dec1ab6` |
| ~~55~~ | Merged upstream | PR #55; upstream commit `a0e18a5e` |
| ~~56~~ | Merged upstream | PR #52; upstream commit `2d90e4e1` |
| ~~46~~ | Merged upstream | PR #45; upstream commit `d16b5cc` |
| ~~45~~ | Merged upstream | PR #43; upstream commit `41d6090c` |

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
