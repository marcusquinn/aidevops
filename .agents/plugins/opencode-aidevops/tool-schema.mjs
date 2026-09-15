// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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
  boolean: () => FALLBACK_SCHEMA_NODE,
  enum: () => FALLBACK_SCHEMA_NODE,
  string: () => FALLBACK_SCHEMA_NODE,
  number: () => FALLBACK_SCHEMA_NODE,
  union: () => FALLBACK_SCHEMA_NODE,
};

function createFallbackToolHelper() {
  const fallback = (definition) => definition;
  fallback.schema = FALLBACK_TOOL_SCHEMA;
  return fallback;
}

function withFallbackToolSchema(candidate) {
  const compatible = (definition) => candidate(definition);
  Object.assign(compatible, candidate);
  compatible.schema = { ...FALLBACK_TOOL_SCHEMA, ...candidate.schema };
  return compatible;
}

export async function loadV1ToolHelper(options = {}) {
  const importer = options.importer || ((specifier) => import(specifier));
  const requirePinnedRuntime = options.requirePinnedRuntime
    ?? process.env.AIDEVOPS_REMOTE_REQUIRE_PINNED_RUNTIME === "1";
  let lastError;
  for (const specifier of ["@opencode-ai/plugin/v1", "@opencode-ai/plugin"]) {
    try {
      const candidate = (await importer(specifier))?.tool;
      if (typeof candidate === "function" && candidate.schema) return withFallbackToolSchema(candidate);
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
  return createFallbackToolHelper();
}

export const tool = await loadV1ToolHelper();
