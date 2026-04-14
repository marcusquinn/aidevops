import { existsSync } from "fs";
import { join } from "path";
import {
  BUILTIN_TTSR_RULES,
  loadTtsrRules,
  scanForViolations,
  getRecentAssistantMessages,
  collectDedupedViolations,
  recordFiredViolations,
} from "./ttsr-rules.mjs";

// ---------------------------------------------------------------------------
// Token Cost Advisory
// ---------------------------------------------------------------------------
// Injects a synthetic message when session context exceeds a token threshold,
// prompting the LLM to advise the user to run /compact. Fires at 200k tokens,
// then every 50k above that (250k, 300k, ...). Uses the last assistant
// message's token counts — which represent the full context sent to the model
// on that turn — so the number tracks real cost, not model capacity.
//
// For headless sessions: autocompact already fires at ~(limit - 20k), so
// this advisory primarily helps interactive sessions on large-context models
// (Gemini 1M+, future models) where autocompact is far above 200k, or when
// autocompact is disabled.

const TOKEN_ADVISORY_INITIAL = 200_000;
const TOKEN_ADVISORY_INTERVAL = 50_000;

/**
 * Compute token total from an assistant message's token counts.
 * @param {object} tokens - { input, output, reasoning, cache: { read, write } }
 * @returns {number}
 */
function getTokenTotal(tokens) {
  if (!tokens) return 0;
  return (tokens.input || 0) +
    (tokens.output || 0) +
    (tokens.reasoning || 0) +
    (tokens.cache?.read || 0) +
    (tokens.cache?.write || 0);
}

// ---------------------------------------------------------------------------
// TTSR state
// ---------------------------------------------------------------------------

/**
 * Create per-session TTSR state.
 * @param {string} ttsrRulesPath
 * @param {(path: string) => string} readIfExists
 * @returns {object}
 */
function createTtsrState(ttsrRulesPath, readIfExists) {
  return {
    ttsrRulesPath,
    readIfExists,
    /** @type {Array<object> | null} */
    ttsrRules: null,
    /** @type {Map<string, Set<string>>} */
    ttsrFiredState: new Map(),
    /** @type {Map<string, number>} Maps sessionID → highest threshold warned about. */
    tokenAdvisoryState: new Map(),
  };
}

// ---------------------------------------------------------------------------
// Token advisory helpers
// ---------------------------------------------------------------------------

/**
 * Prune old session entries from the advisory state map.
 * @param {Map<string, number>} tokenAdvisoryState
 */
function pruneAdvisoryState(tokenAdvisoryState) {
  if (tokenAdvisoryState.size <= 500) return;
  const keys = Array.from(tokenAdvisoryState.keys());
  for (const k of keys.slice(0, 250)) tokenAdvisoryState.delete(k);
}

/**
 * Check whether the token cost advisory should fire for this message set.
 * @param {Array<object>} messages
 * @param {Map<string, number>} tokenAdvisoryState
 * @returns {{ sessionID: string, totalK: number, total: number } | null}
 */
function checkTokenAdvisory(messages, tokenAdvisoryState) {
  for (let i = messages.length - 1; i >= 0; i--) {
    const info = messages[i].info;
    if (info?.role !== "assistant" || !info.tokens) continue;

    const total = getTokenTotal(info.tokens);
    if (total < TOKEN_ADVISORY_INITIAL) return null;

    const sessionID = info.sessionID || "";
    const lastWarned = tokenAdvisoryState.get(sessionID) || 0;
    const stepsAboveInitial = Math.floor((total - TOKEN_ADVISORY_INITIAL) / TOKEN_ADVISORY_INTERVAL);
    const currentThreshold = TOKEN_ADVISORY_INITIAL + stepsAboveInitial * TOKEN_ADVISORY_INTERVAL;

    if (currentThreshold <= lastWarned) return null;

    tokenAdvisoryState.set(sessionID, currentThreshold);
    pruneAdvisoryState(tokenAdvisoryState);
    return { sessionID, totalK: Math.round(total / 1000), total };
  }
  return null;
}

