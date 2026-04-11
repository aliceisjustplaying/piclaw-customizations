# piclaw-mods

Patches, extensions, and maintenance scripts for a [PiClaw](https://github.com/rcarmo/piclaw) instance.

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
├── verify-patches.sh                   # Check patches against latest upstream
├── regenerate-patches.sh               # Regenerate patches from deployed files
└── README.md                           # Patch documentation

patches/post-install/             # Post-install patches (applied after bun install -g)
└── 01-jiti-trynative-bun-runtime.sh  # Fix jiti extension loading under Bun runtime

extensions/codex-delegate/        # PiClaw extension
└── index.ts                          # Multi-task Codex delegation with live widgets

extensions/pi-openai-fast/       # Installed third-party Pi extension package
├── extensions/index.ts              # Implements /fast via service_tier=priority
├── package.json
└── README.md

configs/pi-openai-fast.json      # Project config for the fast-mode package

scripts/                          # Maintenance scripts
├── piclaw-update.sh                  # Full update: git pull → patch → build → install
└── piclaw-refresh-system-prompt      # Regenerate SYSTEM.md (ExecStartPre)
```

## Patches

### Source patches

Applied to the [rcarmo/piclaw](https://github.com/rcarmo/piclaw) source tree before building. The update script handles this automatically.

| # | File | Purpose |
|---|------|---------|
| 01 | `runtime/src/agent-pool/session.ts` | Load `~/.pi/agent/SYSTEM.md` as the agent system prompt |
| 02 | `runtime/src/runtime/bootstrap.ts` | Wire `broadcastEvent` on `globalThis` for extensions |
| 03 | `runtime/src/channels/web/http/dispatch-agent.ts` | Add `/agent/codex/stop` and `/agent/codex/dismiss` HTTP endpoints |
| 04 | `runtime/web/src/ui/app-extension-status.ts` | Handle `codex.stop` and `codex.dismiss` actions in web UI |
| 05 | `runtime/web/src/components/compose-box.ts` | Add `/update` and `/fast` to slash command autocomplete |
| 06 | Terminal dock/popout fixes | Fix terminal dock sizing/rendering, standalone dock fill, popout→dock reattach |
| 07 | `runtime/src/dream.ts`, `runtime/src/task-scheduler.ts` | `PICLAW_DREAM_MODEL` env var override for nightly Dream |
| 08 | WebAuthn enrol regex fix | |
| 09 | Terminal binary resolution from PATH | |

### Post-install patches

Applied after `bun install -g` to the installed `node_modules` tree. These patch dependencies rather than PiClaw source.

| # | Script | Purpose |
|---|--------|---------|
| 01 | `01-jiti-trynative-bun-runtime.sh` | Fix `pi-coding-agent` extension loader for Bun runtime |

**The jiti patch:** When PiClaw runs under Bun (non-binary), jiti's `tryNative` defaults to `true`, causing Bun's native resolver to handle imports before jiti can apply its alias map. Extensions that import `@mariozechner/*` peer dependencies fail with `Cannot find module`. The patch:
1. Adds `isBunRuntime` to the import from `config.js`
2. Sets `tryNative: false` when `isBunRuntime` is true

Patches all copies: top-level `node_modules`, `piclaw/node_modules` (nested), and bun install cache. Idempotent — safe to run on every update. Remove once fixed upstream in `pi-coding-agent`.

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
- **Cancel & dismiss**: Stop running tasks or dismiss completed widgets from the UI
- **Reattach**: Picks up running tmux sessions after restart
- **`/update` command**: One-click PiClaw update from the web UI

### Tools

| Tool | Description |
|------|-------------|
| `delegate_codex` | Launch a Codex task in a tmux session |
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

1. `refresh_source_checkout` — clone/pull piclaw source
2. `compare_versions_or_exit` — skip if up-to-date (unless `--force`)
3. `apply_source_patches` — apply numbered `.patch` files
4. `build_from_source` — compile server + web UI
5. `install_global_packages` — `bun install -g` the tarball
6. `deploy_custom_extensions` — sync extensions + configs to workspace
7. `wire_extension_node_modules` — symlink `node_modules` into extensions
8. `wire_runtime_extensions_node_modules` — symlink for runtime extensions
9. `apply_post_install_patches` — run `patches/post-install/*.sh` scripts
10. `fix_permissions` — chmod the bun install tree
11. `ensure_piclaw_symlink` — wire `/usr/local/bin/piclaw`
12. `regenerate_system_prompt` — refresh `SYSTEM.md`
13. `update_codex_cli` / `update_claude_cli` — update companion tools
14. `restart_service` + `verify_installation`

## System Prompt Script

`scripts/piclaw-refresh-system-prompt` regenerates `~/.pi/agent/SYSTEM.md` from pi-coding-agent's `buildSystemPrompt()`. Runs as `ExecStartPre` in `piclaw.service` to ensure the prompt is fresh on every restart.

## License

Public personal automation/customization repo for a PiClaw instance.
