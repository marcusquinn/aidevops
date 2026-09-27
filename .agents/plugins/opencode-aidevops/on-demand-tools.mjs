// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * On-demand dispatcher for rarely used plugin tools (GH#32592).
 *
 * OpenCode 1 sends every registered tool schema on every model request. Tools
 * used in only a handful of sessions move behind one compact dispatcher whose
 * description carries a one-line signature per sub-tool. Omitting `args`
 * returns the full sub-tool schema without executing; invalid `args` return
 * the validation issues plus that schema so the model can self-correct.
 *
 * OpenCode 2 already defers plugin tools into its Code Mode catalogue, so only
 * the V1 entrypoint (index.mjs) applies this. Per-agent gated tools (for
 * example aidevops_mcp) and frequently used tools stay direct.
 */

export const ON_DEMAND_TOOL = "aidevops_on_demand";
export const ON_DEMAND_TOOL_NAMES = Object.freeze([
  "gpt_image_generate",
  "model-accounts-pool",
  "aidevops_objective_receipt",
]);

// provider-auth-body.mjs injects this into top-level tool schemas only; a model
// that copies it into nested args must not fail strict sub-tool validation.
const INTENT_KEY = "agent__intent";

function firstSentence(text) {
  const value = String(text || "").replace(/\s+/g, " ").trim();
  const match = value.match(/^.*?[.!?](?=\s|$)/);
  return match ? match[0] : value;
}

function subToolSchema(z, args) {
  if (typeof z?.strictObject === "function") return z.strictObject(args || {});
  if (typeof z?.object === "function") return z.object(args || {});
  return null;
}

function toJsonSchema(z, schema) {
  if (!schema || typeof z?.toJSONSchema !== "function") return null;
  try {
    const { $schema: _dialect, ...rest } = z.toJSONSchema(schema);
    return rest;
  } catch {
    return null;
  }
}

function signatureOf(entry) {
  const properties = entry.jsonSchema?.properties;
  if (!properties) return Object.keys(entry.definition.args || {}).join(", ");
  const required = new Set(entry.jsonSchema.required || []);
  return Object.entries(properties)
    .map(([key, property]) => {
      if (!required.has(key)) return `${key}?`;
      return Array.isArray(property?.enum) ? `${key}: ${property.enum.join("|")}` : key;
    })
    .join(", ");
}

function fullSchemaText(name, entry) {
  const schema = entry.jsonSchema
    ? JSON.stringify(entry.jsonSchema)
    : `{${Object.keys(entry.definition.args || {}).join(", ")}}`;
  return `${name}: ${entry.definition.description}\nargs JSON schema: ${schema}`;
}

function formatIssues(issues) {
  return (issues || [])
    .map((issue) => `${(issue.path || []).join(".") || "args"}: ${issue.message}`)
    .join("; ");
}

function openArgsSchema(z) {
  if (typeof z?.looseObject === "function") return z.looseObject({});
  if (typeof z?.object === "function") return z.object({}).passthrough();
  return z.string(); // fallback helper placeholder; the host never validates it
}

/**
 * Build the dispatcher tool for the given sub-tool definitions.
 * @param {Function} tool - OpenCode V1 tool helper (tool.schema is Zod)
 * @param {Record<string, {description: string, args?: object, execute: Function}>} subTools
 * @returns {object} Tool definition
 */
export function createOnDemandTool(tool, subTools) {
  const z = tool.schema;
  const entries = new Map(Object.entries(subTools).map(([name, definition]) => {
    const schema = subToolSchema(z, definition.args);
    return [name, { definition, schema, jsonSchema: toJsonSchema(z, schema) }];
  }));
  const names = [...entries.keys()];
  const lines = names.map((name) => {
    const entry = entries.get(name);
    return `- ${name}(${signatureOf(entry)}): ${firstSentence(entry.definition.description)}`;
  });

  return tool({
    description: [
      "Run a rarely used aidevops tool by name with args. Omit args to get its full schema; invalid args also return it.",
      ...lines,
    ].join("\n"),
    args: {
      tool: z.enum(names).describe("Tool name"),
      args: openArgsSchema(z).optional().describe("That tool's arguments"),
    },
    async execute(input, context) {
      const name = String(input?.tool || "");
      const entry = entries.get(name);
      if (!entry) throw new Error(`Unknown on-demand tool "${name}". Available: ${names.join(", ")}.`);
      if (input.args === undefined || input.args === null) {
        return `${fullSchemaText(name, entry)}\nRun it with {tool:"${name}", args:{...}}.`;
      }
      if (typeof input.args !== "object" || Array.isArray(input.args)) {
        throw new Error(`args must be an object.\n${fullSchemaText(name, entry)}`);
      }
      const { [INTENT_KEY]: _intent, ...args } = input.args;
      if (!entry.schema) return entry.definition.execute(args, context);
      const parsed = entry.schema.safeParse(args);
      if (!parsed.success) {
        throw new Error(`Invalid args for ${name}: ${formatIssues(parsed.error?.issues)}\n${fullSchemaText(name, entry)}`);
      }
      return entry.definition.execute(parsed.data, context);
    },
  });
}

/**
 * Move the named tools behind the on-demand dispatcher, in place.
 * Missing names are ignored; no dispatcher is added when none are present.
 * @param {Record<string, object>} tools
 * @param {Function} tool - OpenCode V1 tool helper
 * @param {readonly string[]} [names]
 * @returns {Record<string, object>} The same tools map
 */
export function moveToolsOnDemand(tools, tool, names = ON_DEMAND_TOOL_NAMES) {
  const subTools = {};
  for (const name of names) {
    if (!tools[name]) continue;
    subTools[name] = tools[name];
    delete tools[name];
  }
  if (Object.keys(subTools).length) tools[ON_DEMAND_TOOL] = createOnDemandTool(tool, subTools);
  return tools;
}
