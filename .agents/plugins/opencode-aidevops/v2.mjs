// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { Plugin } from "@opencode/plugin";
import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { BoundedInteractiveOperationManager } from "./bounded-interactive-operation.mjs";
import { createOutputSandboxReader, createOutputSandboxRecorder } from "./bounded-operation-output.mjs";
import { compactingHook } from "./compaction.mjs";
import { INTENT_FIELD } from "./intent-tracing.mjs";
import { getOnDemandMcpAgents } from "./mcp-registry.mjs";
import {
  createPoolTool,
} from "./oauth-pool.mjs";
import {
  consumeV2Completion,
  handleEvent,
  initObservability,
  recordObjectiveDecision,
} from "./observability.mjs";
import { createObjectiveReceiptTool } from "./objective-receipt-tool.mjs";
import { createPermissionBroker } from "./permission-broker.mjs";
import { installPluginConsoleRouter } from "./plugin-console.mjs";
import { recordPluginHealthStage } from "./plugin-health.mjs";
import { applyImageSizeGuard } from "./quality-hooks-image.mjs";
import { createQualityHooks } from "./quality-hooks.mjs";
import { createSessionContinuationGuard } from "./session-continuation-guard.mjs";
import { createSessionModelStore, createShellEnvHook } from "./shell-env.mjs";
import {
  appendConversationSystemContext,
  CONVERSATION_ORIGIN,
  CONVERSATION_OVERLAY_ENV,
  isRemoteInteractiveConversation,
  loadTeamInterfaceConversation,
} from "./team-interface-context.mjs";
import { enforceConversationPathAccess } from "./team-interface-path-guard.mjs";
import { adaptToolDefinition } from "./tool-definition.mjs";
import { createTools, tool } from "./tools.mjs";
import { createTtsrHooks, isPluginGreetingEnabled } from "./ttsr.mjs";
import { createRootSessionGreetingGate } from "./root-session-greeting-gate.mjs";
import { isHeadless } from "./proxy-lifecycle.mjs";
import { createV2McpRuntime } from "./v2-mcp-adapter.mjs";
import { loadV2PrimaryProfiles, registerV2PrimaryProfiles } from "./v2-agent-profiles.mjs";
import { applyV2ContextBudget, readV2ContextBudget } from "./v2-context-budget.mjs";
import { createV2ProviderAuthRuntime } from "./v2-provider-auth.mjs";
import {
  addV1ToolsToV2Editor,
  applyLegacyToolOutput,
  legacyToolOutput,
} from "./v2-tool-adapter.mjs";

const HOME = homedir();
const PLUGIN_ENTRY_PATH = fileURLToPath(import.meta.url);
const MODULE_AGENTS_DIR = resolve(dirname(PLUGIN_ENTRY_PATH), "../..");
const CONVERSATION_ENVIRONMENT = process.env.AIDEVOPS_SESSION_ORIGIN === CONVERSATION_ORIGIN
  || Boolean(process.env[CONVERSATION_OVERLAY_ENV]);
const ACTIVE_AGENTS_DIR = CONVERSATION_ENVIRONMENT
  ? MODULE_AGENTS_DIR
  : join(HOME, ".aidevops", "agents");
const AGENTS_DIR = CONVERSATION_ENVIRONMENT ? MODULE_AGENTS_DIR : ACTIVE_AGENTS_DIR;
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");
const LOGS_DIR = join(HOME, ".aidevops", "logs");

export const OPENCODE_V2_CAPABILITIES = Object.freeze({
  tools: true,
  qualityHooks: true,
  shellEnvironment: true,
  contextTransforms: true,
  compactionContext: true,
  permissions: true,
  events: true,
  mcpLifecycle: true,
  oauthRequestRotation: true,
  primaryAgents: true,
  optInCatalogCompactionBudget: true,
  textCompletionHook: false,
  compactionAutocontinue: false,
  tuiToast: false,
});

