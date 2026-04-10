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
├── verify-patches.sh                   # Check patches against latest upstream
├── regenerate-patches.sh               # Regenerate patches from deployed files
└── README.md                           # Patch documentation

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

Applied to the [rcarmo/piclaw](https://github.com/rcarmo/piclaw) source tree before building. The update script handles this automatically.

| # | File | Purpose |
|---|------|---------|
| 01 | `runtime/src/agent-pool/session.ts` | Load `~/.pi/agent/SYSTEM.md` as the agent system prompt |
| 02 | `runtime/src/runtime/bootstrap.ts` | Wire `broadcastEvent` on `globalThis` for extensions |
| 03 | `runtime/src/channels/web/http/dispatch-agent.ts` | Add `/agent/codex/stop` and `/agent/codex/dismiss` HTTP endpoints |
| 04 | `runtime/web/src/ui/app-extension-status.ts` | Handle `codex.stop` and `codex.dismiss` actions in web UI |
| 05 | `runtime/web/src/components/compose-box.ts` | Add `/update` and `/fast` to slash command autocomplete (used by the installed `@benvargas/pi-openai-fast` package) |
| 06 | `runtime/web/src/panes/terminal-pane.ts`, `runtime/web/src/ui/app-main-shell-render.ts`, `runtime/web/src/ui/app-pane-runtime-orchestration.ts`, `runtime/web/static/css/editor.css` | Fix terminal dock sizing/rendering, make standalone dock fill the sidebar, and make popout→dock reattach reliable |
| 07 | `runtime/src/dream.ts`, `runtime/src/task-scheduler.ts` | Read `PICLAW_DREAM_MODEL` env var to override the model used for nightly Dream maintenance; add model switching to internal task path so Dream actually runs on the specified model (defaults to session model when unset) |

### Environment variables

| Variable | Default | Purpose |
|----------|---------|----------|
| `PICLAW_DREAM_MODEL` | *(unset — inherits session model)* | Model identifier for the nightly Dream task, e.g. `claude-sonnet-4-6` |

Set in `/etc/piclaw/piclaw.env` for systemd deployments.

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

### Installation

Copy to the PiClaw extensions directory:

```bash
mkdir -p /workspace/.pi/extensions/codex-delegate
cp extensions/codex-delegate/index.ts /workspace/.pi/extensions/codex-delegate/
cd /workspace/.pi/extensions/codex-delegate
ln -sf /home/agent/.bun/install/global/node_modules node_modules
```

## Fast Mode

Fast mode is currently provided by the third-party Pi package [`@benvargas/pi-openai-fast`](https://github.com/ben-vargas/pi-packages/tree/main/packages/pi-openai-fast), installed as a workspace extension under `/workspace/.pi/extensions/pi-openai-fast`.

### What is deployed

- Package: `@benvargas/pi-openai-fast@1.0.2`
- Slash command: `/fast`
- Config path: `/workspace/.pi/extensions/pi-openai-fast.json`
- Supported models:
  - `openai/gpt-5.4`
  - `openai-codex/gpt-5.4`

### Observed behavior on this instance

Although the Codex docs talk about `service_tier = "fast"` plus `features.fast_mode = true`, the package uses `service_tier=priority` and **this empirically worked as fast mode on `pi.mosphere.at`** with the ChatGPT/Codex OAuth setup.

So the current documented setup is:

- `/fast on` → enables the package
- `/fast off` → disables it
- `/fast status` → reports status
- when active, requests for the configured GPT-5.4 models get `service_tier=priority`

### Files in this repo

This repo vendors the package files for reproducibility:

```bash
extensions/pi-openai-fast/
configs/pi-openai-fast.json
```

### Install / wire-up

```bash
rm -rf /workspace/.pi/extensions/codex-fast-mode
mkdir -p /workspace/.pi/extensions/pi-openai-fast
cp -R extensions/pi-openai-fast/. /workspace/.pi/extensions/pi-openai-fast/
cp configs/pi-openai-fast.json /workspace/.pi/extensions/pi-openai-fast.json
ln -sf /home/agent/.bun/install/global/node_modules /workspace/.pi/extensions/pi-openai-fast/node_modules
```

After copying, restart PiClaw so the package loads.

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

Public personal automation/customization repo for a PiClaw instance.
