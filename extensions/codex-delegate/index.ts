import { spawnSync } from "node:child_process";
import { Database } from "bun:sqlite";
import { accessSync, constants, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { Type } from "@sinclair/typebox";
import type { AgentToolResult, ExtensionAPI, ExtensionContext, ExtensionFactory } from "@mariozechner/pi-coding-agent";

type TaskState = "running" | "completed" | "failed" | "stopped";

interface CodexUsage {
  input_tokens?: number;
  cached_input_tokens?: number;
  output_tokens?: number;
}

interface CodexItemBase {
  id?: string;
  type?: string;
  status?: string;
}

interface CodexCommandExecutionItem extends CodexItemBase {
  type?: "command_execution";
  command?: string;
  aggregated_output?: string;
  exit_code?: number;
}

interface CodexFileChange {
  path?: string;
  kind?: string;
}

interface CodexFileChangeItem extends CodexItemBase {
  type?: "file_change";
  changes?: CodexFileChange[];
}

interface CodexAgentMessageItem extends CodexItemBase {
  type?: "agent_message";
  text?: string;
}

interface CodexEvent {
  type?: string;
  thread_id?: string;
  usage?: CodexUsage;
  item?: CodexCommandExecutionItem | CodexFileChangeItem | CodexAgentMessageItem | CodexItemBase;
}

interface CodexTaskMetadata {
  id: string;
  chat_jid: string;
  task: string;
  working_dir: string;
  model: string;
  tmux_session: string;
  jsonl_path: string;
  started_at: string;
}

interface ActiveCodexTask {
  id: string;
  chatJid: string;
  task: string;
  displayName: string;
  workingDir: string;
  model: string;
  tmuxSession: string;
  jsonlPath: string;
  metadataPath: string;
  startedAt: string;
  state: TaskState;
  pollInterval: ReturnType<typeof setInterval> | null;
  lastJsonlOffset: number;
  trailingFragment: string;
  lastActivityAt: number;
  lastCompletedTurnAt: number | null;
  threadId: string | null;
  turns: number;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  commandCount: number;
  fileChangeCount: number;
  messageCount: number;
  lastEventType: string | null;
  lastMessage: string | null;
  lastCommand: string | null;
  rawTail: string[];
}

interface ExtensionStatusPanelAction {
  key: string;
  label: string;
  action_type: string;
  tone?: "default" | "danger";
}

interface ExtensionStatusPanelPayload {
  key: string;
  kind: string;
  title: string;
  collapsed_text: string;
  detail_markdown?: string;
  state?: string;
  actions?: ExtensionStatusPanelAction[];
}

interface ExtensionStatusWidgetPayload {
  chat_jid: string;
  key: string;
  content: Array<{ type: string; panel: ExtensionStatusPanelPayload }>;
  options?: Record<string, unknown>;
}

const TOOL_KEY = "codex-delegate";
const TMUX_SESSION_PREFIX = "codex-";
const POLL_INTERVAL_MS = 2_000;
const TURN_COMPLETE_IDLE_MS = 6_000;

const StartSchema = Type.Object({
  task: Type.String({ minLength: 1, description: "Task to delegate to Codex." }),
  working_dir: Type.Optional(Type.String({ description: "Directory where Codex should run. Defaults to the current workspace." })),
  model: Type.Optional(Type.String({ description: "Codex model to use. Falls back to the configured default, then o3." })),
});

const StatusSchema = Type.Object({});
const StopSchema = Type.Object({
  task_id: Type.Optional(Type.String({ minLength: 1, description: "Specific Codex task ID to stop. Stops all running tasks if omitted." })),
});

const activeTasks = new Map<string, ActiveCodexTask>();
const widgetsByChat = new Map<string, Map<string, ExtensionStatusWidgetPayload>>();
let codexWidgetBroadcast: (type: string, data: unknown) => void = () => {};

function buildResult(text: string, details: Record<string, unknown> = {}): AgentToolResult<Record<string, unknown>> {
  return {
    content: [{ type: "text", text }],
    details: { tool: TOOL_KEY, ...details },
  };
}

const MESSAGES_DB_PATH = "/workspace/.piclaw/store/messages.db";

function sanitizeChatJid(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]/g, "_");
}

function resolveChatJidFromContext(ctx?: ExtensionContext): string | null {
  if (!ctx) return null;
  try {
    const sessionDir = basename(ctx.sessionManager.getSessionDir()).split("__")[0]?.trim();
    if (!sessionDir || !existsSync(MESSAGES_DB_PATH)) return null;
    const db = new Database(MESSAGES_DB_PATH, { readonly: true });
    try {
      const rows = db.query("SELECT jid FROM chats").all() as Array<{ jid?: string }>;
      const match = rows.find((row) => typeof row.jid === "string" && sanitizeChatJid(row.jid) === sessionDir);
      return typeof match?.jid === "string" ? match.jid : null;
    } finally {
      try { db.close(); } catch { /* ignore */ }
    }
  } catch {
    return null;
  }
}

function resolveStatusChatJid(explicitChatJid?: string | null, ctx?: ExtensionContext): string {
  if (explicitChatJid?.trim()) return explicitChatJid.trim();
  const contextChatJid = resolveChatJidFromContext(ctx);
  if (contextChatJid) return contextChatJid;
  if (process.env.PICLAW_CHAT_JID?.trim()) return process.env.PICLAW_CHAT_JID.trim();
  return "web:default";
}