function run(command, timeout = 5000) {
  try {
    return execSync(command, {
      encoding: "utf8",
      timeout,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return "";
  }
}

function runChecked(command, timeout = 5000) {
  return execSync(command, {
    encoding: "utf8",
    timeout,
    stdio: ["pipe", "pipe", "pipe"],
  }).trim();
}

function readIfExists(path) {
  try {
    return existsSync(path) ? readFileSync(path, "utf8").trim() : "";
  } catch {
    return "";
  }
}

function currentAidevopsVersion() {
  return [
    readIfExists(join(ACTIVE_AGENTS_DIR, "VERSION")),
    readIfExists(join(AGENTS_DIR, "VERSION")),
    process.env.AIDEVOPS_VERSION,
  ].find(Boolean)?.split(/\r?\n/, 1)[0].trim() || "";
}

const OPENCODE_V2_PACKAGE_NAMES = new Set(["@opencode/cli", "opencode-ai"]);

function packageVersion(path) {
  try {
    const manifest = JSON.parse(readFileSync(path, "utf8"));
    const version = manifest?.version;
    if (!OPENCODE_V2_PACKAGE_NAMES.has(manifest?.name)) return "";
    return typeof version === "string" && /^\d+\.\d+\.\d+/.test(version) ? version : "";
  } catch {
    return "";
  }
}

/**
 * Resolve the OpenCode V2 runtime version from the running binary's package,
 * falling back to the isolated aidevops V2 runtime. The greeting uses this
 * instead of the shared V1 greeting cache, which reports the V1 version.
 */
export function detectOpenCodeV2RuntimeVersion({ execPath = process.execPath, env = process.env, home = HOME } = {}) {
  const v2Root = env.AIDEVOPS_OPENCODE_V2_ROOT || join(home, ".aidevops", "runtimes", "opencode-v2");
  const candidates = [
    execPath ? resolve(dirname(execPath), "..", "package.json") : "",
    join(v2Root, "runtime", "node_modules", "@opencode", "cli", "package.json"),
  ].filter(Boolean);
  for (const candidate of candidates) {
    const version = packageVersion(candidate);
    if (version) return version;
  }
  return "";
}

function v1Model(model) {
  return {
    providerID: model?.providerID || "",
    modelID: model?.id || model?.modelID || "",
  };
}

function v1HookInput(event) {
  return {
    sessionID: event.sessionID,
    sessionId: event.sessionID,
    messageID: event.messageID,
    callID: event.id,
    tool: event.tool,
    agent: event.agent,
    model: v1Model(event.model),
  };
}

function systemStrings(parts) {
  return (parts || []).map((part) => typeof part === "string" ? part : part?.text || "").filter(Boolean);
}

function replaceSystemParts(event, strings) {
  event.system.splice(0, event.system.length, ...strings.map((text, index) => ({
    ...event.system[index],
    type: "text",
    text,
  })));
}

export function createCompatibilityClient(ctx, mcpClient) {
  return {
    auth: { set: async () => ({}) },
    mcp: mcpClient,
    session: {
      async get(input) {
        return { data: await ctx.session.get({ sessionID: input.path.id }) };
      },
      async update(input) {
        await ctx.session.rename({ sessionID: input.path.id, title: input.body.title });
        return {};
      },
    },
  };
}

async function register(registrations, promise) {
  const registration = await promise;
  registrations.push(registration);
  return registration;
}

// OpenCode 2.0.3 public SessionEvent.Step uses data + envelope.created, not
// message.updated (or the unreleased session.next.* shape in PR #33024).
export function createV2CompletionNormalizer() {
  const started = new Map();
  return (event) => {
    const data = event?.data;
    const key = `${data?.sessionID}/${data?.assistantMessageID}`;
    if (started.size > 1000) started.delete(started.keys().next().value);
    if (event?.type === "session.step.started") {
      started.set(key, event);
      return null;
    }
    return consumeV2Completion(event, started, key);
  };
}

export async function startEventLoop(ctx, handler) {
  let iterator;
  let stopped = false;
  const subscription = await ctx.event.subscribe();
  const iterable = subscription?.stream || subscription;
  if (!iterable?.[Symbol.asyncIterator]) return async () => {};
  iterator = iterable[Symbol.asyncIterator]();
  const loop = (async () => {
    while (!stopped) {
      const next = await iterator.next();
      if (next.done) break;
      try {
        await handler({ event: next.value?.event || next.value });
      } catch (error) {
        if (process.env.AIDEVOPS_PLUGIN_DEBUG === "1") {
          console.error(`[aidevops] V2 event handler failed: ${error.message}`);
        }
      }
    }
  })().catch((error) => {
    if (!stopped && process.env.AIDEVOPS_PLUGIN_DEBUG === "1") {
      console.error(`[aidevops] V2 event subscription failed: ${error.message}`);
    }
  });
  return async () => {
    stopped = true;
    await iterator?.return?.().catch(() => {});
    await loop;
  };
}

/** Define an aidevops descriptor through the released OpenCode V2 SDK. */
export function defineAidevopsV2Adapter(setup) {
  if (typeof setup !== "function") throw new TypeError("OpenCode V2 adapter setup must be a function");
  return Plugin.define({ id: "aidevops", setup });
}

export function applyV2PermissionEvaluation(permissionBroker, event) {
  const output = { status: "ask" };
  permissionBroker.permissionAsk({
    ...event,
    type: event.action,
    patterns: event.resources,
  }, output);
  if (output.status === "allow") event.effect = "allow";
  if (output.status === "deny") event.effect = "deny";
}

async function disposeAidevopsV2({ stopEvents, boundedOperationManager, mcpRuntime, registrations }) {
  await stopEvents?.().catch(() => {});
  try {
    boundedOperationManager?.dispose();
  } catch { /* best-effort cleanup */ }
  await mcpRuntime?.dispose().catch(() => {});
  for (const registration of registrations.reverse()) {
    await registration.dispose().catch(() => {});
  }
}

export async function setupAidevopsV2(ctx) {
  const initializedAtMs = Date.now();
  const directory = String(ctx.location?.directory || process.cwd());
  const worktree = String(ctx.location?.project?.directory || directory);
  const registrations = [];

  installPluginConsoleRouter({
    logPath: join(LOGS_DIR, "opencode-plugin.log"),
    debug: process.env.AIDEVOPS_PLUGIN_DEBUG === "1",
  });
  recordPluginHealthStage("imported", { runtime: "v2" });
  initObservability({
    aidevopsVersion: currentAidevopsVersion(),
    runtimeVersion: (typeof ctx.app?.version === "string" && ctx.app.version) || detectOpenCodeV2RuntimeVersion(),
    adapterId: "opencode-v2",
  });

  const conversation = loadTeamInterfaceConversation(process.env, AGENTS_DIR, {
    pluginEntryPath: PLUGIN_ENTRY_PATH,
    repositoryDir: directory,
  });
  const mcpRuntime = createV2McpRuntime(ctx, WORKSPACE_DIR, { repositoryDir: directory });
  let boundedOperationManager;
  let stopEvents;
  try {
    await mcpRuntime.initialize();
    const client = createCompatibilityClient(ctx, mcpRuntime.client);
    boundedOperationManager = new BoundedInteractiveOperationManager({
      projectRoot: directory,
      scriptsDir: SCRIPTS_DIR,
      recordOutput: createOutputSandboxRecorder(join(SCRIPTS_DIR, "output-sandbox-helper.sh")),
      readOutput: createOutputSandboxReader(join(SCRIPTS_DIR, "output-sandbox-helper.sh")),
    });
    const baseTools = createTools(SCRIPTS_DIR, run, {
      aidevopsRun: runChecked,
      sessionOrigin: process.env.AIDEVOPS_SESSION_ORIGIN,
      poolToolFactory: () => createPoolTool(client),
      projectRoot: directory,
      mcpClient: mcpRuntime.client,
      mcpDirectory: directory,
      managedMcpNames: getOnDemandMcpAgents().map((mcp) => mcp.name),
      managedMcpWorkspaces: mcpRuntime.workspaces,
      boundedOperationManager,
    });
    baseTools.aidevops_objective_receipt = createObjectiveReceiptTool(tool, recordObjectiveDecision);

    const continuationGuard = createSessionContinuationGuard({
      repository: directory,
      checkpointHelper: join(SCRIPTS_DIR, "session-checkpoint-helper.sh"),
    });
    const sessionModels = createSessionModelStore();
    const { toolExecuteBefore, toolExecuteAfter, qualityLog } = createQualityHooks({
      activeScriptsDir: join(ACTIVE_AGENTS_DIR, "scripts"),
      scriptsDir: SCRIPTS_DIR,
      logsDir: LOGS_DIR,
      repositoryDir: directory,
      continuationGuard,
      resolveSessionModel: (sessionID) => sessionModels.resolve(sessionID),
    });
    const shellEnvHook = createShellEnvHook({
      activeAgentsDir: ACTIVE_AGENTS_DIR,
      agentsDir: AGENTS_DIR,
      scriptsDir: SCRIPTS_DIR,
      workspaceDir: WORKSPACE_DIR,
      onSessionIdentity: (sessionID, modelID) => sessionModels.remember(sessionID, modelID),
    });
    const shouldInjectGreeting = createRootSessionGreetingGate({
      getSession: (sessionID) => ctx.session.get({ sessionID }),
      isHeadless,
      log: qualityLog,
    });
    const greetingEnabled = () => isPluginGreetingEnabled(process.env, true);
    if (!greetingEnabled()) qualityLog("INFO", "Session greeting disabled by AIDEVOPS_PLUGIN_SESSION_GREETING");
    const { systemTransformHook, messagesTransformHook } = createTtsrHooks({
      agentsDir: AGENTS_DIR,
      scriptsDir: SCRIPTS_DIR,
      readIfExists,
      qualityLog,
      run,
      intentField: INTENT_FIELD,
      isHeadless,
      shouldInjectGreeting,
      initializedAtMs,
      runtimeName: "OpenCode",
      runtimeVersion: (typeof ctx.app?.version === "string" && ctx.app.version) || detectOpenCodeV2RuntimeVersion(),
      // The V2 config AGENTS.md is the framework guide, not the V1 greeting
      // fallback, so the plugin block stays the greeting source (GH#32444, GH#32498).
      greetingEnabled,
    });
    const permissionBroker = createPermissionBroker({ isHeadless });
    const providerAuth = createV2ProviderAuthRuntime();
    // Terminal title status is owned by the V2 TUI entrypoint (v2-plugin/tui.mjs):
    // this service process has no reliable terminal and must not write titles.

    const primaryProfiles = loadV2PrimaryProfiles(ACTIVE_AGENTS_DIR);
    await register(registrations, ctx.agent.transform((editor) => {
      registerV2PrimaryProfiles(editor, primaryProfiles);
    }));
    const budget = readV2ContextBudget();
    if (budget && typeof ctx.catalog?.transform === "function") await register(registrations, ctx.catalog.transform((editor) => {
      applyV2ContextBudget(editor, budget);
    }));

    await register(registrations, ctx.tool.transform((editor) => {
      addV1ToolsToV2Editor(editor, baseTools, tool.schema, { directory, worktree });
      editor.update("bash", (definition) => adaptToolDefinition({ toolID: "bash" }, definition));
      editor.update("grep", (definition) => adaptToolDefinition({ toolID: "grep" }, definition));
      editor.update("apply_patch", (definition) => adaptToolDefinition({ toolID: "apply_patch" }, definition));
    }));

    await register(registrations, ctx.tool.hook("execute.before", async (event) => {
      const input = v1HookInput(event);
      const output = { args: event.input || {} };
      enforceConversationPathAccess(event.tool, output.args, conversation);
      permissionBroker.recordToolCall(input, output);
      await toolExecuteBefore(input, output);
      event.input = output.args;
    }));
    await register(registrations, ctx.tool.hook("execute.after", async (event) => {
      const output = legacyToolOutput(event.result || {});
      await toolExecuteAfter(v1HookInput(event), output);
      if (event.status === "completed") applyLegacyToolOutput(event.result, output);
    }));
    await register(registrations, ctx.shell.hook("create.before", async (event) => {
      await shellEnvHook(v1HookInput(event), event);
    }));
    await register(registrations, ctx.session.hook("context", async (event) => {
      const input = v1HookInput(event);
      sessionModels.remember(event.sessionID, input.model.modelID);
      const legacy = { system: systemStrings(event.system), messages: event.messages };
      await systemTransformHook(input, legacy);
      await messagesTransformHook(input, legacy).catch((error) => qualityLog("WARN", `V2 message transform skipped: ${error.message}`));
      legacy.system.push("OpenCode 2: if TodoWrite is unavailable, keep a short numbered task list in your responses and update it as work progresses. The Code Mode catalogue is partial; find unlisted aidevops tools with search({ namespace: \"aidevops\" }) before concluding they are unavailable.");
      try {
        applyImageSizeGuard(legacy, qualityLog);
      } catch (error) {
        qualityLog("WARN", `V2 image guard skipped: ${error.message}`);
      }
      if (isRemoteInteractiveConversation(conversation)) appendConversationSystemContext(legacy, conversation);
      replaceSystemParts(event, legacy.system);
      event.messages = legacy.messages;
    }));
    await register(registrations, ctx.session.hook("compaction", async (event) => {
      const output = { context: [] };
      await compactingHook({ workspaceDir: WORKSPACE_DIR, scriptsDir: SCRIPTS_DIR }, event, output, directory, { host: "opencode2" });
      event.system.push(...output.context.map((text) => ({ type: "text", text })));
    }));
    await register(registrations, ctx.session.hook("http.request", providerAuth.httpRequest));
    await register(registrations, ctx.session.hook("http.response", providerAuth.httpResponse));
    await register(registrations, ctx.session.hook("retry", providerAuth.retry));
    await register(registrations, ctx.permission.hook("evaluate", async (event) => {
      applyV2PermissionEvaluation(permissionBroker, event);
    }));

    const normalizeCompletion = createV2CompletionNormalizer();
    stopEvents = await startEventLoop(ctx, async (input) => {
      const completed = normalizeCompletion(input.event);
      const observeContext = { resolveSessionModel: (sessionID) => sessionModels.resolve(sessionID) };
      await Promise.all([
        handleEvent(input, observeContext),
        completed ? handleEvent({ event: completed }, observeContext) : undefined,
        Promise.resolve(boundedOperationManager.handleEvent(input)),
        permissionBroker.handleEvent(input),
      ]);
    });
    recordPluginHealthStage("factory_initialized", {
      runtime: "v2",
      tools: Object.keys(baseTools).length,
      capabilities: OPENCODE_V2_CAPABILITIES,
    });

    return async () => {
      await disposeAidevopsV2({ stopEvents, boundedOperationManager, mcpRuntime, registrations });
    };
  } catch (error) {
    await disposeAidevopsV2({ stopEvents, boundedOperationManager, mcpRuntime, registrations });
    throw error;
  }
}

export const AidevopsV2Plugin = defineAidevopsV2Adapter(setupAidevopsV2);
export default AidevopsV2Plugin;
