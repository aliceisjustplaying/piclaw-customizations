import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { ExtensionAPI, ExtensionFactory } from "@mariozechner/pi-coding-agent";

type ServiceTier = "auto" | "default" | "flex" | "scale" | "priority";

interface PersistedState {
  service_tier: ServiceTier | null;
}

const COMMAND_NAME = "service-tier";
const STATE_FILE = "/workspace/.pi/openai-service-tier.json";
const VALID_TIERS = new Set<ServiceTier>(["auto", "default", "flex", "scale", "priority"]);

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (!value || typeof value !== "object") return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function hasOwn(value: Record<string, unknown>, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function readTier(): ServiceTier | null {
  try {
    const parsed = JSON.parse(readFileSync(STATE_FILE, "utf8")) as Partial<PersistedState>;
    return parsed.service_tier && VALID_TIERS.has(parsed.service_tier) ? parsed.service_tier : null;
  } catch {
    return null;
  }
}

function writeTier(tier: ServiceTier | null): void {
  mkdirSync(dirname(STATE_FILE), { recursive: true });
  writeFileSync(STATE_FILE, `${JSON.stringify({ service_tier: tier }, null, 2)}\n`, "utf8");
}

function isLikelyOpenAIModel(model: string): boolean {
  const normalized = model.trim().toLowerCase();
  if (!normalized || normalized.includes("/")) return false;

  return normalized.startsWith("gpt-")
    || normalized.startsWith("chatgpt-")
    || normalized.startsWith("o1")
    || normalized.startsWith("o3")
    || normalized.startsWith("o4")
    || normalized.startsWith("codex");
}

function isOpenAIPayload(payload: unknown): payload is Record<string, unknown> & { model: string } {
  if (!isPlainObject(payload)) return false;
  if (typeof payload.model !== "string") return false;
  if (!isLikelyOpenAIModel(payload.model)) return false;

  const hasMessages = hasOwn(payload, "messages");
  const hasInput = hasOwn(payload, "input");
  const hasCodexShape = hasOwn(payload, "instructions") && hasInput;
  return hasMessages || hasInput || hasCodexShape;
}

function describeTier(tier: ServiceTier | null): string {
  return tier ? `OpenAI service tier: ${tier}` : "OpenAI service tier: off";
}

export const openaiServiceTier: ExtensionFactory = (pi: ExtensionAPI) => {
  let currentTier = readTier();

  pi.on("before_provider_request", (event) => {
    if (!currentTier) return;
    if (!isOpenAIPayload(event.payload)) return;

    // Shallow clone only when we are actually injecting the request field.
    return {
      ...event.payload,
      service_tier: currentTier,
    };
  });

  pi.registerCommand(COMMAND_NAME, {
    description: "Show or set the OpenAI service tier (off|auto|default|flex|scale|priority)",
    handler: async (args, ctx) => {
      const value = args.trim().toLowerCase();

      if (!value) {
        ctx.ui.notify(describeTier(currentTier), "info");
        return;
      }

      if (value === "off") {
        currentTier = null;
        writeTier(currentTier);
        ctx.ui.notify("OpenAI service tier injection disabled", "info");
        return;
      }

      if (VALID_TIERS.has(value as ServiceTier)) {
        currentTier = value as ServiceTier;
        writeTier(currentTier);
        ctx.ui.notify(`OpenAI service tier set to ${currentTier}`, "info");
        return;
      }

      ctx.ui.notify("Usage: /service-tier [off|auto|default|flex|scale|priority]", "warning");
    },
  });
};

export default openaiServiceTier;
