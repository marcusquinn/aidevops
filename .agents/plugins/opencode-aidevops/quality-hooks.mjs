// ---------------------------------------------------------------------------
// Phase 3: Quality Hooks (t008.3)
// Extracted from index.mjs (t1914) — tool execution hook wiring.
// Logging, scanning, and pipeline logic in quality-logging.mjs.
// ---------------------------------------------------------------------------

import { existsSync } from "fs";
import { execSync, execFile } from "child_process";
import { join } from "path";
import { recordToolCall } from "./observability.mjs";
import { extractAndStoreIntent, consumeIntent } from "./intent-tracing.mjs";
import { recordToolStart, consumeToolDuration } from "./timing-tracing.mjs";
import { qualityLog, runFileQualityGate } from "./quality-logging.mjs";
import { enrichActiveSpan, detectTaskId, detectSessionOrigin } from "./otel-enrichment.mjs";

// Re-export for consumers that import from this module
export { scanForSecrets } from "./quality-logging.mjs";

// ---------------------------------------------------------------------------
// Credential transcript scrub (GH#20207, Layer 4 of t2458)
// Mirrors shared-constants.sh scrub_credentials regex.
// Applied in handleToolAfter to redact tokens before they reach the model
// or are persisted to the SQLite transcript store.
// ---------------------------------------------------------------------------

const CREDENTIAL_PATTERN =
  /(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;

const REDACTION_TOKEN = "[redacted-credential]";

/**
 * Scrub known credential token prefixes from a string value.
 * @param {string} text
 * @returns {{ scrubbed: string, count: number }}
 */
function scrubCredentials(text) {
  let count = 0;
  const scrubbed = text.replace(CREDENTIAL_PATTERN, () => {
    count++;
    return REDACTION_TOKEN;
  });
  return { scrubbed, count };
}

/**
 * Recursively scrub credentials from any JSON-serialisable value.
 * @param {unknown} value
 * @returns {{ value: unknown, count: number }}
 */
function scrubValue(value) {
  if (typeof value === "string") {
    const { scrubbed, count } = scrubCredentials(value);
    return { value: scrubbed, count };
  }
  if (Array.isArray(value)) {
    let total = 0;
    const result = value.map((item) => {
      const { value: v, count } = scrubValue(item);
      total += count;
      return v;
    });
    return { value: result, count: total };
  }
  if (value !== null && typeof value === "object") {
    let total = 0;
    const result = {};
    for (const [k, v] of Object.entries(value)) {
      const { value: scrubbed, count } = scrubValue(v);
      result[k] = scrubbed;
      total += count;
    }
    return { value: result, count: total };
  }
  return { value, count: 0 };
}

/**
 * Scrub credentials from tool output. Returns the sanitised output and a
 * boolean indicating whether any redaction occurred.
 * @param {unknown} output
 * @returns {{ output: unknown, redacted: boolean }}
 */
function scrubToolOutput(output) {
  const { value, count } = scrubValue(output);
  return { output: value, redacted: count > 0 };
}

// ---------------------------------------------------------------------------
// Tool classification helpers
// ---------------------------------------------------------------------------

/**
 * Check if a tool name is a Write or Edit operation.
 * @param {string} tool
 * @returns {boolean}
 */
function isWriteOrEditTool(tool) {
  return tool === "Write" || tool === "Edit" || tool === "write" || tool === "edit";
}

/**
 * Check if a tool name is a Bash operation.
 * @param {string} tool
 * @returns {boolean}
 */
function isBashTool(tool) {
  return tool === "Bash" || tool === "bash";
}

// ---------------------------------------------------------------------------
// Signature footer gate (GH#12805, t1755, t2685)
// ---------------------------------------------------------------------------
// Implementation extracted to quality-hooks-signature.mjs (t2685) to keep
// this module below the qlty file-complexity ratchet. Re-exports preserve
// the existing public API so callers and tests don't have to change imports.

export {
  SIG_MARKER,
  isGhWriteCommand,
  isMachineProtocolCommand,
  hasTrustedSignatureSignal,
  tryRepairSignature,
  checkSignatureFooterGate,
} from "./quality-hooks-signature.mjs";

// ---------------------------------------------------------------------------
// Pattern tracking
// ---------------------------------------------------------------------------

/**
 * Run a shell command and return stdout, or empty string on failure.
 * @param {string} cmd
 * @param {number} [timeout=5000]
 * @returns {string}
 */
/**
 * Record a git operation pattern via pattern-tracker-helper.sh.
 * @param {string} scriptsDir
 * @param {string} title
 * @param {string} outputText
 */
function recordGitPattern(scriptsDir, title, outputText) {
  const patternTracker = join(scriptsDir, "pattern-tracker-helper.sh");
  if (!existsSync(patternTracker)) return;

  const success = !outputText.includes("error") && !outputText.includes("fatal");
  const patternType = success ? "SUCCESS_PATTERN" : "FAILURE_PATTERN";

  try {
    execSync(
      `bash "${patternTracker}" record "${patternType}" "git operation: ${title.substring(0, 100)}" --tag "quality-hook" 2>/dev/null`,
      { encoding: "utf-8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"] },
    );
  } catch {
    // best-effort
  }
}

