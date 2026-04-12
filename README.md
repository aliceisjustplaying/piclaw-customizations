# piclaw-mods

Patches, extensions, and maintenance scripts for a [PiClaw](https://github.com/rcarmo/piclaw) instance.

The deployment checkout lives at `/workspace/src/piclaw-live`. For clean upstream PR work, use `/workspace/src/piclaw-fork` instead of editing the live checkout directly.

## Structure

```
patches/                          # Source patches applied before build
├── 01-session-system-prompt.patch      # Load ~/.pi/agent/SYSTEM.md as system prompt
├── 02-bootstrap-broadcast-event.patch  # Expose broadcastEvent to extensions
├── 03-dispatch-codex-endpoints.patch   # /agent/codex/stop & /dismiss endpoints
├── 04-web-codex-action-handler.patch   # Web UI action handlers for codex widgets
├── 05-web-update-autocomplete.patch    # /update and /fast in slash command autocomplete
├── 06-terminal-dock-and-popout-fixes.patch # Terminal dock sizing/rendering/reattach fixes
├── 07-dream-model-override.patch          # Dream model override via PICLAW_DREAM_MODEL env var
├── 08-webauthn-enrol-regex-fix.patch
├── 09-terminal-resolve-binaries-from-path.patch
├── 10-extension-ui-error-details.patch
├── 11-db-lazy-init-for-extension-module-graph.patch
├── 14-workspace-search-rel-scope.patch       # Keep workspace indexing path logging in scope and fix source build
├── verify-patches.sh                   # Check patches against latest upstream
├── regenerate-patches.sh               # Regenerate patches from deployed files
└── README.md                           # Patch documentation

patches/post-install/             # Post-install patches (applied inside the staged source checkout)
└── 01-jiti-trynative-bun-runtime.sh  # Fix jiti extension loading under Bun runtime

extensions/codex-delegate/        # PiClaw extension
└── index.ts                          # Multi-task Codex delegation with live widgets

extensions/pi-openai-fast/       # Installed third-party Pi extension package
├── extensions/index.ts              # Implements /fast via service_tier=priority
├── package.json
└── README.md

configs/pi-openai-fast.json      # Project config for the fast-mode package
SYSTEM.append.md                 # Durable custom instructions appended to generated SYSTEM.md

scripts/                          # Maintenance scripts
├── piclaw-update.sh                  # Full update: refresh cache → patch → build → activate live checkout
├── piclaw-rollback.sh                # Swap piclaw-live.previous back into place and restart
└── piclaw-refresh-system-prompt      # Regenerate SYSTEM.md from the live checkout
```

## Patches

### Source patches

Applied to the [rcarmo/piclaw](https://github.com/rcarmo/piclaw) source tree before building. The update script handles this automatically.

| # | File | Purpose |
|---|------|---------|
| 01 | `runtime/src/agent-pool/session.ts` | Load `~/.pi/agent/SYSTEM.md` as the agent system prompt |
| 02 | `runtime/src/runtime/bootstrap.ts` | Wire `broadcastEvent` on `globalThis` for extensions |
| 03 | `runtime/src/channels/web/http/dispatch-agent.ts` | Add `/agent/codex/stop` and `/agent/codex/dismiss` HTTP endpoints with correct chat targeting and NixOS-safe `tmux` resolution |
| 04 | `runtime/web/src/ui/app-extension-status.ts`, `runtime/web/src/ui/app-sidepanel-orchestration.ts` | Handle Codex panel actions in the web UI, send `chat_jid` on cancel, and dismiss panels locally |
| 05 | `runtime/web/src/components/compose-box.ts` | Add `/update` and `/fast` to slash command autocomplete |
| 06 | Terminal dock/popout fixes | Fix terminal dock sizing/rendering, standalone dock fill, popout→dock reattach |
| ~~07~~ | *(merged upstream — PR #25)* | |
| ~~08~~ | *(merged upstream — PR #23)* | |
| ~~09~~ | *(merged upstream — PR #24)* | |
| ~~10~~ | *(merged upstream — commit `4fcd82d`)* | |
| 11 | DB lazy init for extension module graph | Ensure Jiti-loaded extension code can initialize and use the DB singleton on first access |
| ~~12~~ | *(merged upstream — commit `071e2f4c`)* | |
| ~~13~~ | *(merged upstream — PR #27)* | |
| 14 | `runtime/src/workspace-search.ts` | Hoist `rel` outside the `try` block so unreadable-file logging still has the path and source builds do not fail |

### Post-install patches

Applied after `bun install --ignore-scripts` inside the staged source checkout. These patch dependencies rather than PiClaw source.

| # | Script | Purpose |
|---|--------|---------|
| 01 | `01-jiti-trynative-bun-runtime.sh` | Fix `pi-coding-agent` extension loader for Bun runtime |

**The jiti patch:** When PiClaw runs under Bun (non-binary), jiti's `tryNative` defaults to `true`, causing Bun's native resolver to handle imports before jiti can apply its alias map. Extensions that import `@mariozechner/*` peer dependencies fail with `Cannot find module`. The patch:
1. Adds `isBunRuntime` to the import from `config.js`
2. Sets `tryNative: false` when `isBunRuntime` is true

Patches the staged checkout's top-level `node_modules` copy and a nested `piclaw/node_modules` copy if one exists. Idempotent — safe to run on every update. Remove once fixed upstream in `pi-coding-agent`.

### Environment variables

| Variable | Default | Purpose |
|----------|---------|----------|
| `PICLAW_DREAM_MODEL` | *(unset — inherits session model)* | Model identifier for the nightly Dream task, e.g. `claude-sonnet-4-6` |

### Verifying patches

```bash
./patches/verify-patches.sh
```

### Regenerating patches from deployed code

```bash
./patches/regenerate-patches.sh
```

> **Note:** Patch 04, 05, and 06 modify web source that ships only as a compiled bundle — they can't be regenerated from deployed files, only verified against upstream.

## Codex Delegate Extension

A PiClaw extension that delegates coding tasks to [OpenAI Codex CLI](https://github.com/openai/codex) and streams live progress via status widgets in the web UI.

### Features

- **Multi-task**: Run multiple Codex tasks concurrently with independent widgets
- **Live streaming**: JSONL polling every 2s, item counts (cmds/files/msgs), token usage
- **Correct chat targeting**: Widgets attach to the active branch chat instead of falling back to `web:default`
- **NixOS-friendly binary resolution**: finds `codex`, `tmux`, and `bash` without relying on `which`
- **Cancel & dismiss**: Cancel goes through the backend; dismiss is handled locally in the web UI
- **Reattach**: Picks up running tmux sessions after restart
- **`/update` command**: One-click PiClaw update from the web UI

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
```

### Update flow

1. `refresh_source_checkout` — refresh the cached upstream clone and create a temp candidate checkout
2. `compare_versions_or_exit` — skip if up-to-date (unless `--force`)
3. `apply_source_patches` — apply numbered `.patch` files to the candidate
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