function resolveStateDir(): string {
  const piclawData = resolvePiclawData();
  if (piclawData) {
    return join(piclawData, "extensions", TOOL_KEY);
  }
  return join(process.cwd(), ".piclaw", TOOL_KEY);
}

function tasksDir(): string {
  return join(resolveStateDir(), "tasks");
}

function taskDir(taskId: string): string {
  return join(tasksDir(), taskId);
}

function metadataPath(taskId: string): string {
  return join(taskDir(taskId), "task.json");
}

function outputPath(taskId: string): string {
  return join(taskDir(taskId), "output.jsonl");
}

function ensureDir(path: string): void {
  mkdirSync(path, { recursive: true });
}

function shellQuote(value: string): string {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

const EXTRA_BIN_DIRS = [
  "/run/current-system/sw/bin",
  "/etc/profiles/per-user/agent/bin",
  "/home/agent/.nix-profile/bin",
  "/nix/profile/bin",
  "/home/agent/.local/bin",
  "/home/agent/.bun/bin",
];

function buildSpawnPath(): string {
  return [...new Set([...(process.env.PATH || "").split(":").filter(Boolean), ...EXTRA_BIN_DIRS])].join(":");
}

function resolveExecutable(name: string): string | null {
  for (const dir of buildSpawnPath().split(":").filter(Boolean)) {
    const candidate = `${dir}/${name}`;
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // continue
    }
  }
  return null;
}

const SPAWN_ENV = { ...process.env, PATH: buildSpawnPath() };
const TMUX_BIN = resolveExecutable("tmux");
const BASH_BIN = resolveExecutable("bash") || "bash";
const CODEX_BIN = resolveExecutable("codex");
const UPDATE_HELPER_BIN = resolveExecutable("update") || "/home/agent/.local/bin/update";
const REBUILD_HELPER_BIN = resolveExecutable("rebuild") || "/home/agent/.local/bin/rebuild";

function toolExists(name: string): boolean {
  return resolveExecutable(name) !== null;
}

function tmuxSessionExists(name: string): boolean {
  if (!TMUX_BIN) return false;
  const result = spawnSync(TMUX_BIN, ["has-session", "-t", name], { stdio: "ignore", env: SPAWN_ENV });
  return result.status === 0;
}

function summarizeTask(task: string): string {
  const singleLine = task.replace(/\s+/g, " ").trim();
  if (!singleLine) return "Task";
  return singleLine.length > 72 ? `${singleLine.slice(0, 69)}...` : singleLine;
}

function formatCompactCount(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "0";
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(value % 1_000_000 === 0 ? 0 : 1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(value % 1_000 === 0 ? 0 : 1)}k`;
  return String(Math.round(value));
}

function clipText(text: string, limit = 1_200): string {
  const trimmed = text.trim();
  if (trimmed.length <= limit) return trimmed;
  return `${trimmed.slice(0, Math.max(0, limit - 3)).trimEnd()}...`;
}

function escapeMarkdownCell(value: string): string {
  return value.replace(/\|/g, "\\|").replace(/\n/g, "<br>");
}

function formatIsoTime(timestamp: number): string {
  try {
    return new Date(timestamp).toISOString();
  } catch {
    return "unknown";
  }
}

function buildCollapsedText(task: ActiveCodexTask): string {
  const parts: string[] = [];

  // Item counts
  const counts: string[] = [];
  if (task.commandCount > 0) counts.push(`${task.commandCount} cmd${task.commandCount === 1 ? "" : "s"}`);
  if (task.fileChangeCount > 0) counts.push(`${task.fileChangeCount} file${task.fileChangeCount === 1 ? "" : "s"}`);
  if (task.messageCount > 0) counts.push(`${task.messageCount} msg${task.messageCount === 1 ? "" : "s"}`);
  if (counts.length > 0) {
    parts.push(counts.join(", "));
  }

  // Token usage
  if (task.inputTokens > 0 || task.outputTokens > 0) {
    parts.push(`↑${formatCompactCount(task.inputTokens)} ↓${formatCompactCount(task.outputTokens)}`);
  }

  // Show live activity
  if (task.lastCommand) {
    const cmd = task.lastCommand.replace(/^\/bin\/bash -lc /, "").slice(0, 60);
    parts.push(`$ ${cmd}${task.lastCommand.length > 60 ? "…" : ""}`);
  } else if (task.lastMessage) {
    parts.push(task.lastMessage.slice(0, 60) + (task.lastMessage.length > 60 ? "…" : ""));
  } else if (task.state === "running") {
    parts.push("starting…");
  }
  return parts.join(" | ");
}

function widgetKey(taskOrId: ActiveCodexTask | string): string {
  const taskId = typeof taskOrId === "string" ? taskOrId : taskOrId.id;
  return `codex-${taskId}`;
}

function buildDetailMarkdown(task: ActiveCodexTask, state: TaskState, reason?: string | null): string {
  const lines = [
    "| Field | Value |",
    "|---|---|",
    `| State | **${state}** |`,
    `| Task ID | \`${task.id}\` |`,
    `| Items | **${task.commandCount}** cmds, **${task.fileChangeCount}** files, **${task.messageCount}** msgs |`,
    `| Tokens | ↑${formatCompactCount(task.inputTokens)} / ↓${formatCompactCount(task.outputTokens)} |`,
    task.cachedInputTokens > 0 ? `| Cached input | ${formatCompactCount(task.cachedInputTokens)} |` : "",
    task.threadId ? `| Thread ID | \`${escapeMarkdownCell(task.threadId)}\` |` : "",
    `| Model | \`${escapeMarkdownCell(task.model)}\` |`,
    `| Working dir | \`${escapeMarkdownCell(task.workingDir)}\` |`,
    `| tmux | \`${escapeMarkdownCell(task.tmuxSession)}\` |`,
    `| Log | \`${escapeMarkdownCell(task.jsonlPath)}\` |`,
    `| Started | ${escapeMarkdownCell(task.startedAt)} |`,
    `| Last activity | ${escapeMarkdownCell(formatIsoTime(task.lastActivityAt))} |`,
    reason ? `| Reason | ${escapeMarkdownCell(reason)} |` : "",
  ].filter(Boolean);

  const detailBlocks = [lines.join("\n")];

  if (task.lastMessage) {
    detailBlocks.push(`**Last agent message**\n\n${clipText(task.lastMessage, 1_500)}`);
  }

  if (task.rawTail.length > 0) {
    detailBlocks.push(`**Raw output tail**\n\n\`\`\`\n${clipText(task.rawTail.join("\n"), 1_200)}\n\`\`\``);
  }

  return detailBlocks.join("\n\n");
}

