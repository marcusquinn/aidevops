// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Keep exact tool permissions after the broad deny: OpenCode uses the last
// matching rule. Reuse the same policy for new and re-registered agents.
export function onDemandMcpToolPolicy(mcp) {
  const allowed = mcp.allowedTools || [];
  return {
    tools: {
      [mcp.toolPattern]: !mcp.allowedTools,
      ...Object.fromEntries(allowed.map((name) => [name, true])),
    },
    permission: {
      [mcp.toolPattern]: mcp.allowedTools ? "deny" : "allow",
      ...Object.fromEntries(allowed.map((name) => [
        name, mcp.approvalRequiredTools?.includes(name) ? "ask" : "allow",
      ])),
    },
  };
}
