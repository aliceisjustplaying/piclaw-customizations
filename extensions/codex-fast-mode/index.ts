import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { ExtensionAPI, ExtensionFactory } from "@mariozechner/pi-coding-agent";

interface PersistedState {
  enabled: boolean;
}

const COMMAND_NAME = "fast";
const STATE_FILE = "/workspace/.pi/codex-fast-mode.json";

function readEnabled(): boolean {
  try {
    const parsed = JSON.parse(readFileSync(STATE_FILE, "utf8")) as Partial<PersistedState>;
    return parsed.enabled === true;
  } catch {
    return false;
  }
}

function writeEnabled(enabled: boolean): void {
  mkdirSync(dirname(STATE_FILE), { recursive: true });
  writeFileSync(STATE_FILE, `${JSON.stringify({ enabled }, null, 2)}\n`, "utf8");
}

function describeFastMode(enabled: boolean): string {
  return enabled
    ? "Codex Fast mode: requested, but provider injection is currently disabled pending a correct implementation"
    : "Codex Fast mode: off";
}

export const codexFastMode: ExtensionFactory = (pi: ExtensionAPI) => {
  let enabled = readEnabled();

  // Intentionally no before_provider_request hook for now.
  // A previous attempt that injected service_tier: "fast" directly caused empty/no-op replies.
  // Keep the command/state shape, but disable provider mutation until the real Codex contract is known.

  pi.registerCommand(COMMAND_NAME, {
    description: "Show Codex Fast mode status (provider injection currently disabled)",
    handler: async (args, ctx) => {
      const value = args.trim().toLowerCase();

      if (!value || value === "status") {
        ctx.ui.notify(describeFastMode(enabled), "info");
        return;
      }

      if (value === "on") {
        enabled = true;
        writeEnabled(true);
        ctx.ui.notify("Fast mode request recorded, but injection is disabled until a correct implementation is found", "warning");
        return;
      }

      if (value === "off") {
        enabled = false;
        writeEnabled(false);
        ctx.ui.notify("Codex Fast mode disabled", "info");
        return;
      }

      ctx.ui.notify("Usage: /fast [on|off|status]", "warning");
    },
  });
};

export default codexFastMode;