function buildWidgetPayload(task: ActiveCodexTask, state: TaskState, reason?: string | null): ExtensionStatusWidgetPayload {
  const key = widgetKey(task);
  return {
    chat_jid: task.chatJid,
    key,
    content: [{
      type: "status_panel",
      panel: {
        key,
        kind: "chart_status",
        title: `Codex: ${task.displayName}`,
        collapsed_text: buildCollapsedText(task),
        detail_markdown: buildDetailMarkdown(task, state, reason),
        state,
        actions: state === "running"
          ? [{ key: "stop", label: "Cancel", action_type: `codex.stop.${task.id}`, tone: "danger" }]
          : [{ key: "dismiss", label: "Dismiss", action_type: `codex.dismiss.${task.id}` }],
      },
    }],
    options: {
      surface: "status-panel",
      state,
    },
  };
}

function clearStatusPanel(broadcastEvent: (type: string, data: unknown) => void, task: ActiveCodexTask): void {
  const key = widgetKey(task);
  const chatWidgets = widgetsByChat.get(task.chatJid);
  chatWidgets?.delete(key);
  if (chatWidgets && chatWidgets.size === 0) {
    widgetsByChat.delete(task.chatJid);
  }
  broadcastEvent("extension_ui_widget", {
    chat_jid: task.chatJid,
    key,
    content: [],
    options: { surface: "status-panel", remove: true },
  });
}

function emitStatus(
  broadcastEvent: (type: string, data: unknown) => void,
  task: ActiveCodexTask | null,
  state: TaskState,
  reason?: string | null,
): void {
  try {
    if (!task) return;
    const widget = buildWidgetPayload(task, state, reason);
    let chatWidgets = widgetsByChat.get(task.chatJid);
    if (!chatWidgets) {
      chatWidgets = new Map<string, ExtensionStatusWidgetPayload>();
      widgetsByChat.set(task.chatJid, chatWidgets);
    }
    chatWidgets.set(widget.key, widget);
    const isBound = broadcastEvent !== _noopBroadcast;
    console.error(`[codex-delegate:emit] state=${state} turns=${task.turns} tokens=↑${task.inputTokens}↓${task.outputTokens} broadcastBound=${isBound} chatJid=${task.chatJid}`);
    broadcastEvent("extension_ui_widget", widget);
  } catch (err) {
    console.error(`[codex-delegate:emit] ERROR: ${err}`);
    // Best effort only.
  }
}

function resolvePiclawData(): string | null {
  if (process.env.PICLAW_DATA?.trim()) return process.env.PICLAW_DATA.trim();
  // Fallback: detect from workspace
  const candidates = [
    join(process.cwd(), ".piclaw", "data"),
    "/workspace/.piclaw/data",
  ];
  for (const c of candidates) {
    if (existsSync(join(c, "ipc"))) return c;
  }
  return null;
}

function buildMessageFilePath(): string | null {
  const piclawData = resolvePiclawData();
  if (!piclawData) return null;
  const dir = join(piclawData, "ipc", "messages");
  ensureDir(dir);
  return join(dir, `msg_${Date.now()}_${Math.random().toString(36).slice(2, 8)}.json`);
}

function postTimelineMessage(chatJid: string, text: string): void {
  const messagePath = buildMessageFilePath();
  if (!messagePath) return;
  try {
    writeFileSync(
      messagePath,
      JSON.stringify({ type: "message", chatJid, text }) + "\n",
      "utf-8",
    );
  } catch {
    // Best effort only.
  }
}

function rememberRawLines(task: ActiveCodexTask, rawLines: string[]): void {
  const normalized = rawLines.map((line) => line.trim()).filter(Boolean);
  if (normalized.length === 0) return;
  task.rawTail = [...task.rawTail, ...normalized].slice(-10);
}

