// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// OpenCode V2 counterpart of V1's registerOnDemandMcpAgents (GH#34219).
// V2 has no global `tools` map and evaluates one ordered ruleset per agent
// (last matching rule wins; a trailing wildcard deny hides the tool). Global
// MCP denies are therefore appended to every agent, and each activation agent
// re-allows only its own MCP after them.

import { MCP_ACTIVATION_TOOL, onDemandMcpSourceProfile } from "./config-agent-profiles.mjs";
import { getOnDemandMcpAgents } from "./mcp-registry.mjs";
import { onDemandMcpToolPolicy } from "./on-demand-mcp-tool-policy.mjs";

// V1 tool keys whose V2 permission action differs or varies by host release.
// Rules for unused aliases never match, so emitting every alias is safe.
const ACTION_ALIASES = {
  bash: ["bash", "shell"],
  task: ["task", "subagent"],
  write: ["edit"],
  patch: ["edit"],
};
const EFFECTS = new Set(["allow", "ask", "deny"]);
// Host built-in subagent whose rules carry host defaults plus config-level
// permissions; new activation agents inherit them like V1 global permissions.
const BASE_AGENT = "general";

const rule = (action, effect, resource = "*") => ({ action, resource, effect });
const actionsFor = (name) => ACTION_ALIASES[name] || [name];
const isMap = (value) => Boolean(value) && typeof value === "object" && !Array.isArray(value);

/** Deny rules every non-activation agent receives, derived from the V1 global tool policy. */
export function globalMcpDenyRules(toolPolicy = {}) {
  return [
    rule(MCP_ACTIVATION_TOOL, "deny"),
    ...Object.entries(toolPolicy)
      .filter(([pattern, enabled]) => pattern && enabled !== true)
      .map(([pattern]) => rule(pattern, "deny")),
  ];
}

function toolEnablement(tools) {
  const enabled = new Map();
  for (const [name, value] of Object.entries(tools)) {
    for (const action of actionsFor(name)) {
      // Collapsed aliases (write/patch/edit) are enabled only if all are.
      enabled.set(action, (enabled.get(action) ?? true) && value === true);
    }
  }
  return enabled;
}

function toolDisabled(enabled, action) {
  if (action === "*") return enabled.get("*") === false;
  return enabled.get(action) === false || (enabled.get("*") === false && enabled.get(action) !== true);
}

function permissionRules(permission, enabled) {
  const rules = [];
  for (const [name, value] of Object.entries(permission)) {
    const entries = isMap(value) ? Object.entries(value) : [["*", value]];
    for (const [resource, effect] of entries) {
      const safeEffect = EFFECTS.has(effect) ? effect : "deny";
      for (const action of actionsFor(name)) {
        // V1 needs both the tool switch and the permission; never let a
        // permission allow/ask re-open a tool the source disabled.
        if (safeEffect !== "deny" && toolDisabled(enabled, action)) continue;
        rules.push(rule(action, safeEffect, resource));
      }
    }
  }
  return rules;
}

/**
 * Convert an authored V1 source's tools/permission maps into ordered V2 rules,
 * preserving every restriction (fail closed on unreadable or malformed input).
 */
export function sourceRestrictionRules(source) {
  if (source.unparsed) return [rule("*", "deny")];
  const tools = source.tools ?? {};
  const permission = source.permission ?? {};
  if (!isMap(tools) || !isMap(permission)) return [rule("*", "deny")];

  const enabled = toolEnablement(tools);
  const toolRules = [...enabled].map(([action, on]) => rule(action, on ? "allow" : "deny"));
  const wildcard = toolRules.filter(({ action }) => action === "*");
  const specific = toolRules.filter(({ action }) => action !== "*");
  return [
    ...wildcard,
    ...specific,
    ...permissionRules(permission, enabled),
    // Re-assert explicit tool denies after any broader permission allow.
    ...specific.filter(({ effect }) => effect === "deny"),
  ];
}

/**
 * Rules that let an activation agent connect and use exactly its own MCP.
 * `activation` replaces the default `aidevops_mcp` allow, so an operator's
 * explicit rule for the activation tool survives the global deny (V1 parity).
 */
export function activationRules(mcp, activation = [rule(MCP_ACTIVATION_TOOL, "allow")]) {
  const { permission } = onDemandMcpToolPolicy(mcp);
  return [
    ...activation,
    ...Object.entries(permission).map(([action, effect]) => rule(action, effect)),
  ];
}

const copyRule = ({ action, resource, effect }) => rule(action, effect, resource);

/**
 * Register V2 on-demand MCP activation agents and scope MCP tools to them.
 * Call inside `ctx.agent.transform` after primary registration so every agent
 * present receives the global denies. Operator agents with an activation name
 * keep their own settings and gain only the activation rules, as on V1.
 * @param {object} editor - V2 agent transform draft
 * @param {{agentsDir: string, toolPolicy?: object, mcps?: Array<object>}} options
 * @returns {number} Number of activation agents created
 */
export function registerV2OnDemandMcpAgents(editor, { agentsDir, toolPolicy = {}, mcps = getOnDemandMcpAgents() }) {
  const denies = globalMcpDenyRules(toolPolicy);
  const base = (editor.get(BASE_AGENT)?.permissions ?? []).map(copyRule);
  const operatorActivation = new Map(mcps.map((mcp) => [
    mcp.agentName,
    (editor.get(mcp.agentName)?.permissions ?? [])
      .filter(({ action }) => action === MCP_ACTIVATION_TOOL)
      .map(copyRule),
  ]));
  for (const agent of editor.list()) {
    editor.update(agent.id, (draft) => draft.permissions.push(...denies));
  }

  let created = 0;
  for (const mcp of mcps) {
    if (editor.get(mcp.agentName)) {
      const explicit = operatorActivation.get(mcp.agentName);
      const allow = activationRules(mcp, explicit.length ? explicit : undefined);
      editor.update(mcp.agentName, (draft) => draft.permissions.push(...allow));
      continue;
    }
    const allow = activationRules(mcp);
    const source = onDemandMcpSourceProfile(mcp, agentsDir);
    editor.update(mcp.agentName, (draft) => {
      draft.name = mcp.agentName;
      draft.description = source.description;
      draft.system = source.prompt;
      draft.mode = "subagent";
      draft.hidden = false;
      draft.permissions.push(...base, ...denies, ...sourceRestrictionRules(source), ...allow);
    });
    created++;
  }
  return created;
}
