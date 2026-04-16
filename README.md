# piclaw-customizations

Deployment tooling, extensions, post-install dependency patches, and the SYSTEM.md template for a [PiClaw](https://github.com/rcarmo/piclaw) instance.

PiClaw source customizations themselves live as commits on `pix/main` in the fork (`https://github.com/aliceisjustplaying/piclaw.git`), not as `.patch` files in this repo. See [Customizations](#customizations-branch-workflow--new-as-of-2026-04-16) below.

Deployment checkout: `/workspace/src/piclaw-live`
Fork / customization branch / upstream PR work: `/workspace/src/piclaw-fork`

## Structure

```
patches/                          # Post-install dependency patches only (source-patch workflow retired)
├── post-install/                 # Shell scripts applied after `bun install`
├── archive/                      # Historical source patches + retired tooling (informational)
└── README.md                     # Migration + common operations

extensions/
├── codex-delegate/index.ts       # Multi-task Codex delegation with live widgets
└── pi-openai-fast/               # /fast toggle (service_tier=priority)

configs/pi-openai-fast.json       # Project config for fast-mode
SYSTEM.base.md                    # Exact text installed to ~/.pi/agent/SYSTEM.md

scripts/
├── piclaw-update.sh              # Full update: clone pix/main → build → activate
├── piclaw-update-host.sh         # Host-side wrapper (systemd transient unit)
├── piclaw-ci-check.sh            # Regression gate — patch-area tests, filters baseline
├── piclaw-verify-deploy.sh       # Verify candidate without activating
├── piclaw-rollback.sh            # Swap piclaw-live.previous back and restart
├── piclaw-rollback-host.sh       # Host-side rollback wrapper
├── piclaw-healthcheck.sh         # Post-restart health check
└── piclaw-refresh-system-prompt  # Regenerate SYSTEM.md from live checkout
```

## Customizations (branch workflow — new as of 2026-04-16)

Source of truth: **`pix/main`** branch on `https://github.com/aliceisjustplaying/piclaw.git`.

Customizations live as commits on `pix/main` on top of upstream `rcarmo/piclaw@main`. The deploy path (`scripts/piclaw-update.sh`) clones `pix/main` and builds from it directly — no more `git apply` step.

Historical source patches (formerly `patches/NN-*.patch`) were migrated into commits on `pix/main` on 2026-04-16. The originals are preserved under `patches/archive/` for reference/blame only. See [`patches/README.md`](patches/README.md) for migration details and common operations.

### Common operations

```bash
# Audit customization set (commits ahead of upstream):
cd /workspace/src/piclaw-fork && git fetch upstream
git log upstream/main..pix/main --oneline

# Drop a merged-upstream customization:
git rebase -i upstream/main   # delete the subsumed commit, force-push pix/main

# Add a new customization:
git checkout pix/main && [...edits...] && git commit && git push origin pix/main

# Stage an upstream PR from an existing pix/main commit:
git checkout -b upstream-ready/NN-short-name pix/main
# cherry-pick / rebase / push; open PR against rcarmo/piclaw main
```

Local-only customizations (intentionally never upstreamed):
- `session-system-prompt` — Codex-at-home harness system prompt override
- `runtime-bootstrap` — `broadcastEvent` on globalThis for extensions
- `web: codex action handlers` — Piclaw-specific UI plumbing
- `web: slash commands` — `/update`, `/rebuild`, `/fast` autocomplete
- `db: lazy init` — Jiti-specific runtime compatibility
- `provider-usage: Anthropic OAuth` — 5h/week usage windows
- `web: iOS share-sheet` — currently not in upstream PR flow
- `web-push: /agent/push/test` — diagnostic endpoint, local-only by design

## Codex Delegate Extension

Delegates coding tasks to [OpenAI Codex CLI](https://github.com/openai/codex) via tmux, with live JSONL-based progress widgets in the web UI.

| Tool | Description |
|------|-------------|
| `delegate_codex` | Launch a Codex task (defaults: `gpt-5.4`, reasoning `high`, tier `fast`) |
| `codex_status` | Check running/completed task status |
| `codex_stop` | Stop a specific task or all tasks |

Features: multi-task, live streaming, correct chat targeting, NixOS-safe binary resolution, cancel/dismiss, tmux reattach after restart, `/update` and `/rebuild` commands.

## Fast Mode

[`@benvargas/pi-openai-fast`](https://github.com/ben-vargas/pi-packages/tree/main/packages/pi-openai-fast) — adds `service_tier=priority` to configured OpenAI models.

Commands: `/fast on`, `/fast off`, `/fast status`

## Update Script

```bash
update                        # full update with restart (uses host wrapper)
update --force --no-restart   # force update, caller handles restart
verify-deploy                 # validate candidate without activating
rollback                      # swap piclaw-live.previous back
```

What the update script actually does, in order:

1. Acquire `${STATE_DIR}/piclaw-live.update.lock` (mutex against concurrent update/rollback).
2. Fetch `pix/main` from the fork into `/workspace/.cache/piclaw-fork`, then clone it into a fresh candidate checkout under `/workspace/.tmp/piclaw-update.*`.
3. Compare the candidate's HEAD against the live tree; exit "Already up to date" if the SHAs match (overridable with `--force` / `--verify-only`).
4. Verify the candidate: `git diff --check HEAD`, no conflict markers, `session.ts` imports match the customization.
5. `bun install --ignore-scripts` + `bun run build` + `bun run build:web`, then delete `.map` files from `runtime/web/static/dist/`.
6. Assert bundle + `@mariozechner/pi-coding-agent/dist/cli.js` exist.
7. Apply post-install dependency patches (`patches/post-install/[0-9]*.sh`) against the candidate's `node_modules`.
8. Stage a new `SYSTEM.md` from `SYSTEM.base.md` via `piclaw-refresh-system-prompt`.
9. (`--verify-only` exits here.)
10. Activate: `mv piclaw-live piclaw-live.previous`, `mv candidate piclaw-live`.
11. Rsync `extensions/*/` to `/workspace/.pi/extensions`; copy matching `configs/<name>.json`; symlink each extension's `node_modules` to the live tree.
12. Install the staged `SYSTEM.md` to `~/.pi/agent/SYSTEM.md`.
13. `bun add -g @mariozechner/pi-coding-agent@latest`.
14. Print a single-line summary (version, customization-commit count, HEAD prefix).

Codex and Claude "updates" are explicit no-ops — those CLIs are Nix-managed; the script just prints their current version. On failure after step 10, the EXIT trap rolls back by swapping `piclaw-live.previous` back into place.

## Web Push / iPhone PWA

PiClaw's web-push runtime needs a real public VAPID subject in the service environment:

- `PICLAW_WEB_PUSH_VAPID_SUBJECT=https://pix.mosphere.at`
- `PICLAW_WEB_NOTIFICATION_DEBUG_LABELS=1` only if you want notification titles to show `[Local]` / `[Web Push]` while debugging; default is off

Without that, iPhone Safari PWA subscriptions can be stored successfully in `/workspace/.piclaw/web-push/subscriptions.json`, but Apple Push rejects outbound deliveries with `403 {"reason":"BadJwtToken"}`. The upstream fallback `mailto:notifications@localhost.invalid` is not sufficient for this deployment.

Current delivery behavior is per-device and per-chat:

- visible live client for that chat on a device: no notification on that device
- hidden desktop/non-iPhone live client for that chat: local notification on that device
- hidden iPhone/iPad PWA live client only: Web Push is allowed for that device
- no live client for that chat: Web Push is allowed for that device

Source of truth for the live service env is the host config in [`/workspace/src/pix/modules/piclaw.nix`](/workspace/src/pix/modules/piclaw.nix). If mobile web push stops working after a restart or rebuild, check that rendered env first:

```bash
sudo grep PICLAW_WEB_PUSH_VAPID_SUBJECT /run/secrets/rendered/piclaw-env
```

If you need to prove the issue is config rather than routing, the local-only `pix/main` diagnostic endpoint `/agent/push/test` can confirm whether a stored device subscription is deliverable.

## System Prompt

`scripts/piclaw-refresh-system-prompt` installs `SYSTEM.base.md` verbatim as `~/.pi/agent/SYSTEM.md`, with no local or repo append layers, and rewrites `~/.local/bin/pi` to prefer the live bundled CLI with a global fallback.

The single canonical `AGENTS.md` for Pix lives in `/workspace/src/pix/AGENTS.md`; `/workspace/AGENTS.md` should point to that tracked file.