function readLogDelta(task: ActiveCodexTask): {
  events: CodexEvent[];
  rawLines: string[];
  newOffset: number;
  trailingFragment: string;
} {
  if (!existsSync(task.jsonlPath)) {
    return {
      events: [],
      rawLines: [],
      newOffset: task.lastJsonlOffset,
      trailingFragment: task.trailingFragment,
    };
  }

  try {
    const contents = readFileSync(task.jsonlPath, "utf-8");
    const offset = contents.length < task.lastJsonlOffset ? 0 : task.lastJsonlOffset;
    const slice = contents.slice(offset);
    const combined = `${task.trailingFragment}${slice}`;
    if (!combined) {
      return {
        events: [],
        rawLines: [],
        newOffset: contents.length,
        trailingFragment: task.trailingFragment,
      };
    }

    const lines = combined.split("\n");
    const trailingFragment = combined.endsWith("\n") ? "" : (lines.pop() || "");
    const parsedEvents: CodexEvent[] = [];
    const rawLines: string[] = [];

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        parsedEvents.push(JSON.parse(trimmed) as CodexEvent);
      } catch {
        rawLines.push(trimmed);
      }
    }

    return {
      events: parsedEvents,
      rawLines,
      newOffset: contents.length,
      trailingFragment,
    };
  } catch {
    return {
      events: [],
      rawLines: [],
      newOffset: task.lastJsonlOffset,
      trailingFragment: task.trailingFragment,
    };
  }
}

function readAllEvents(jsonlPath: string): { events: CodexEvent[]; rawLines: string[]; size: number } {
  if (!existsSync(jsonlPath)) return { events: [], rawLines: [], size: 0 };
  try {
    const contents = readFileSync(jsonlPath, "utf-8");
    const events: CodexEvent[] = [];
    const rawLines: string[] = [];

    for (const line of contents.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        events.push(JSON.parse(trimmed) as CodexEvent);
      } catch {
        rawLines.push(trimmed);
      }
    }

    return { events, rawLines, size: contents.length };
  } catch {
    return { events: [], rawLines: [], size: 0 };
  }
}

function resetDerivedState(task: ActiveCodexTask): void {
  task.threadId = null;
  task.turns = 0;
  task.inputTokens = 0;
  task.cachedInputTokens = 0;
  task.outputTokens = 0;
  task.commandCount = 0;
  task.fileChangeCount = 0;
  task.messageCount = 0;
  task.lastEventType = null;
  task.lastMessage = null;
  task.lastCommand = null;
  task.lastCompletedTurnAt = null;
  task.rawTail = [];
}

function summarizeFileChanges(changes: CodexFileChange[] | undefined): string {
  if (!Array.isArray(changes) || changes.length === 0) return "Updated files.";
  return changes
    .slice(0, 8)
    .map((change) => `${change.kind || "modified"} ${change.path || "unknown"}`)
    .join(", ");
}

const _noopBroadcast = () => {};

function applyEvent(task: ActiveCodexTask, event: CodexEvent, _emitTimeline: boolean): void {
  console.error(`[codex-delegate:event] type=${event.type} itemType=${event.item?.type || '-'}`);
  task.lastEventType = event.type || task.lastEventType;

  if (event.type === "thread.started") {
    task.threadId = typeof event.thread_id === "string" ? event.thread_id : task.threadId;
    return;
  }

  if (event.type === "turn.started") {
    return;
  }

  if (event.type === "turn.completed") {
    task.turns += 1;
    task.inputTokens += Number(event.usage?.input_tokens || 0);
    task.cachedInputTokens += Number(event.usage?.cached_input_tokens || 0);
    task.outputTokens += Number(event.usage?.output_tokens || 0);
    task.lastCompletedTurnAt = Date.now();
    return;
  }

  if (event.type !== "item.started" && event.type !== "item.completed") return;

  const item = event.item;
  if (!item?.type) return;

  if (event.type === "item.started" && item.type === "command_execution") {
    const command = (item as CodexCommandExecutionItem).command?.trim();
    if (!command) return;
    task.lastCommand = command;
    return;
  }

  if (event.type === "item.completed" && item.type === "agent_message") {
    task.messageCount += 1;
    const message = (item as CodexAgentMessageItem).text?.trim();
    if (!message) return;
    task.lastMessage = message;
    return;
  }

  if (event.type === "item.completed" && item.type === "command_execution") {
    task.commandCount += 1;
    const commandItem = item as CodexCommandExecutionItem;
    task.lastCommand = commandItem.command?.trim() || task.lastCommand;
    return;
  }

  if (event.type === "item.completed" && item.type === "file_change") {
    const changeItem = item as CodexFileChangeItem;
    task.fileChangeCount += (changeItem.changes?.length || 1);
    return;
  }
}

function rehydrateTaskFromLog(task: ActiveCodexTask): void {
  resetDerivedState(task);
  const { events, rawLines, size } = readAllEvents(task.jsonlPath);
  for (const event of events) applyEvent(task, event, false);
  rememberRawLines(task, rawLines);
  task.lastJsonlOffset = size;
  task.trailingFragment = "";
  if (existsSync(task.jsonlPath)) {
    task.lastActivityAt = statSync(task.jsonlPath).mtimeMs || task.lastActivityAt;
  }
}

function flushTaskLog(
  task: ActiveCodexTask,
  broadcastEvent: (type: string, data: unknown) => void,
  emitTimeline: boolean,
): boolean {
  const delta = readLogDelta(task);
  task.lastJsonlOffset = delta.newOffset;
  task.trailingFragment = delta.trailingFragment;

  if (delta.events.length === 0 && delta.rawLines.length === 0) return false;

  task.lastActivityAt = Date.now();
  rememberRawLines(task, delta.rawLines);

  for (const event of delta.events) {
    applyEvent(task, event, emitTimeline);
  }

  emitStatus(broadcastEvent, task, task.state);
  return true;
}

function finalStateForExitedTask(task: ActiveCodexTask): TaskState {
  if (task.state === "stopped") return "stopped";
  if (task.lastEventType === "turn.completed" || task.turns > 0) return "completed";
  return "failed";
}