/**
 * Build the synthetic advisory message injected into the message stream.
 * @param {{ sessionID: string, totalK: number }} advisory
 * @returns {object}
 */
function buildTokenAdvisoryMessage(advisory) {
  const advisoryId = `token-advisory-${Date.now()}`;
  const text = [
    `[TOKEN COST ADVISORY] This session has reached approximately ${advisory.totalK}k tokens.`,
    "",
    "Briefly inform the user in your next response:",
    `The token cost of this session is rising with each interaction \u2014 currently at ~${advisory.totalK}k tokens. ` +
      "You can use the /compact command to significantly reduce ongoing costs. " +
      "Compaction preserves full understanding of what we\u2019re working on, so nothing is lost.",
    "",
    "Deliver this as a short note at the start of your response, then continue normally.",
    "Do not repeat this advisory if you have already mentioned it.",
  ].join("\n");

  return {
    info: { id: advisoryId, sessionID: advisory.sessionID, role: "user", time: { created: Date.now() }, parentID: "" },
    parts: [{
      id: `${advisoryId}-part`,
      sessionID: advisory.sessionID,
      messageID: advisoryId,
      type: "text",
      text,
      synthetic: true,
    }],
  };
}

// ---------------------------------------------------------------------------
// Correction message builder (called only from ttsrMessagesTransform)
// ---------------------------------------------------------------------------

function buildCorrectionMessage(violations, sessionID) {
  const corrections = violations.map((v) => {
    const severity = v.rule.severity === "error" ? "ERROR" : "WARNING";
    return `[${severity}] ${v.rule.id}: ${v.rule.correction}`;
  });
  const correctionText = [
    "[aidevops TTSR] Rule violations detected in recent output:",
    ...corrections, "",
    "Apply these corrections in your next response.",
  ].join("\n");
  const correctionId = `ttsr-correction-${Date.now()}`;
  return {
    info: { id: correctionId, sessionID, role: "user", time: { created: Date.now() }, parentID: "" },
    parts: [{ id: `${correctionId}-part`, sessionID, messageID: correctionId, type: "text", text: correctionText, synthetic: true }],
  };
}

// ---------------------------------------------------------------------------
// Hook implementations (module-level, accept state + deps as parameters)
// ---------------------------------------------------------------------------

/**
 * system.transform hook: prepend identity prefix and inject quality rules.
 */
async function ttsrSystemTransform(input, output, state, intentField) {
  if (input.model?.providerID === "anthropic") {
    const prefix = "You are Claude Code, Anthropic's official CLI for Claude.";
    output.system.unshift(prefix);
    if (output.system[1]) output.system[1] = prefix + "\n\n" + output.system[1];
  }

  const rules = loadTtsrRules(state);
  const ruleLines = rules.filter((r) => r.systemPrompt).map((r) => `- ${r.systemPrompt}`);

  const intentInstruction = [
    "## Intent Tracing (observability)",
    `When calling any tool, include a field named \`${intentField}\` in the tool arguments.`,
    "Value: one sentence in present participle form describing your intent (e.g., \"Reading the file to understand the existing schema\").",
    "No trailing period. This field is used for debugging and audit trails — it is stripped before tool execution.",
  ].join("\n");

  output.system.push(intentInstruction);
  if (ruleLines.length === 0) return;

  output.system.push([
    "## aidevops Quality Rules (enforced)",
    "The following rules are actively enforced. Violations will be flagged.",
    ...ruleLines,
  ].join("\n"));
}

/**
 * messages.transform hook: inject token advisory and TTSR violation corrections.
 */
