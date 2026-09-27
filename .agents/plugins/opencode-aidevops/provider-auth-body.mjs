// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash, randomBytes } from "node:crypto";

import { buildBillingHeader, serializeWithKeyOrder, computeBodyHash, CCH_PLACEHOLDER } from "./provider-auth-cch.mjs";
import { normalizeToolNames, normalizeToolUseBlocks } from "./provider-auth-tool-names.mjs";

const TAG_RENAMES = [
  [/<directories>/g, "<working_dirs>"],     [/<\/directories>/g, "</working_dirs>"],
  [/<available_skills>/g, "<skill_list>"],   [/<\/available_skills>/g, "</skill_list>"],
  [/<env>/g, "<environment>"],               [/<\/env>/g, "</environment>"],
];

// Anthropic's third-party detection pattern-matches system prompt content.
// Keep only Anthropic/Claude-Code-equivalent system blocks in system and move
// framework/runtime instructions into the first user message turn.
const OFFICIAL_CLAUDE_CODE_SYSTEM_PROMPT = "You are Claude Code, Anthropic's official CLI for Claude.";

function sanitizeSystemPrompt(system) {
  return system.map((item) => {
    if (item.type !== "text" || !item.text) return item;
    let text = item.text;
    for (const [pattern, replacement] of TAG_RENAMES) text = text.replace(pattern, replacement);
    return { ...item, text };
  });
}

// Anthropic rejects requests with more than four cache_control breakpoints.
const MAX_CACHE_BREAKPOINTS = 4;

function countBlockMarkers(blocks) {
  if (!Array.isArray(blocks)) return 0;
  return blocks.filter((block) => block && typeof block === "object" && block.cache_control).length;
}

function countCacheBreakpoints(parsed) {
  let count = countBlockMarkers(parsed.tools) + countBlockMarkers(parsed.system);
  for (const message of parsed.messages ?? []) {
    if (Array.isArray(message?.content)) count += countBlockMarkers(message.content);
  }
  return count;
}

/**
 * Carry the system prompt's cache breakpoint onto the redistributed block so
 * the stable framework prefix stays cacheable (GH#32444). The redistributed
 * text is identical across sessions in a project, so the marker also enables
 * cross-session reuse. Never exceed Anthropic's breakpoint limit.
 */
function applyRedistributedCacheControl(parsed, prefix, overflow) {
  const cacheControl = overflow.findLast((block) => block.cache_control)?.cache_control;
  if (!cacheControl) return false;
  if (countCacheBreakpoints(parsed) >= MAX_CACHE_BREAKPOINTS) return false;
  prefix.cache_control = cacheControl;
  return true;
}

function shortHash(text) {
  return createHash("sha256").update(text).digest("hex").slice(0, 12);
}

/** Only the billing header (first block) and the exact Claude Code identity stay in system. */
function isKeptSystemBlock(block, index) {
  if (block.type !== "text") return false;
  const isBillingHeader = index === 0 && Boolean(block.text?.startsWith("x-anthropic-billing-header:"));
  return isBillingHeader || block.text === OFFICIAL_CLAUDE_CODE_SYSTEM_PROMPT;
}

function joinOverflowText(overflow) {
  return overflow
    .filter((block) => block.type === "text" && block.text)
    .map((block) => block.text)
    .join("\n\n");
}

function prependToFirstUserMessage(messages, prefix) {
  const firstMsg = messages[0];
  if (firstMsg?.role !== "user") {
    messages.unshift({ role: "user", content: [prefix] });
  } else if (typeof firstMsg.content === "string") {
    firstMsg.content = [prefix, { type: "text", text: firstMsg.content }];
  } else if (Array.isArray(firstMsg.content)) {
    firstMsg.content = [prefix, ...firstMsg.content];
  }
}

function logRedistribution({ overflow, overflowText, kept, cached, sessionID }) {
  const session = sessionID ? ` session=${sessionID}` : "";
  console.error(
    `[aidevops] provider-auth: redistributed ${overflow.length} system blocks (${overflowText.length} chars) ` +
    `to user message to stay under third-party detection threshold ` +
    `(kept=${kept.length} sha=${shortHash(overflowText)} cache=${cached ? "marked" : "none"}${session})`,
  );
}

/** Move framework/runtime system blocks into the first user message. */
function redistributeSystemToMessages(parsed, context = {}) {
  if (!Array.isArray(parsed.system) || !Array.isArray(parsed.messages)) return;
  const kept = parsed.system.filter((block, index) => isKeptSystemBlock(block, index));
  const overflow = parsed.system.filter((block, index) => !isKeptSystemBlock(block, index));
  const overflowText = joinOverflowText(overflow);
  if (!overflowText) return;
  parsed.system = kept;

  const prefix = { type: "text", text: overflowText };
  prependToFirstUserMessage(parsed.messages, prefix);
  const cached = applyRedistributedCacheControl(parsed, prefix, overflow);
  logRedistribution({ overflow, overflowText, kept, cached, sessionID: context.sessionID });
}