function buildFinalTimelineMessage(task: ActiveCodexTask, state: TaskState, reason?: string | null): string {
  const parts = [
    `Codex ${state}: ${task.displayName}`,
    `Items: ${task.commandCount} cmds, ${task.fileChangeCount} files, ${task.messageCount} msgs`,
    `Tokens: ↑${formatCompactCount(task.inputTokens)} ↓${formatCompactCount(task.outputTokens)}`,
    task.lastMessage ? `Summary: ${clipText(task.lastMessage, 500)}` : "",
    reason ? `Reason: ${reason}` : "",
  ].filter(Boolean);
  return parts.join("\n");
}

function stopPolling(task: ActiveCodexTask): void {
  if (!task.pollInterval) return;
  clearInterval(task.pollInterval);
  task.pollInterval = null;
}

function finalizeTask(
  task: ActiveCodexTask,
  state: TaskState,
  broadcastEvent: (type: string, data: unknown) => void,
  options: { reason?: string | null; postTimeline?: boolean } = {},
): void {
  stopPolling(task);
  task.state = state;
  emitStatus(broadcastEvent, task, state, options.reason ?? null);
  if (options.postTimeline !== false) {
    if (state === "completed" || state === "failed") {
      postTimelineMessage(task.chatJid, buildFinalTimelineMessage(task, state, options.reason ?? null));
    }
  }
  if (tmuxSessionExists(task.tmuxSession)) {
    spawnSync(TMUX_BIN || "tmux", ["kill-session", "-t", task.tmuxSession], { stdio: "ignore", env: SPAWN_ENV });
  }
  activeTasks.delete(task.id);
}

function writeMetadata(task: ActiveCodexTask): void {
  const metadata: CodexTaskMetadata = {
    id: task.id,
    chat_jid: task.chatJid,
    task: task.task,
    working_dir: task.workingDir,
    model: task.model,
    tmux_session: task.tmuxSession,
    jsonl_path: task.jsonlPath,
    started_at: task.startedAt,
  };
  ensureDir(taskDir(task.id));
  writeFileSync(task.metadataPath, JSON.stringify(metadata, null, 2) + "\n", "utf-8");
}

function readMetadata(taskId: string): CodexTaskMetadata | null {
  try {
    const path = metadataPath(taskId);
    if (!existsSync(path)) return null;
    const parsed = JSON.parse(readFileSync(path, "utf-8"));
    return parsed && typeof parsed === "object" ? parsed as CodexTaskMetadata : null;
  } catch {
    return null;
  }
}

function buildTaskStatusText(task: ActiveCodexTask): string {
  const parts = [
    `Task: ${task.id}`,
    `State: ${task.state}`,
    `Items: ${task.commandCount} cmds, ${task.fileChangeCount} files, ${task.messageCount} msgs`,
    `Tokens: ↑${task.inputTokens} ↓${task.outputTokens}` + (task.cachedInputTokens > 0 ? ` (cached ${task.cachedInputTokens})` : ""),
    `Last activity: ${formatIsoTime(task.lastActivityAt)}`,
    `tmux: ${task.tmuxSession}`,
    `Working dir: ${task.workingDir}`,
  ];
  return parts.join("\n");
}

function buildTaskFromMetadata(
  id: string,
  metadata: CodexTaskMetadata | null,
  tmuxSession: string,
  workingDir: string,
  jsonlPath: string,
): ActiveCodexTask {
  return {
    id,
    chatJid: metadata?.chat_jid || resolveStatusChatJid(),
    task: metadata?.task || basename(workingDir),
    displayName: summarizeTask(metadata?.task || basename(workingDir)),
    workingDir,
    model: metadata?.model || defaultModel(),
    tmuxSession,
    jsonlPath,
    metadataPath: metadataPath(id),
    startedAt: metadata?.started_at || new Date().toISOString(),
    state: "running",
    pollInterval: null,
    lastJsonlOffset: 0,
    trailingFragment: "",
    lastActivityAt: Date.now(),
    lastCompletedTurnAt: null,
    threadId: null,
    turns: 0,
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    commandCount: 0,
    fileChangeCount: 0,
    messageCount: 0,
    lastEventType: null,
    lastMessage: null,
    lastCommand: null,
    rawTail: [],
  };
}

function collectTaskDetails(task: ActiveCodexTask): Record<string, unknown> {
  return {
    task_id: task.id,
    state: task.state,
    turns: task.turns,
    input_tokens: task.inputTokens,
    cached_input_tokens: task.cachedInputTokens,
    output_tokens: task.outputTokens,
    last_activity: formatIsoTime(task.lastActivityAt),
    log_path: task.jsonlPath,
    tmux_session: task.tmuxSession,
    working_dir: task.workingDir,
    model: task.model,
  };
}

function defaultModel(): string {
  return process.env.PICLAW_CODEX_DELEGATE_MODEL?.trim()
    || process.env.CODEX_DELEGATE_MODEL?.trim()
    || "gpt-5.4";
}

function defaultReasoningEffort(): string {
  return process.env.PICLAW_CODEX_DELEGATE_REASONING_EFFORT?.trim()
    || process.env.CODEX_DELEGATE_REASONING_EFFORT?.trim()
    || "high";
}

function defaultServiceTier(): string {
  return process.env.PICLAW_CODEX_DELEGATE_SERVICE_TIER?.trim()
    || process.env.CODEX_DELEGATE_SERVICE_TIER?.trim()
    || "fast";
}

