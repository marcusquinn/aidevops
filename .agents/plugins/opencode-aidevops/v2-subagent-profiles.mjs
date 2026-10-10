// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// OpenCode V2 counterpart of V1's non-primary registrations (GH#34227):
// research-only, specialist-advisor and the domain-focused/domain-light roles.
// The V1 builders are reused unchanged against a scratch config, then each
// resulting profile is converted to ordered V2 permission rules.

import { registerDelegatedDomainProfiles } from "./agent-loader.mjs";
import { registerResearchOnlyAgent } from "./config-agent-profiles.mjs";
import { registerSpecialistAdvisor } from "./specialist-advisor.mjs";
import { sourceRestrictionRules } from "./v2-on-demand-mcp-agents.mjs";

// Host built-in subagent carrying host defaults, as in the MCP activation agents.
const BASE_AGENT = "general";
const copyRule = ({ action, resource, effect }) => ({ action, resource, effect });

/**
 * Register V2 research/advisory subagents. Call inside `ctx.agent.transform`
 * before registerV2OnDemandMcpAgents so the global MCP denies reach them.
 * Operator-defined agents with the same name take precedence.
 * @param {object} editor - V2 agent transform draft
 * @param {{agentsDir: string, routing?: object, env?: object}} options
 * @returns {number} Number of agents created
 */
export function registerV2SubagentProfiles(editor, { agentsDir, routing, env = process.env }) {
  const scratch = { agent: {} };
  const state = { tiers: new Map(), pinned: new Set() };
  registerResearchOnlyAgent(scratch, agentsDir, env);
  registerSpecialistAdvisor(scratch, agentsDir, routing, state);
  registerDelegatedDomainProfiles(scratch, agentsDir, state);

  const base = (editor.get(BASE_AGENT)?.permissions ?? []).map(copyRule);
  let created = 0;
  for (const [name, profile] of Object.entries(scratch.agent)) {
    if (editor.get(name)) continue;
    // An unusable canonical source (V1 sets disable) must not become a live agent.
    if (profile.disable || typeof profile.prompt !== "string" || !profile.prompt) continue;
    const rules = sourceRestrictionRules({
      tools: profile.tools,
      permission: profile.permission,
      unparsed: !profile.tools || !profile.permission,
    });
    editor.update(name, (draft) => {
      draft.name = name;
      draft.description = profile.description;
      draft.system = profile.prompt;
      draft.mode = "subagent";
      draft.hidden = false;
      draft.permissions.push(...base, ...rules);
    });
    created++;
  }
  return created;
}
