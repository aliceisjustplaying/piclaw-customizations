# piclaw-customizations

Patches, extensions, and maintenance scripts for a [PiClaw](https://github.com/rcarmo/piclaw) instance.

Deployment checkout: `/workspace/src/piclaw-live`
Upstream PR work: `/workspace/src/piclaw-fork`

## Structure

```
patches/                          # Source patches applied before build
├── *.patch                       # Active source patches (see patches/README.md)
├── retired/                      # Retired patches kept for history/reference
├── post-install/                 # Post-install dependency patches
├── manifest.json                 # Patch metadata; upstream PR polling is opt-in per patch
├── audit-upstream.sh             # Classify active patches against upstream (needed/upstreamed/drifted)
├── watch-upstream-prs.sh         # Poll tracked upstream PRs and rerun the audit on merge
├── verify-patches.sh
├── regenerate-patches.sh
└── README.md

extensions/
├── codex-delegate/index.ts       # Multi-task Codex delegation with live widgets
└── pi-openai-fast/               # /fast toggle (service_tier=priority)

configs/pi-openai-fast.json       # Project config for fast-mode
SYSTEM.base.md                    # Exact text installed to ~/.pi/agent/SYSTEM.md

scripts/
├── piclaw-update.sh              # Full update: cache → patch → build → activate
├── piclaw-update-host.sh         # Host-side wrapper (systemd transient unit)
├── piclaw-verify-deploy.sh       # Verify candidate without activating
├── piclaw-rollback.sh            # Swap piclaw-live.previous back and restart
├── piclaw-rollback-host.sh       # Host-side rollback wrapper
├── piclaw-healthcheck.sh         # Post-restart health check
└── piclaw-refresh-system-prompt  # Regenerate SYSTEM.md from live checkout
```

## Patches

See [`patches/README.md`](patches/README.md) for the full patch table, retired patches, terminal patch outcomes, and upstream-audit automation.

Active source patches: `01`, `02`, `04`, `05`, `11`, `24`, `28`, `29–32`
Retired patches kept under `patches/retired/`: `06` (folded into `21`), `15` (folded into `05`), `20–23`, `25–27` (merged upstream), `29–44` (retired after consolidation into `29–32`)
Post-install patches: `01` (jiti/Bun fix), `02` (context usage)
Next available number: **45**

Upstream maintenance helpers:
- `./patches/audit-upstream.sh` audits every active patch against current upstream
- `./patches/watch-upstream-prs.sh` polls only patches with `"track_upstream": true` in `patches/manifest.json`
- local watcher/audit state is cached under ignored `patches/.state/`

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

The update script refreshes the upstream cache, applies patches with strict `git apply`, builds server + web, validates the candidate, activates it, deploys extensions, installs the fixed SYSTEM.md template, updates the global `pi-coding-agent` CLI, and updates companion CLIs.

## System Prompt

`scripts/piclaw-refresh-system-prompt` installs `SYSTEM.base.md` verbatim as `~/.pi/agent/SYSTEM.md`, with no local or repo append layers, and rewrites `~/.local/bin/pi` to prefer the live bundled CLI with a global fallback.

The single canonical `AGENTS.md` for Pix lives in `/workspace/src/pix/AGENTS.md`; `/workspace/AGENTS.md` should point to that tracked file.
