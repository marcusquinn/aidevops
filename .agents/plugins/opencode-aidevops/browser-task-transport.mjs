// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

export const BROWSER_TASK_SCHEMA = "aidevops.browser-task/v1";
const MCP_REQUIRED = ["deployed", "enabled", "runtime_compatible", "tool_visible", "reachable"];

function capabilityBlocker(reason) {
  throw new Error(`[aidevops] Browser transport capability blocker: ${reason}; no child created, no transport fallback permitted`);
}

// Native Task has no invocation-scoped tool ceiling. Reject incompatible roles
// BEFORE Task creates/resumes a session, rather than trusting the child's prose.
export function assertBrowserTaskTransport(input, output) {
  if (input.tool !== "task") return;
  const args = output.args || {};
  const text = String(args.prompt || "").replace(/^\[effort:(simple|standard|thinking)\]\s*/i, "").trim();
  if (!text.startsWith("{")) return;
  let envelope;
  try {
    envelope = JSON.parse(text);
  } catch {
    // Structured Playwright requests cannot silently degrade into legacy prose.
    if (args.subagent_type === "playwright") capabilityBlocker("invalid JSON envelope");
    return;
  }
  if (!envelope || (!Object.hasOwn(envelope, "browser_transport") && envelope.schema !== BROWSER_TASK_SCHEMA)) return;
  if (envelope.schema !== BROWSER_TASK_SCHEMA || !["playwright", "mcp"].includes(envelope.browser_transport)) {
    capabilityBlocker("invalid transport envelope");
  }
  if (envelope.browser_transport === "playwright") {
    capabilityBlocker("standalone Playwright requires a transport-only runner; native Task roles cannot enforce that ceiling");
  }
  assertMcpTaskEnvelope(args, envelope);
  // Keep the full envelope intact for the child, including target, action budget,
  // cleanup, authorization and challenge stop conditions in the parent's prompt.
  // This validates supplied readiness, not live readiness or site authority.
}

function assertMcpTaskEnvelope(args, envelope) {
  if (args.subagent_type !== "playwright" || args.task_id) {
    capabilityBlocker("MCP envelope requires a fresh canonical playwright child");
  }
  const readiness = envelope.readiness;
  // Standalone evidence always carries its package/browser transport scope.
  // The current default MCP readiness helper emits a null evidence_scope.
  if (readiness?.capability !== "browser-automation" || readiness.decision !== "route"
    || readiness.evidence_scope !== null
    || !MCP_REQUIRED.every((key) => readiness.readiness?.[key] === "true")) {
    capabilityBlocker("MCP readiness is missing, unknown or belongs to another transport");
  }
  if (typeof envelope.prompt !== "string" || !envelope.prompt.trim()) {
    capabilityBlocker("bounded browser instructions are missing");
  }
}