/**
 * Track Bash tool operations (git, lint) for pattern recording.
 * @param {object} ctx - { scriptsDir, logsDir, qualityLogPath }
 * @param {string} title
 * @param {string} outputText
 */
function trackBashOperation(ctx, title, outputText) {
  if (title.includes("git commit") || title.includes("git push")) {
    console.error(`[aidevops] Git operation detected: ${title}`);
    qualityLog(ctx.logsDir, ctx.qualityLogPath, "INFO", `Git operation: ${title}`);
    recordGitPattern(ctx.scriptsDir, title, outputText);
  }

  if (title.includes("shellcheck") || title.includes("linters-local")) {
    const passed = !outputText.includes("error") && !outputText.includes("violation");
    qualityLog(ctx.logsDir, ctx.qualityLogPath, passed ? "INFO" : "WARN", `Lint run: ${title} — ${passed ? "PASS" : "issues found"}`);
  }
}

/**
 * Handle post-tool tracking for task tool calls (GH#17511).
 * @param {string} taskId
 * @param {string} scriptsDir
 * @param {Function} log - Quality logger function
 */
function recordChildSubagent(taskId, scriptsDir, log) {
  if (!taskId) return;
  const helper = join(scriptsDir, "gh-signature-helper.sh");
  if (!existsSync(helper)) return;
  execFile(helper, ["record-child", "--child", taskId], (err) => {
    if (err) log("WARN", `record-child failed: ${err.message}`);
  });
}

// ---------------------------------------------------------------------------
// Hook factory
// ---------------------------------------------------------------------------

/**
 * Create the quality hook functions (toolExecuteBefore, toolExecuteAfter).
 * @param {object} deps - { scriptsDir, logsDir }
 * @returns {{ toolExecuteBefore: Function, toolExecuteAfter: Function, qualityLog: Function }}
 */
/**
 * Pre-tool-execution handler: intent tracing, signature gate, file quality.
 * @param {object} ctx - Quality hooks context
 * @param {Function} log - Bound quality logger
 * @param {object} input - Tool input
 * @param {object} output - Tool output
 */
function handleToolBefore(ctx, log, input, output) {
  const callID = input.callID || "";
  let intent = "";
  if (callID && output.args) {
    intent = extractAndStoreIntent(callID, output.args) || "";
    if (intent) {
      log("INFO", `Intent [${input.tool}] callID=${callID}: ${intent}`);
    }
  }

  // t2184: pair with tool.execute.after to compute duration_ms for the
  // tool_calls INSERT. recordToolStart no-ops on empty callID.
  recordToolStart(callID);

  // OTEL span enrichment (t2177) — attaches aidevops attributes to opencode's
  // active tool span when OTEL is enabled. Async fire-and-forget; errors
  // swallowed inside enrichActiveSpan to isolate the host tool from OTEL SDK
  // failures.
  enrichActiveSpan({
    "aidevops.intent": intent,
    "aidevops.tool_name": input.tool || "",
    "aidevops.task_id": detectTaskId(),
    "aidevops.session_origin": detectSessionOrigin(),
    "aidevops.runtime": "opencode",
  }).catch(() => {});

  if (isBashTool(input.tool)) {
    // t2685: pass scriptsDir + output so the hook can repair (mutate
    // output.args.command) or block (throw) as appropriate.
    checkSignatureFooterGate(output.args?.command || "", log, ctx.scriptsDir, output);
  }

  if (!isWriteOrEditTool(input.tool)) return;

  const filePath = output.args?.filePath || output.args?.file_path || "";
  if (filePath) {
    runFileQualityGate(ctx, filePath, output.args);
  }
}

