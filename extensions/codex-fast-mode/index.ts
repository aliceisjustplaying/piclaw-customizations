import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { ExtensionAPI, ExtensionFactory } from "@mariozechner/pi-coding-agent";

interface PersistedState {
  enabled: boolean;
}

const COMMAND_NAME = "fast";
const STATE_FILE = "/workspace/.pi/codex-fast-mode.json";

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (!value || typeof value !== "object") return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

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

function isFastCapableCodexPayload(payload: unknown): payload is Record<string, unknown> & { model: string } {
  if (!isPlainObject(payload)) return false;
  if (typeof payload.model !== "string") return false;

  const model = payload.model.trim().toLowerCase();
  if (!model.startsWith("gpt-5.4")) return false;

  // pi's OpenAI Codex provider builds a Responses-style payload with these fields.
  return Array.isArray(payload.input)
    && typeof payload.instructions === "string"
    && isPlainObject(payload.text)
    && payload.parallel_tool_calls === true;
}

function describeFastMode(enabled: boolean): string {
  return enabled
    ? "Codex Fast mode: on (applies to GPT-5.4 Codex requests only)"
    : "Codex Fast mode: off";
}

export const codexFastMode: ExtensionFactory = (pi: ExtensionAPI) => {
  let enabled = readEnabled();

  pi.on("before_provider_request", (event) => {
    if (!enabled) return;
    if (!isFastCapableCodexPayload(event.payload)) return;

    return {
      ...event.payload,
      service_tier: "fast",
    };
  });

  pi.registerCommand(COMMAND_NAME, {
    description: "Show or set Codex Fast mode (on|off|status)",
    handler: async (args, ctx) => {
      const value = args.trim().toLowerCase();

      if (!value || value === "status") {
        ctx.ui.notify(describeFastMode(enabled), "info");
        return;
      }

      if (value === "on") {
        enabled = true;
        writeEnabled(true);
        ctx.ui.notify("Codex Fast mode enabled for GPT-5.4", "info");
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