function startPollingTask(taskId: string, broadcastEvent: (type: string, data: unknown) => void): void {
  const logPoll = (msg: string) => { try { console.error(`[codex-delegate:poll] ${msg}`); } catch {} };
  const initialTask = activeTasks.get(taskId);
  if (!initialTask) return;
  if (initialTask.pollInterval) {
    logPoll(`Poller already active for ${initialTask.id}, skipping`);
    return;
  }
  logPoll(`Starting poller for ${initialTask.id}, jsonl=${initialTask.jsonlPath}`);
  initialTask.pollInterval = setInterval(() => {
    const task = activeTasks.get(taskId);
    if (!task) { logPoll(`task missing: ${taskId}`); return; }

    const tmuxAlive = tmuxSessionExists(task.tmuxSession);
    if (!tmuxAlive) {
      logPoll(`tmux gone for ${task.id}, flushing final log`);
      stopPolling(task);
      flushTaskLog(task, broadcastEvent, true);
      finalizeTask(task, finalStateForExitedTask(task), broadcastEvent, { reason: "process_exited" });
      return;
    }

    const changed = flushTaskLog(task, broadcastEvent, true);
    logPoll(`tick: tmux=alive changed=${changed} turns=${task.turns} tokens=↑${task.inputTokens}↓${task.outputTokens} offset=${task.lastJsonlOffset}`);
    if (!changed && task.lastCompletedTurnAt && Date.now() - task.lastCompletedTurnAt >= TURN_COMPLETE_IDLE_MS) {
      logPoll(`idle timeout for ${task.id}`);
      stopPolling(task);
      finalizeTask(task, "completed", broadcastEvent, { reason: "turn_completed_idle" });
    }
  }, POLL_INTERVAL_MS);
}