async function ttsrMessagesTransform(_input, output, state, qualityLog) {
  if (!output.messages || output.messages.length === 0) return;

  const advisory = checkTokenAdvisory(output.messages, state.tokenAdvisoryState);
  if (advisory) {
    output.messages.push(buildTokenAdvisoryMessage(advisory));
    qualityLog("INFO", `Token advisory: session ${advisory.sessionID} at ~${advisory.totalK}k tokens`);
  }

  const assistantMessages = getRecentAssistantMessages(output.messages, 3);
  if (assistantMessages.length === 0) return;

  const allViolations = collectDedupedViolations(assistantMessages, state);
  if (allViolations.length === 0) return;

  recordFiredViolations(allViolations, state.ttsrFiredState);

  const sessionID = output.messages[0]?.info?.sessionID || "";
  output.messages.push(buildCorrectionMessage(allViolations, sessionID));

  qualityLog(
    "INFO",
    `TTSR messages.transform: injected ${allViolations.length} correction(s): ${allViolations.map((v) => v.rule.id).join(", ")}`,
  );
}

/**
 * Record TTSR violations to the pattern tracker script if available.
 * @param {Array<{ rule: object }>} violations
 * @param {{ scriptsDir: string, run: Function }} execDeps
 */
function recordViolationsToTracker(violations, execDeps) {
  const patternTracker = join(execDeps.scriptsDir, "pattern-tracker-helper.sh");
  if (!existsSync(patternTracker)) return;
  const ruleIds = violations.map((v) => v.rule.id).join(",");
  execDeps.run(
    `bash "${patternTracker}" record "TTSR_VIOLATION" "rules: ${ruleIds}" --tag "ttsr" 2>/dev/null`,
    5000,
  );
}

/**
 * text.complete hook: scan output text and append TTSR violation markers.
 * @param {object} input
 * @param {object} output
 * @param {object} state
 * @param {{ scriptsDir: string, run: Function }} execDeps
 * @param {(level: string, message: string) => void} qualityLog
 */
async function ttsrTextComplete(input, output, state, execDeps, qualityLog) {
  if (!output.text) return;

  const violations = scanForViolations(output.text, state);
  if (violations.length === 0) return;

  for (const v of violations) {
    qualityLog(
      v.rule.severity === "error" ? "ERROR" : "WARN",
      `TTSR violation [${v.rule.id}]: ${v.rule.description} (session: ${input.sessionID}, message: ${input.messageID})`,
    );
  }

  const markers = violations.map((v) => {
    const severity = v.rule.severity === "error" ? "ERROR" : "WARN";
    return `<!-- TTSR:${severity}:${v.rule.id} — ${v.rule.correction} -->`;
  });

  output.text = output.text + "\n" + markers.join("\n");
  recordViolationsToTracker(violations, execDeps);
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/**
 * Build TTSR hook functions with injected dependencies from index.mjs.
 * @param {object} deps
 * @param {string} deps.agentsDir
 * @param {string} deps.scriptsDir
 * @param {(path: string) => string} deps.readIfExists
 * @param {(level: string, message: string) => void} deps.qualityLog
 * @param {(cmd: string, timeout?: number) => string} deps.run
 * @param {string} deps.intentField
 * @returns {{ loadTtsrRules: Function, systemTransformHook: Function, messagesTransformHook: Function, textCompleteHook: Function }}
 */
export function createTtsrHooks(deps) {
  const { agentsDir, scriptsDir, readIfExists, qualityLog, run, intentField } = deps;
  const ttsrRulesPath = join(agentsDir, "configs", "ttsr-rules.json");
  const state = createTtsrState(ttsrRulesPath, readIfExists);
  const execDeps = { scriptsDir, run };

  return {
    loadTtsrRules: () => loadTtsrRules(state),
    systemTransformHook: (input, output) => ttsrSystemTransform(input, output, state, intentField),
    messagesTransformHook: (_input, output) => ttsrMessagesTransform(_input, output, state, qualityLog),
    textCompleteHook: (input, output) => ttsrTextComplete(input, output, state, execDeps, qualityLog),
  };
}

// Re-export BUILTIN_TTSR_RULES for callers that access it directly.
export { BUILTIN_TTSR_RULES };
