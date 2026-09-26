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

export function applyOnDemandMcpToolPolicy(profile, mcp) {
  const policy = onDemandMcpToolPolicy(mcp);
  const prefix = mcp.allowedTools && mcp.toolPattern.endsWith("*")
    ? mcp.toolPattern.slice(0, -1) : null;
  for (const field of ["tools", "permission"]) {
    profile[field] ||= {};
    if (prefix !== null) {
      // Remove stale exact grants, and reinsert the wildcard before approved
      // exact names. OpenCode applies the last matching rule.
      for (const name of Object.keys(profile[field])) {
        if (name.startsWith(prefix)) delete profile[field][name];
      }
    }
    Object.assign(profile[field], policy[field]);
  }
}
