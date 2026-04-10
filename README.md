# piclaw-mods

Patches, extensions, and maintenance scripts for a [PiClaw](https://github.com/rcarmo/piclaw) instance.

## Structure

```
patches/                          # Source patches applied before build
├── 01-session-system-prompt.patch    # Load ~/.pi/agent/SYSTEM.md as system prompt
├── 02-bootstrap-broadcast-event.patch # Expose broadcastEvent to extensions
├── 03-dispatch-codex-endpoints.patch  # /agent/codex/stop & /dismiss endpoints
├── 04-web-codex-action-handler.patch  # Web UI action handlers for codex widgets
├── 05-web-update-autocomplete.patch   # /update and /service-tier in slash command autocomplete
├── verify-patches.sh                  # Check patches against latest upstream
├── regenerate-patches.sh             # Regenerate patches from deployed files
└── README.md                          # Patch documentation

extensions/codex-delegate/        # PiClaw extension
└── index.ts                          # Multi-task Codex delegation with live widgets

extensions/openai-service-tier/   # PiClaw extension
└── index.ts                          # Injects OpenAI service_tier via /service-tier

scripts/                          # Maintenance scripts
├── piclaw-update.sh                  # Full update: git pull → patch → build → install
└── piclaw-refresh-system-prompt      # Regenerate SYSTEM.md (ExecStartPre)
```

## Patches

Applied to the [rcarmo/piclaw](https://github.com/rcarmo/piclaw) source tree before building. The update script handles this automatically.

| # | File | Purpose |
|---|------|---------|
| 01 | `runtime/src/agent-pool/session.ts` | Load `~/.pi/agent/SYSTEM.md` as the agent system prompt |
| 02 | `runtime/src/runtime/bootstrap.ts` | Wire `broadcastEvent` on `globalThis` for extensions |
| 03 | `runtime/src/channels/web/http/dispatch-agent.ts` | Add `/agent/codex/stop` and `/agent/codex/dismiss` HTTP endpoints |
| 04 | `runtime/web/src/ui/app-extension-status.ts` | Handle `codex.stop` and `codex.dismiss` actions in web UI |
| 05 | `runtime/web/src/components/compose-box.ts` | Add `/update` and `/service-tier` to slash command autocomplete |

### Verifying patches

```bash
./patches/verify-patches.sh
```

### Regenerating patches from deployed code

```bash
./patches/regenerate-patches.sh
```

> **Note:** Patch 04 and 05 modify web source that ships only as a compiled bundle — they can't be regenerated from deployed files, only verified against upstream.

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

### Installation

Copy to the PiClaw extensions directory:

```bash
mkdir -p /workspace/.pi/extensions/codex-delegate
cp extensions/codex-delegate/index.ts /workspace/.pi/extensions/codex-delegate/
cd /workspace/.pi/extensions/codex-delegate
ln -sf /home/agent/.bun/install/global/node_modules node_modules
```

## OpenAI Service Tier Extension

A PiClaw extension that persists an OpenAI `service_tier` preference and injects it into outgoing OpenAI-family payloads without patching upstream Pi/PiClaw.

### Features

- **Request hook**: Uses `before_provider_request` to add `service_tier` only to likely OpenAI payloads
- **Persistent setting**: Stores the current tier in `/workspace/.pi/openai-service-tier.json`
- **Slash command**: `/service-tier` shows or sets `off`, `auto`, `default`, `flex`, `scale`, or `priority`

### Installation

Copy to the PiClaw extensions directory:

```bash
mkdir -p /workspace/.pi/extensions/openai-service-tier
cp extensions/openai-service-tier/index.ts /workspace/.pi/extensions/openai-service-tier/
cd /workspace/.pi/extensions/openai-service-tier
ln -sf /home/agent/.bun/install/global/node_modules node_modules
```

## Update Script

`scripts/piclaw-update.sh` pulls the latest PiClaw source, applies patches, builds, and installs globally.

```bash
# Full update with restart
bash scripts/piclaw-update.sh --force

# Update without restart (caller handles restart)
bash scripts/piclaw-update.sh --force --no-restart

# Check for updates only
bash scripts/piclaw-update.sh --dry-run
```

Also updates Codex CLI and Claude CLI, and prints a summary report at the end.

## System Prompt Script

`scripts/piclaw-refresh-system-prompt` regenerates `~/.pi/agent/SYSTEM.md` from pi-coding-agent's `buildSystemPrompt()`. Runs as `ExecStartPre` in `piclaw.service` to ensure the prompt is fresh on every restart.

## License

Private — personal automation for a PiClaw instance.