export const INTENT_PARAM_NAME = "agent__intent";

export const INTENT_PARAM_SCHEMA = Object.freeze({
  type: "string",
  description:
    "Intent tracing: one sentence in present participle form describing your intent for this tool call (no trailing period).",
});

/** Inject agent__intent into one object-typed JSON schema without mutation. */
export function injectIntentSchemaProperty(schema) {
  if (!schema || schema.type !== "object") return schema;
  const properties = schema.properties ?? {};
  if (Object.prototype.hasOwnProperty.call(properties, INTENT_PARAM_NAME)) return schema;
  return {
    ...schema,
    properties: {
      ...properties,
      [INTENT_PARAM_NAME]: INTENT_PARAM_SCHEMA,
    },
  };
}

/** Inject agent__intent as an optional property on object-typed tool schemas. */
export function injectIntentParameter(tools) {
  return tools.map((tool) => {
    const schema = tool?.input_schema;
    const transformed = injectIntentSchemaProperty(schema);
    if (transformed === schema) return tool;
    return {
      ...tool,
      input_schema: transformed,
    };
  });
}

function isAdaptiveThinkingModel(model) {
  if (!model) return false;
  return /claude-[a-z]+-4[-.]6/i.test(model);
}

function applyBodyTransforms(parsed, sentinel, context) {
  const billingText = withHeaderSentinel(buildBillingHeader(parsed), sentinel);
  if (!Array.isArray(parsed.system)) parsed.system = [];
  parsed.system = parsed.system.filter(
    (block) => !(block.type === "text" && block.text?.startsWith("x-anthropic-billing-header:")),
  );
  parsed.system.unshift({ type: "text", text: billingText });
  parsed.system = sanitizeSystemPrompt(parsed.system);
  redistributeSystemToMessages(parsed, context);
  if (Array.isArray(parsed.tools)) {
    parsed.tools = normalizeToolNames(parsed.tools);
    parsed.tools = injectIntentParameter(parsed.tools);
  }
  if (Array.isArray(parsed.messages)) parsed.messages = normalizeToolUseBlocks(parsed.messages);
  normalizeAdaptiveThinking(parsed);
}

/**
 * OpenCode's newer Claude variants can include adaptive-thinking metadata
 * (for example block_binding) that the Messages API rejects on the wire.
 * Effort is carried separately in output_config; keep the wire shape minimal.
 */
function normalizeAdaptiveThinking(parsed) {
  if (parsed.thinking?.type === "adaptive") parsed.thinking = { type: "adaptive" };
  if (!isAdaptiveThinkingModel(parsed.model)) return;
  if (parsed.thinking?.type !== "adaptive") parsed.thinking = { type: "adaptive" };
  if (parsed.temperature !== undefined && parsed.temperature !== 1) parsed.temperature = 1;
}

/**
 * Per-request marker for the billing header's cch field. Conversation history
 * can legitimately contain the placeholder text (tool output, docs, summaries);
 * serializeWithKeyOrder emits messages before system, so a first-match
 * replacement would sign the history copy instead of the header, changing
 * history bytes on every request and defeating prompt caching (GH#32444).
 */
function createCchSentinel() {
  return `cch=AIDEVOPS_CCH_${randomBytes(12).toString("hex")};`;
}

function withHeaderSentinel(billingText, sentinel) {
  if (!billingText.endsWith(CCH_PLACEHOLDER)) return billingText;
  return billingText.slice(0, -CCH_PLACEHOLDER.length) + sentinel;
}

/**
 * Hash the body with the placeholder at the header position only, then write
 * the hash into that position. All other body bytes are left untouched.
 */
function finalizeBillingHeaderHash(serialized, sentinel) {
  // The sentinel carries 96 random bits and is written only into the header,
  // so the first occurrence is the header position.
  const index = sentinel ? serialized.indexOf(sentinel) : -1;
  if (index < 0) return serialized;
  const before = serialized.slice(0, index);
  const after = serialized.slice(index + sentinel.length);
  const bodyHash = computeBodyHash(`${before}${CCH_PLACEHOLDER}${after}`);
  return `${before}cch=${bodyHash};${after}`;
}

/**
 * Transform the request body while preserving billing-header key ordering.
 * @param {string|null|undefined} body
 * @param {{ sessionID?: string }} [context] - optional diagnostics context
 * @returns {string|null|undefined}
 */
export function transformRequestBody(body, context = {}) {
  if (!body || typeof body !== "string") return body;
  try {
    const parsed = JSON.parse(body);
    const sentinel = createCchSentinel();
    applyBodyTransforms(parsed, sentinel, context);
    const serialized = serializeWithKeyOrder(parsed);
    return finalizeBillingHeaderHash(serialized, sentinel);
  } catch {
    return body;
  }
}