async function delegateCodex(
  params: { task: string; working_dir?: string; model?: string },
  broadcastEvent: (type: string, data: unknown) => void,
  ctx?: ExtensionContext,
): Promise<AgentToolResult<Record<string, unknown>>> {
  if (!toolExists("codex")) return buildResult("❌ codex CLI not found.");
  if (!toolExists("tmux")) return buildResult("❌ tmux not found.");

  const workingDir = resolve(params.working_dir || process.cwd());
  if (!existsSync(workingDir)) {
    return buildResult(`❌ Working directory does not exist: ${workingDir}`);
  }

  const id = `task-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  const tmuxSession = `${TMUX_SESSION_PREFIX}${id}`;
  const jsonlPath = outputPath(id);
  const taskMetadataPath = metadataPath(id);
  const model = params.model?.trim() || defaultModel();
  const reasoningEffort = defaultReasoningEffort();
  const serviceTier = defaultServiceTier();
  const chatJid = resolveStatusChatJid(null, ctx);
  const startedAt = new Date().toISOString();
  const displayName = summarizeTask(params.task);

  ensureDir(taskDir(id));

  const shellCommand = [
    `${shellQuote(CODEX_BIN || "codex")} exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check`,
    `-m ${shellQuote(model)}`,
    `-c ${shellQuote(`model_reasoning_effort=${reasoningEffort}`)}`,
    `-c ${shellQuote(`service_tier=${serviceTier}`)}`,
    `-C ${shellQuote(workingDir)}`,
    shellQuote(params.task),
    `> ${shellQuote(jsonlPath)} 2>&1`,
  ].join(" ");

  const task: ActiveCodexTask = {
    id,
    chatJid,
    task: params.task,
    displayName,
    workingDir,
    model,
    tmuxSession,
    jsonlPath,
    metadataPath: taskMetadataPath,
    startedAt,
    state: "running",
    pollInterval: null,
    lastJsonlOffset: 0,
    trailingFragment: "",
    lastActivityAt: Date.now(),
    lastCompletedTurnAt: null,
    threadId: null,
    turns: 0,
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    commandCount: 0,
    fileChangeCount: 0,
    messageCount: 0,
    lastEventType: null,
    lastMessage: null,
    lastCommand: null,
    rawTail: [],
  };

  writeMetadata(task);

  const tmuxResult = spawnSync(
    TMUX_BIN || "tmux",
    ["new-session", "-d", "-s", tmuxSession, BASH_BIN, "-lc", shellCommand],
    { stdio: "ignore", env: SPAWN_ENV },
  );

  if (tmuxResult.status !== 0) {
    return buildResult(`❌ Failed to create tmux session (exit ${tmuxResult.status ?? "?"}).`);
  }

  activeTasks.set(task.id, task);
  // No timeline spam — widget handles live status
  emitStatus(broadcastEvent, task, "running");
  startPollingTask(task.id, broadcastEvent);

  return buildResult(
    [
      `Codex task launched.`,
      `Task ID: ${id}`,
      `State: running`,
      `tmux: ${tmuxSession}`,
      `Working dir: ${workingDir}`,
      `Model: ${model}`,
      `Reasoning: ${reasoningEffort}`,
      `Service tier: ${serviceTier}`,
      `Log: ${jsonlPath}`,
    ].join("\n"),
    {
      task_id: id,
      state: "running",
      tmux_session: tmuxSession,
      working_dir: workingDir,
      model,
      reasoning_effort: reasoningEffort,
      service_tier: serviceTier,
      log_path: jsonlPath,
    },
  );
}

async function codexStatus(
  broadcastEvent: (type: string, data: unknown) => void,
): Promise<AgentToolResult<Record<string, unknown>>> {
  if (activeTasks.size === 0) {
    return buildResult("No Codex task is currently running.", { active: false });
  }

  const statusLines: string[] = [];
  const tasks: Record<string, unknown>[] = [];

  for (const task of activeTasks.values()) {
    if (!tmuxSessionExists(task.tmuxSession)) {
      stopPolling(task);
      flushTaskLog(task, broadcastEvent, false);
      finalizeTask(task, finalStateForExitedTask(task), broadcastEvent, { reason: "process_exited", postTimeline: false });
      statusLines.push(buildTaskStatusText(task));
      tasks.push({ active: false, ...collectTaskDetails(task) });
      continue;
    }

    flushTaskLog(task, broadcastEvent, false);
    emitStatus(broadcastEvent, task, "running");
    statusLines.push(buildTaskStatusText(task));
    tasks.push({ active: true, ...collectTaskDetails(task) });
  }

  return buildResult(statusLines.join("\n\n"), {
    active: activeTasks.size > 0,
    task_count: tasks.length,
    tasks,
  });
}

async function stopCodex(
  params: { task_id?: string },
  broadcastEvent: (type: string, data: unknown) => void,
): Promise<AgentToolResult<Record<string, unknown>>> {
  if (activeTasks.size === 0) {
    return buildResult("No Codex task is currently running.", { active: false });
  }

  const tasksToStop = params.task_id?.trim()
    ? [activeTasks.get(params.task_id.trim())].filter((task): task is ActiveCodexTask => Boolean(task))
    : [...activeTasks.values()];

  if (tasksToStop.length === 0) {
    return buildResult(`No Codex task found for task_id=${params.task_id?.trim() || ""}.`, { active: activeTasks.size > 0 });
  }

  const stoppedText: string[] = [];
  const stoppedTasks: Record<string, unknown>[] = [];

  for (const task of tasksToStop) {
    stopPolling(task);

    if (tmuxSessionExists(task.tmuxSession)) {
      spawnSync(TMUX_BIN || "tmux", ["send-keys", "-t", task.tmuxSession, "C-c", ""], { stdio: "ignore", env: SPAWN_ENV });
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 1_500));
      flushTaskLog(task, broadcastEvent, false);
      if (tmuxSessionExists(task.tmuxSession)) {
        spawnSync(TMUX_BIN || "tmux", ["kill-session", "-t", task.tmuxSession], { stdio: "ignore", env: SPAWN_ENV });
      }
    }

    flushTaskLog(task, broadcastEvent, false);
    finalizeTask(task, "stopped", broadcastEvent, { reason: "user_stopped" });

    stoppedText.push(
      [
        `Codex task stopped.`,
        `Task ID: ${task.id}`,
        `State: stopped`,
        `Items: ${task.commandCount} cmds, ${task.fileChangeCount} files, ${task.messageCount} msgs`,
        `Tokens: ↑${task.inputTokens} ↓${task.outputTokens}` + (task.cachedInputTokens > 0 ? ` (cached ${task.cachedInputTokens})` : ""),
        task.lastMessage ? `Last message: ${clipText(task.lastMessage, 500)}` : "",
        `Log: ${task.jsonlPath}`,
      ].filter(Boolean).join("\n"),
    );
    stoppedTasks.push({ active: false, ...collectTaskDetails(task) });
  }

  return buildResult(stoppedText.join("\n\n"), {
    active: activeTasks.size > 0,
    stopped_count: stoppedTasks.length,
    tasks: stoppedTasks,
  });
}

export async function stopCodexFromWeb(taskId?: string | null): Promise<AgentToolResult<Record<string, unknown>>> {
  return stopCodex({ task_id: taskId || undefined }, codexWidgetBroadcast);
}

export function getCodexDelegateWidgetPayload(chatJid?: string | null): ExtensionStatusWidgetPayload[] {
  const normalizedChatJid = typeof chatJid === "string" && chatJid.trim() ? chatJid.trim() : null;
  const widgets = [...activeTasks.values()]
    .filter((task) => !normalizedChatJid || task.chatJid === normalizedChatJid)
    .map((task) => buildWidgetPayload(task, task.state));
  if (widgets.length > 0) return widgets;
  if (!normalizedChatJid) {
    return [...widgetsByChat.values()].flatMap((chatWidgets) => [...chatWidgets.values()]);
  }
  return [...(widgetsByChat.get(normalizedChatJid)?.values() || [])];
}

function reattachExistingTask(broadcastEvent: (type: string, data: unknown) => void): void {
  if (!toolExists("tmux")) return;

  try {
    const result = spawnSync(TMUX_BIN || "tmux", ["list-sessions", "-F", "#{session_name}"], { encoding: "utf8", env: SPAWN_ENV });
    if (result.status !== 0) return;
    const tmuxSessions = result.stdout
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.startsWith(TMUX_SESSION_PREFIX));

    for (const tmuxSession of tmuxSessions) {
      const id = tmuxSession.slice(TMUX_SESSION_PREFIX.length);
      if (activeTasks.has(id)) continue;

      const metadata = readMetadata(id);
      const cwdResult = spawnSync(TMUX_BIN || "tmux", ["display-message", "-t", tmuxSession, "-p", "#{pane_current_path}"], { encoding: "utf8", env: SPAWN_ENV });
      const workingDir = metadata?.working_dir || cwdResult.stdout?.trim() || process.cwd();
      const jsonlPath = metadata?.jsonl_path || outputPath(id);

      if (!existsSync(jsonlPath)) continue;

      const task = buildTaskFromMetadata(id, metadata, tmuxSession, workingDir, jsonlPath);
      rehydrateTaskFromLog(task);
      activeTasks.set(task.id, task);
      emitStatus(broadcastEvent, task, "running");
      startPollingTask(task.id, broadcastEvent);
    }
  } catch {
    // Best effort only.
  }
}

const HINT = [
  "## Codex Delegate",
  "Use delegate_codex to launch a Codex coding task in tmux.",
  "Use codex_status to check running Codex tasks, turns, token usage, and last activity.",
  "Use codex_stop to stop a specific Codex task by task_id, or all running tasks if omitted.",
].join("\n");

export const codexDelegate: ExtensionFactory = (pi: ExtensionAPI) => {
  let broadcastEvent: (type: string, data: unknown) => void = _noopBroadcast;

  try {
    const global = globalThis as { __PICLAW_BROADCAST_EVENT__?: (type: string, data: unknown) => void };
    if (typeof global.__PICLAW_BROADCAST_EVENT__ === "function") {
      broadcastEvent = global.__PICLAW_BROADCAST_EVENT__;
      codexWidgetBroadcast = global.__PICLAW_BROADCAST_EVENT__;
      console.error("[codex-delegate:init] broadcastEvent BOUND from globalThis");
    } else {
      console.error("[codex-delegate:init] broadcastEvent NOT FOUND on globalThis");
    }
  } catch (err) {
    console.error(`[codex-delegate:init] Error binding broadcastEvent: ${err}`);
  }

  pi.on("before_agent_start", async (event) => ({
    systemPrompt: `${event.systemPrompt}\n\n${HINT}`,
  }));

  pi.registerTool({
    name: "delegate_codex",
    label: "delegate_codex",
    description: "Launch a Codex coding task in a tmux session, stream JSONL progress to the chat timeline, and update a live status widget.",
    promptSnippet: "delegate_codex: launch Codex in tmux and return immediately with a task ID.",
    parameters: StartSchema,
    async execute(_toolCallId, params, _signal, _update, ctx) {
      return delegateCodex(params, broadcastEvent, ctx);
    },
  });

  pi.registerTool({
    name: "codex_status",
    label: "codex_status",
    description: "Check all running Codex delegate task statuses, including turns, token usage, and last activity.",
    promptSnippet: "codex_status: check running Codex tasks.",
    parameters: StatusSchema,
    async execute() {
      return codexStatus(broadcastEvent);
    },
  });

  pi.registerTool({
    name: "codex_stop",
    label: "codex_stop",
    description: "Stop a specific running Codex delegate task by task_id, or all running tasks if task_id is omitted.",
    promptSnippet: "codex_stop: stop one Codex task by task_id, or all running tasks if omitted.",
    parameters: StopSchema,
    async execute(_toolCallId, params) {
      return stopCodex(params, broadcastEvent);
    },
  });

  pi.registerCommand("update", {
    description: "Update PiClaw via the managed host helper (runs update --force --no-restart, then restarts)",
    handler: async (_args, ctx) => {
      const updateHelper = UPDATE_HELPER_BIN;
      if (!updateHelper || !existsSync(updateHelper)) {
        ctx.ui.notify("Update helper not found at " + String(updateHelper || "update"), "error");
        return;
      }
      ctx.ui.notify("Starting PiClaw update...", "info");
      const result = spawnSync(updateHelper, ["--force", "--no-restart"], {
        encoding: "utf8",
        env: SPAWN_ENV,
        timeout: 300_000,
      });
      const combinedOutput = `${result.stdout || ""}${result.stderr || ""}`.trim();
      if (result.status === 0) {
        postTimelineMessage("web:default", "PiClaw update completed:\n" + combinedOutput.slice(-2000));
        ctx.ui.notify("Update complete — restarting PiClaw...", "success");
        ctx.shutdown();
        return;
      }

      const msg = combinedOutput
        || result.error?.message
        || `update exited with code ${result.status ?? "unknown"}`;
      postTimelineMessage("web:default", "PiClaw update FAILED:\n" + msg.slice(-2000));
      ctx.ui.notify("Update failed — check timeline", "error");
    },
  });

  pi.registerCommand("rebuild", {
    description: "Rebuild the NixOS host via the managed rebuild helper",
    handler: async (_args, ctx) => {
      const rebuildHelper = REBUILD_HELPER_BIN;
      if (!rebuildHelper || !existsSync(rebuildHelper)) {
        ctx.ui.notify("Rebuild helper not found at " + String(rebuildHelper || "rebuild"), "error");
        return;
      }
      ctx.ui.notify("Starting host rebuild...", "info");
      const result = spawnSync(rebuildHelper, [], {
        encoding: "utf8",
        env: SPAWN_ENV,
        timeout: 1_800_000,
      });
      const combinedOutput = `${result.stdout || ""}${result.stderr || ""}`.trim();
      if (result.status === 0) {
        postTimelineMessage("web:default", "Host rebuild completed:\n" + combinedOutput.slice(-2000));
        ctx.ui.notify("Host rebuild completed", "success");
        return;
      }

      const msg = combinedOutput
        || result.error?.message
        || `rebuild exited with code ${result.status ?? "unknown"}`;
      postTimelineMessage("web:default", "Host rebuild FAILED:\n" + msg.slice(-2000));
      ctx.ui.notify("Host rebuild failed — check timeline", "error");
    },
  });

  setTimeout(() => reattachExistingTask(broadcastEvent), 1_000);
};

export default codexDelegate;
