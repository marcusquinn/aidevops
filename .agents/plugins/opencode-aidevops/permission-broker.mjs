// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "fs";
import { dirname } from "path";
import { homedir } from "os";

const REQUEST_SCHEMA = "aidevops-permission-capture/v1";
const MAX_PATTERN_LENGTH = 500;
const MAX_INTENT_LENGTH = 500;
const MAX_REQUESTS = 20;
const FORBIDDEN_PATTERN = /(?:approval-keys\/private|\/(?:\.ssh|\.gnupg)(?:\/|$)|auth\.json(?:$|\*)|credentials?(?:\.|\/|$)|(?:^|\/)\.env(?:\.|$|\/))/i;
const HIGH_RISK_PATTERN = /(?:\.config\/opencode|node_modules\/@opencode-ai\/plugin|(?:^|\/)\.git(?:\/|$))/i;

function redactSecrets(value) {
  return value
    .replace(/((?:api[_-]?key|token|secret|password|authorization)\s*[:=]\s*)[^\s,;]+/gi, "$1[REDACTED]")
    .replace(/\b(?:sk|ghp|github_pat|sntryu)_[A-Za-z0-9_-]{12,}\b/g, "[REDACTED]");
}

export function sanitizePermissionText(value, options = {}) {
  if (typeof value !== "string") return "";
  const home = options.home || homedir();
  const workDir = options.workDir || process.env.WORKER_WORKTREE_PATH || "";
  let sanitized = value.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  sanitized = redactSecrets(sanitized);
  if (home && sanitized.includes(home)) sanitized = sanitized.split(home).join("~");
  if (workDir && sanitized.includes(workDir)) sanitized = sanitized.split(workDir).join("$WORKTREE");
  return sanitized.slice(0, options.maxLength || MAX_PATTERN_LENGTH);
}

function classifyRisk(permission, patterns, tool) {
  const combined = patterns.join("\n");
  if (patterns.some((pattern) => FORBIDDEN_PATTERN.test(pattern))) {
    return { level: "critical", grantable: false, reason: "sensitive credential or signing-key location" };
  }
  if (["bash", "edit", "write"].includes(tool) || ["bash", "edit"].includes(permission)) {
    return { level: "high", grantable: true, reason: "capability can modify or execute content" };
  }
  if (HIGH_RISK_PATTERN.test(combined)) {
    return { level: "high", grantable: true, reason: "shared runtime or OpenCode configuration path" };
  }
  if (permission === "external_directory") {
    return { level: "medium", grantable: true, reason: "access crosses the worker project boundary" };
  }
  return { level: "low", grantable: true, reason: "bounded non-destructive capability" };
}

function stableRequestID(request) {
  const canonical = JSON.stringify({
    issue: request.issue,
    repo: request.repo,
    permission: request.permission,
    patterns: [...request.patterns].sort(),
    tool: request.tool,
    intent: request.intent,
  });
  return `perm-${createHash("sha256").update(canonical).digest("hex").slice(0, 16)}`;
}

function readCaptureFile(path) {
  if (!path || !existsSync(path)) return null;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return parsed?.schema === REQUEST_SCHEMA ? parsed : null;
  } catch {
    return null;
  }
}

function writeCaptureFile(path, capture) {
  if (!path) return;
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(capture, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporary, path);
}

function normalizePatterns(input, options) {
  const source = Array.isArray(input) ? input : input == null ? [] : [input];
  return [...new Set(source
    .map((value) => sanitizePermissionText(String(value), options))
    .filter(Boolean))].slice(0, 20);
}

export function createPermissionBroker({ client, isHeadless, home = homedir() }) {
  const toolCalls = new Map();

  function recordToolCall(input, output) {
    if (!isHeadless()) return;
    const callID = input?.callID || input?.callId;
    if (!callID) return;
    const args = output?.args || input?.args || {};
    toolCalls.set(callID, {
      tool: sanitizePermissionText(input?.tool || input?.name || "unknown", { home, maxLength: 100 }),
      intent: sanitizePermissionText(args?.agent__intent || "", { home, maxLength: MAX_INTENT_LENGTH }),
    });
    while (toolCalls.size > 100) toolCalls.delete(toolCalls.keys().next().value);
  }

  function captureRequest(raw) {
    const requestFile = process.env.AIDEVOPS_PERMISSION_REQUEST_FILE || "";
    if (!requestFile) return null;
    const callID = raw?.tool?.callID || raw?.callID || "";
    const toolContext = toolCalls.get(callID) || {};
    const options = { home, workDir: process.env.WORKER_WORKTREE_PATH || "" };
    const permission = sanitizePermissionText(raw?.permission || raw?.type || "unknown", { ...options, maxLength: 100 });
    const patterns = normalizePatterns(raw?.patterns ?? raw?.pattern, options);
    const tool = sanitizePermissionText(toolContext.tool || raw?.metadata?.tool || permission, { ...options, maxLength: 100 });
    const risk = classifyRisk(permission, patterns, tool);
    const request = {
      request_id: "",
      permission,
      patterns,
      tool,
      intent: sanitizePermissionText(toolContext.intent || raw?.metadata?.description || raw?.title || "", { ...options, maxLength: MAX_INTENT_LENGTH }),
      risk,
      opencode: {
        request_id: sanitizePermissionText(raw?.id || "", { ...options, maxLength: 100 }),
        session_id: sanitizePermissionText(raw?.sessionID || "", { ...options, maxLength: 100 }),
        message_id: sanitizePermissionText(raw?.tool?.messageID || raw?.messageID || "", { ...options, maxLength: 100 }),
        call_id: sanitizePermissionText(callID, { ...options, maxLength: 100 }),
      },
      captured_at: new Date().toISOString(),
    };
    const capture = readCaptureFile(requestFile) || {
      schema: REQUEST_SCHEMA,
      issue: sanitizePermissionText(process.env.WORKER_ISSUE_NUMBER || "", { ...options, maxLength: 30 }),
      repo: sanitizePermissionText(process.env.WORKER_REPO_SLUG || process.env.DISPATCH_REPO_SLUG || "", { ...options, maxLength: 200 }),
      worker_session: sanitizePermissionText(process.env.WORKER_SESSION_KEY || "", { ...options, maxLength: 200 }),
      requests: [],
    };
    request.request_id = stableRequestID({ ...request, issue: capture.issue, repo: capture.repo });
    const existingIndex = capture.requests.findIndex((item) => item.request_id === request.request_id);
    if (existingIndex >= 0) capture.requests[existingIndex] = request;
    else capture.requests.push(request);
    capture.requests = capture.requests.slice(-MAX_REQUESTS);
    writeCaptureFile(requestFile, capture);
    return request;
  }

  async function replyReject(request) {
    if (!request?.id || !request?.sessionID) return;
    try {
      await client.postSessionIdPermissionsPermissionId({
        path: { id: request.sessionID, permissionID: request.id },
        body: { response: "reject" },
      });
    } catch {
      // `opencode run` may have already rejected the same request.
    }
  }

  async function handleEvent(input) {
    const event = input?.event;
    if (!isHeadless() || event?.type !== "permission.asked") return;
    const request = event.properties || {};
    captureRequest(request);
    await replyReject(request);
  }

  async function permissionAsk(input, output) {
    if (!isHeadless()) return;
    captureRequest(input || {});
    output.status = "deny";
  }

  return { recordToolCall, handleEvent, permissionAsk };
}
