# piclaw-customizations

Patches, extensions, and maintenance scripts for a [PiClaw](https://github.com/rcarmo/piclaw) instance.

The deployment checkout lives at `/workspace/src/piclaw-live`. For clean upstream PR work, use `/workspace/src/piclaw-fork` instead of editing the live checkout directly.

## Structure

```
patches/                          # Source patches applied before build
├── 01-session-system-prompt.patch
├── 02-bootstrap-broadcast-event.patch
├── 04-web-codex-action-handler.patch
├── 05-web-update-autocomplete.patch
├── 06-terminal-dock-and-popout-fixes.patch
├── 11-db-lazy-init-for-extension-module-graph.patch
├── 15-web-rebuild-autocomplete.patch
├── verify-patches.sh
├── regenerate-patches.sh
└── README.md                     # Patch documentation and terminal patch outcomes

patches/post-install/             # Post-install patches (applied inside the staged source checkout)
├── 01-jiti-trynative-bun-runtime.sh
└── 02-context-usage-from-session-context.sh

extensions/codex-delegate/        # PiClaw extension
└── index.ts                      # Multi-task Codex delegation with live widgets

extensions/pi-openai-fast/        # Installed third-party Pi extension package
├── extensions/index.ts           # Implements /fast via service_tier=priority
├── package.json
└── README.md

configs/pi-openai-fast.json       # Project config for the fast-mode package
SYSTEM.append.md                  # Durable custom instructions appended to generated SYSTEM.md

scripts/                          # Maintenance scripts
├── piclaw-update.sh              # Full update: refresh cache → patch → build → activate
├── piclaw-update-host.sh         # Host-side wrapper (systemd transient unit)
├── piclaw-verify-deploy.sh       # Verify a candidate without activating
├── piclaw-rollback.sh            # Swap piclaw-live.previous back and restart
├── piclaw-rollback-host.sh       # Host-side rollback wrapper
├── piclaw-healthcheck.sh         # Post-restart health check
└── piclaw-refresh-system-prompt  # Regenerate SYSTEM.md from the live checkout
```

## Patches

### Source patches

Applied to the [rcarmo/piclaw](https://github.com/rcarmo/piclaw) source tree before building. The update script handles this automatically.

| # | File(s) | Purpose |
|---|---------|---------|
| 01 | `runtime/src/agent-pool/session.ts` | Load `~/.pi/agent/SYSTEM.md` as the agent system prompt |
| 02 | `runtime/src/runtime/bootstrap.ts` | Wire `broadcastEvent` on `globalThis` for extensions |
| 04 | `dispatch-agent.ts`, `app-extension-status.ts`, `app-sidepanel-orchestration.ts`, `app-main-action-composition.ts` | Codex stop/dismiss endpoints, web UI action handlers, `setExtensionStatusPanels` plumbing |
| 05 | `runtime/web/src/components/compose-box.ts` | Add `/update` and `/fast` to slash command autocomplete |
| 06 | `terminal-pane.ts`, `app-main-shell-render.ts`, `editor.css` | Terminal dock sizing/layout improvements and standalone dock fill |
| 11 | `runtime/src/db/connection.ts` | Lazy DB init for Jiti-loaded extension module graphs |
| 15 | `runtime/web/src/components/compose-box.ts` | Add `/rebuild` to slash command autocomplete |

### Retired patches

Numbering is preserved so the next new patch is **20**.

| # | Status | Reason |
|---|--------|--------|
| ~~03~~ | Removed | Was a subset of 04 |
| ~~07~~ | Merged upstream | PR #25 |
| ~~08~~ | Merged upstream | PR #23 |
| ~~09~~ | Merged upstream | PR #24 |
| ~~10~~ | Merged upstream | Commit `4fcd82d` |
| ~~12~~ | Merged upstream | Commit `071e2f4c` |
| ~~13~~ | Merged upstream | PR #27 |
| ~~14~~ | Merged upstream | — |
| ~~16~~ | Retired locally | Reusing dock terminal instance across hide/show broke reopen |
| ~~17~~ | Retired locally | Listener detach on reopen caused garbled/stale redraw |
| ~~18~~ | Merged upstream | PR #31 |
| ~~19~~ | Retired locally | Reconnect-on-reopen path was too invasive |

See `patches/README.md` for detailed terminal patch outcomes.

### Post-install patches

Applied after `bun install --ignore-scripts` inside the staged source checkout. These patch dependencies rather than PiClaw source.

| # | Script | Purpose |
|---|--------|---------|
| 01 | `01-jiti-trynative-bun-runtime.sh` | Fix jiti extension loader for Bun runtime |
| 02 | `02-context-usage-from-session-context.sh` | Context usage from session context |

**The jiti patch:** When PiClaw runs under Bun (non-binary), jiti's `tryNative` defaults to `true`, causing Bun's native resolver to handle imports before jiti can apply its alias map. Extensions that import `@mariozechner/*` peer dependencies fail with `Cannot find module`. The patch adds `isBunRuntime` to the import from `config.js` and sets `tryNative: false` when `isBunRuntime` is true. Idempotent — safe to run on every update. Remove once fixed upstream in `pi-coding-agent`.

## Codex Delegate Extension

A PiClaw extension that delegates coding tasks to [OpenAI Codex CLI](https://github.com/openai/codex) and streams live progress via status widgets in the web UI.

### Features

- **Multi-task**: Run multiple Codex tasks concurrently with independent widgets
- **Live streaming**: JSONL polling every 2s, item counts (cmds/files/msgs), token usage
- **Correct chat targeting**: Widgets attach to the active branch chat
- **NixOS-friendly binary resolution**: finds `codex`, `tmux`, and `bash` without relying on `which`
- **Cancel & dismiss**: Cancel goes through the backend; dismiss is handled locally in the web UI
- **Reattach**: Picks up running tmux sessions after restart
- **`/update` command**: One-click PiClaw update from the web UI
- **`/rebuild` command**: One-click host rebuild from the web UI

### Tools

| Tool | Description |
|------|-------------|
| `delegate_codex` | Launch a Codex task in a tmux session (defaults: `gpt-5.4`, reasoning `high`, service tier `fast`) |
| `codex_status` | Check running/completed task status |
| `codex_stop` | Stop a specific task or all tasks |

## Fast Mode

Provided by [`@benvargas/pi-openai-fast`](https://github.com/ben-vargas/pi-packages/tree/main/packages/pi-openai-fast), deployed as a workspace extension.

- Slash command: `/fast on`, `/fast off`, `/fast status`
- Config: `/workspace/.pi/extensions/pi-openai-fast.json`
- Supported models: `openai/gpt-5.4`, `openai-codex/gpt-5.4`
- Uses `service_tier=priority`

## Pi packages (npm)

Additional pi packages installed via `pi install`:

| Package | Purpose |
|---------|---------|
| `pi-web-access` | Web search via Exa, content fetching, code search |

These are managed separately from the extensions in this repo. They install to `~/.local/lib/node_modules/` (npm global prefix) and are loaded by pi-coding-agent's package resolver from `~/.pi/agent/settings.json`.

## Extension deployment

Extensions and configs are **automatically deployed** by `piclaw-update.sh`. The `deploy_custom_extensions` step:

1. Syncs each `extensions/<name>/` dir to `/workspace/.pi/extensions/<name>/` via rsync
2. Copies matching `configs/<name>.json` to `/workspace/.pi/extensions/<name>.json`
3. `wire_extension_node_modules` then symlinks `node_modules` into each extension dir

No manual `cp` or `ln` commands needed.

## Update Script

`scripts/piclaw-update.sh` handles the full lifecycle:

```bash
# Full update with restart
bash scripts/piclaw-update.sh --force

# Update without restart (caller handles restart)
bash scripts/piclaw-update.sh --force --no-restart

# Check for updates only
bash scripts/piclaw-update.sh --dry-run

# Validate without activating
bash scripts/piclaw-update.sh --force --verify-only
```

### Update flow

1. `refresh_source_checkout` — refresh the cached upstream clone and create a temp candidate checkout
2. `compare_versions_or_exit` — skip if up-to-date (unless `--force`)
3. `apply_source_patches` — apply numbered `.patch` files to the candidate with strict `git apply`
4. `build_from_source` — install deps and compile server + web UI in the candidate
5. `validate_candidate` — confirm the built assets and bundled `pi-coding-agent` files exist before activation
6. `apply_post_install_patches` — patch the candidate's local `node_modules`
7. `activate_candidate` — move the old live checkout to `piclaw-live.previous` and replace it with the new one
8. `deploy_custom_extensions` — sync extensions + configs to workspace
9. `wire_extension_node_modules` — symlink extension `node_modules` to `/workspace/src/piclaw-live/node_modules`
10. `regenerate_system_prompt` — refresh `SYSTEM.md` from the live checkout
11. `update_codex_cli` / `update_claude_cli` — update companion tools
12. `restart_service` + `verify_installation`

If dependency install, server build, or web build fails, the update script aborts before activation and leaves the current live checkout in place.

## System Prompt Script

`scripts/piclaw-refresh-system-prompt` regenerates `~/.pi/agent/SYSTEM.md` from the live checkout's `pi-coding-agent` dependency at `/workspace/src/piclaw-live/node_modules/@mariozechner/pi-coding-agent/`.

After generating the base prompt, it appends any non-empty overlay files it finds, in this order:

1. `SYSTEM.append.md` in this repo
2. `~/.pi/agent/SYSTEM.local.md`
3. `/workspace/.pi/SYSTEM.local.md`

Use `SYSTEM.append.md` for durable custom instructions you want to keep under version control in this customization repo.

## License

Public personal automation/customization repo for a PiClaw instance.
