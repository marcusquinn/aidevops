// ---------------------------------------------------------------------------
// Quality Logging and Scanning Infrastructure
// Extracted from quality-hooks.mjs (t1914) — logging, rotation, scanning.
// ---------------------------------------------------------------------------

import {
  readFileSync,
  existsSync,
  appendFileSync,
  mkdirSync,
  statSync,
  writeFileSync,
  renameSync,
} from "fs";
import { execSync } from "child_process";
import { validateReturnStatements, validatePositionalParams } from "./validators.mjs";
import { runMarkdownQualityPipeline } from "./quality-pipeline.mjs";

const CONSOLE_MAX_DETAIL_LINES = 10;

/**
 * Run a shell command and return stdout, or empty string on failure.
 * @param {string} cmd
 * @param {number} [timeout=5000]
 * @returns {string}
 */
function run(cmd, timeout = 5000) {
  try {
    return execSync(cmd, {
      encoding: "utf-8",
      timeout,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return "";
  }
}

/**
 * Log a quality event to the quality hooks log file.
 * @param {string} logsDir
 * @param {string} qualityLogPath
 * @param {string} level - "INFO" | "WARN" | "ERROR"
 * @param {string} message
 */
export function qualityLog(logsDir, qualityLogPath, level, message) {
  try {
    mkdirSync(logsDir, { recursive: true });
    const timestamp = new Date().toISOString();
    appendFileSync(qualityLogPath, `[${timestamp}] [${level}] ${message}\n`);
  } catch {
    // Logging should never break the hook
  }
}

/**
 * Rotate a log file if it exceeds maxBytes.
 * @param {string} logPath
 * @param {number} maxBytes
 */
function rotateLogIfNeeded(logPath, maxBytes) {
  try {
    if (!existsSync(logPath)) return;
    const stats = statSync(logPath);
    if (stats.size <= maxBytes) return;
    const backup = `${logPath}.1`;
    renameSync(logPath, backup);
    writeFileSync(logPath, `[${new Date().toISOString()}] [INFO] Log rotated (previous: ${stats.size} bytes)\n`);
  } catch (e) {
    console.error(`[aidevops] Log rotation failed: ${e.message}`);
  }
}

/**
 * Write full quality violation details to the detail log file.
 * @param {object} ctx - { logsDir, detailLogPath, detailMaxBytes }
 * @param {string} label
 * @param {string} filePath
 * @param {string} report
 */
function qualityDetailLog(ctx, label, filePath, report) {
  try {
    mkdirSync(ctx.logsDir, { recursive: true });
    rotateLogIfNeeded(ctx.detailLogPath, ctx.detailMaxBytes);
    const timestamp = new Date().toISOString();
    appendFileSync(
      ctx.detailLogPath,
      `[${timestamp}] ${label} — ${filePath}\n${report}\n\n`,
    );
  } catch (e) {
    console.error(`[aidevops] Quality detail logging failed: ${e.message}`);
  }
}

/**
 * Scan file content for potential secrets.
 * @param {string} filePath
 * @param {string} [content]
 * @returns {{ violations: number, details: string[] }}
 */
export function scanForSecrets(filePath, content) {
  const details = [];
  let violations = 0;

  const secretPatterns = [
    { pattern: /(?:api[_-]?key|apikey)\s*[:=]\s*['"][A-Za-z0-9+/=]{20,}['"]/i, label: "API key" },
    { pattern: /(?:secret|password|passwd|pwd)\s*[:=]\s*['"][^'"]{8,}['"]/i, label: "Secret/password" },
    { pattern: /(?:AKIA|ASIA)[A-Z0-9]{16}/, label: "AWS access key" },
    { pattern: /ghp_[A-Za-z0-9]{36}/, label: "GitHub personal access token" },
    { pattern: /gho_[A-Za-z0-9]{36}/, label: "GitHub OAuth token" },
    { pattern: /sk-[A-Za-z0-9]{20,}/, label: "OpenAI/Stripe secret key" },
    { pattern: /-----BEGIN (?:RSA |EC |DSA )?PRIVATE KEY-----/, label: "Private key" },
  ];

  try {
    const text = content || readFileSync(filePath, "utf-8");
    const lines = text.split("\n");

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.trim().startsWith("#") || /example|placeholder|YOUR_/i.test(line)) {
        continue;
      }
      for (const { pattern, label } of secretPatterns) {
        if (pattern.test(line)) {
          details.push(`  Line ${i + 1}: potential ${label} detected`);
          violations++;
          break;
        }
      }
    }
  } catch {
    // File read error — skip
  }

  return { violations, details };
}

/**
 * Run the full pre-commit quality pipeline on a shell script.
 * @param {string} filePath
 * @returns {{ totalViolations: number, report: string }}
 */
export function runShellQualityPipeline(filePath) {
  const sections = [];
  let totalViolations = 0;

  const shellcheckResult = run(
    `shellcheck -x -S warning "${filePath}" 2>&1`,
    10000,
  );
  if (shellcheckResult) {
    const count = (shellcheckResult.match(/^In /gm) || []).length || 1;
    totalViolations += count;
    sections.push(`ShellCheck (${count} issue${count !== 1 ? "s" : ""}):\n${shellcheckResult}`);
  }

  const returnResult = validateReturnStatements(filePath);
  if (returnResult.violations > 0) {
    totalViolations += returnResult.violations;
    sections.push(
      `Return statements (${returnResult.violations} missing):\n${returnResult.details.join("\n")}`,
    );
  }

  const paramResult = validatePositionalParams(filePath);
  if (paramResult.violations > 0) {
    totalViolations += paramResult.violations;
    sections.push(
      `Positional params (${paramResult.violations} direct usage):\n${paramResult.details.join("\n")}`,
    );
  }

  const secretResult = scanForSecrets(filePath);
  if (secretResult.violations > 0) {
    totalViolations += secretResult.violations;
    sections.push(
      `Secrets scan (${secretResult.violations} potential):\n${secretResult.details.join("\n")}`,
    );
  }

  const report = sections.length > 0
    ? sections.join("\n\n")
    : "All quality checks passed.";

  return { totalViolations, report };
}

/**
 * Log a quality gate result (violations or pass).
 * @param {object} ctx - { logsDir, qualityLogPath, detailLogPath, detailMaxBytes }
 * @param {object} result - { label, filePath, totalViolations, report, errorLevel? }
 */
export function logQualityGateResult(ctx, result) {
  const { label, filePath, totalViolations, report, errorLevel = "WARN" } = result;
  if (totalViolations > 0) {
    const plural = totalViolations !== 1 ? "s" : "";
    qualityLog(ctx.logsDir, ctx.qualityLogPath, errorLevel, `${label}: ${totalViolations} violations in ${filePath}`);
    qualityDetailLog(ctx, label, filePath, report);
    if (errorLevel === "ERROR") {
      const reportLines = report.split("\n");
      let consoleReport;
      if (reportLines.length > CONSOLE_MAX_DETAIL_LINES) {
        const shown = reportLines.slice(0, CONSOLE_MAX_DETAIL_LINES).join("\n");
        const omitted = reportLines.length - CONSOLE_MAX_DETAIL_LINES;
        consoleReport = `${shown}\n  ... and ${omitted} more (see ${ctx.detailLogPath})`;
      } else {
        consoleReport = report;
      }
      console.error(`[aidevops] ${label}: ${totalViolations} issue${plural} in ${filePath}:\n${consoleReport}`);
    }
  } else {
    qualityLog(ctx.logsDir, ctx.qualityLogPath, "INFO", `${label}: PASS for ${filePath}`);
  }
}

/**
 * Run quality gate on a file being written/edited.
 * @param {object} ctx - Logging context
 * @param {string} filePath
 * @param {object} args - Tool args (for content extraction)
 */
export function runFileQualityGate(ctx, filePath, args) {
  if (filePath.endsWith(".sh")) {
    const result = runShellQualityPipeline(filePath);
    logQualityGateResult(ctx, { label: "Quality gate", filePath, totalViolations: result.totalViolations, report: result.report });
    const secretResult = scanForSecrets(filePath);
    if (secretResult.violations > 0) {
      logQualityGateResult(ctx, { label: "SECURITY", filePath, totalViolations: secretResult.violations,
        report: secretResult.details.join("\n"), errorLevel: "ERROR" });
    }
    return;
  }

  if (filePath.endsWith(".md")) {
    const result = runMarkdownQualityPipeline(filePath);
    logQualityGateResult(ctx, { label: "Markdown quality", filePath, totalViolations: result.totalViolations, report: result.report });
    return;
  }

  const writeContent = args?.content || args?.newString || "";
  if (writeContent) {
    const secretResult = scanForSecrets(filePath, writeContent);
    logQualityGateResult(ctx, { label: "SECURITY", filePath, totalViolations: secretResult.violations,
      report: secretResult.details.join("\n"), errorLevel: "ERROR" });
  }
}
