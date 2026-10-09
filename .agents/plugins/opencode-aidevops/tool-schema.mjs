// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { recordPluginHealthStage } from "./plugin-health.mjs";

// Definition-only placeholders keep dependency-free unit tests usable. They are
// NOT Zod schemas and must never reach a host's tool registry or V2 adapter.
const FALLBACK_SCHEMA_NODE = {
  _zod: {},
  optional() {
    return this;
  },
  describe() {
    return this;
  },
};
const FALLBACK_TOOL_SCHEMA = {
  array: () => FALLBACK_SCHEMA_NODE,
  enum: () => FALLBACK_SCHEMA_NODE,
  string: () => FALLBACK_SCHEMA_NODE,
  number: () => FALLBACK_SCHEMA_NODE,
  union: () => FALLBACK_SCHEMA_NODE,
};

function createFallbackToolHelper() {
  const fallback = (definition) => definition;
  fallback.schema = FALLBACK_TOOL_SCHEMA;
  fallback.schemasUnavailable = true;
  return fallback;
}

export function hasToolSchemas(helper) {
  try {
    return typeof helper === "function"
      && typeof helper.schema?.object === "function"
      && typeof helper.schema?.string === "function"
      && typeof helper.schema.string()._zod?.def?.type === "string";
  } catch {
    return false;
  }
}

export async function loadV1ToolHelper(options = {}) {
  const importer = options.importer || ((specifier) => import(specifier));
  const requirePinnedRuntime = options.requirePinnedRuntime
    ?? process.env.AIDEVOPS_REMOTE_REQUIRE_PINNED_RUNTIME === "1";
  let lastError;
  for (const specifier of ["@opencode-ai/plugin/v1", "@opencode-ai/plugin"]) {
    try {
      const candidate = (await importer(specifier))?.tool;
      if (hasToolSchemas(candidate)) return candidate;
      lastError = new TypeError(`${specifier} does not export V1 tool schemas`);
    } catch (error) {
      lastError = error;
    }
  }
  if (requirePinnedRuntime) {
    throw new Error("Pinned remote runtime cannot resolve @opencode-ai/plugin V1 schemas", {
      cause: lastError,
    });
  }
  // Probe-only factories intentionally register no tools, regardless of schemas.
  if (process.env.AIDEVOPS_PLUGIN_HEALTH_PROBE_ONLY !== "1") {
    recordPluginHealthStage("custom_tools_disabled", {
      reason: "@opencode-ai/plugin V1 schemas unavailable",
    });
  }
  console.warn("[aidevops plugin-health] Custom tools not registered: @opencode-ai/plugin V1 schemas unavailable");
  return createFallbackToolHelper();
}

export const tool = await loadV1ToolHelper();