/**
 * Post-tool-execution handler: bash tracking, file logging, observability.
 * @param {object} ctx - Quality hooks context
 * @param {Function} log - Bound quality logger
 * @param {string} scriptsDir
 * @param {object} input - Tool input
 * @param {object} output - Tool output
 */
function handleToolAfter(ctx, log, scriptsDir, input, output) {
  const toolName = input.tool || "";

  // GH#20207 (t2458 Layer 4): scrub credentials from tool output before
  // persisting to the SQLite transcript store or sending to the model.
  // Applies to all tools — credentials can arrive via user scripts, third-party
  // CLIs, or runtime error backtraces, not just framework helpers.
  const rawOutput = output.output;
  if (rawOutput !== undefined) {
    const { output: scrubbedOutput, redacted } = scrubToolOutput(rawOutput);
    if (redacted) {
      output.output = scrubbedOutput;
      log("WARN", `[credential-scrub] redacted credential token(s) from ${toolName} output`);
    }
  }

  if (isBashTool(toolName)) {
    trackBashOperation(ctx, output.title || "", output.output || "");
  }

  if (isWriteOrEditTool(toolName)) {
    const filePath = output.metadata?.filePath || "";
    if (filePath) {
      log("INFO", `File modified: ${filePath} via ${toolName}`);
    }
  }

  const intent = consumeIntent(input.callID || "");
  // t2184: consumeToolDuration returns null when the callID wasn't paired
  // (e.g., hook race on plugin reload) — recordToolCall emits SQL NULL.
  const durationMs = consumeToolDuration(input.callID || "");
  recordToolCall(input, output, intent, durationMs);

  if (toolName === "mcp_task" || toolName === "task") {
    recordChildSubagent(output?.metadata?.task_id || "", scriptsDir, log);
  }
}

export function createQualityHooks(deps) {
  const { scriptsDir, logsDir } = deps;
  const qualityLogPath = join(logsDir, "quality-hooks.log");
  // t2120: qualityDetailLog (in quality-logging.mjs) reads ctx.detailLogPath
  // and ctx.detailMaxBytes. Previously these were never populated here, so
  // every call to logQualityGateResult → qualityDetailLog threw
  // "path must be a string or a file descriptor" from appendFileSync(undefined)
  // at quality-logging.mjs:86. The warning was swallowed by the catch block
  // but `console.error` polluted every worker's stderr on every file write.
  // It also meant real quality-gate diagnostics (shellcheck reports, markdown
  // lint, secret scan details) were silently lost for every edit — the
  // framework's own write-time quality discipline was invisible.
  const detailLogPath = join(logsDir, "quality-hooks-detail.log");
  const detailMaxBytes = 5 * 1024 * 1024; // 5MB before rotation
  const ctx = {
    scriptsDir,
    logsDir,
    qualityLogPath,
    detailLogPath,
    detailMaxBytes,
  };

  function boundQualityLog(level, message) {
    qualityLog(logsDir, qualityLogPath, level, message);
  }

  return {
    toolExecuteBefore: async (input, output) => handleToolBefore(ctx, boundQualityLog, input, output),
    toolExecuteAfter: async (input, output) => handleToolAfter(ctx, boundQualityLog, scriptsDir, input, output),
    qualityLog: boundQualityLog,
  };
}
