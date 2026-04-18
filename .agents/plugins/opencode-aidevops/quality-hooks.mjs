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
import { qualityLog, runFileQualityGate } from "./quality-logging.mjs";
import { enrichActiveSpan, detectTaskId, detectSessionOrigin } from "./otel-enrichment.mjs";

// Re-export for consumers that import from this module
export { scanForSecrets } from "./quality-logging.mjs";

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
// Signature footer gate
// ---------------------------------------------------------------------------

/**
 * Check signature footer gate on gh write commands (GH#12805, t1755).
 * @param {string} cmd - Bash command string
 * @param {Function} log - Quality logger function
 */
function checkSignatureFooterGate(cmd, log) {
  const ghWritePattern = /\bgh\s+(pr\s+create|issue\s+(create|comment))\b/;
  const hasGhWriteCommand = cmd.split("\n").some((line) => {
    const trimmed = line.trim();
    if (trimmed.startsWith("#")) return false;
    if (/\bgit\s+commit\b/.test(trimmed)) return false;
    return ghWritePattern.test(trimmed);
  });

  if (!hasGhWriteCommand) return;

  const isMachineProtocol =
    /DISPATCH_CLAIM|KILL_WORKER|DISPATCH_ACK|<!-- MERGE_SUMMARY -->/.test(cmd);
  const hasDirectFooter =
    cmd.includes("aidevops.sh") || cmd.includes("gh-signature-helper");
  const hasFooterVar =
    /\$\{?\w*(?:footer|FOOTER|signature|SIGNATURE)\w*\}?/i.test(cmd);

  if (!isMachineProtocol && !hasDirectFooter && !hasFooterVar) {
    log("WARN", `Signature footer missing in: ${cmd.substring(0, 200)}`);
  }
}

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
    checkSignatureFooterGate(output.args?.command || "", log);
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
  recordToolCall(input, output, intent);

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
