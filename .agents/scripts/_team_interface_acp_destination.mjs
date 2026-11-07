// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {collectEventBlocks} from "./_team_interface_acp_events.mjs";

const UUID_PATTERN = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const EVENT_ID_PATTERN = "[0-9a-f]{64}";
const DIRECT_GREETING_REPLY = "Hi! What would you like to work on?";

// Buzz >= 0.5.28 wraps prompt sections in tags (`<context>…</context>`,
// `<buzz-event type="…">…</buzz-event>`); earlier releases used bracket
// headers (`[Context]`, `[Buzz event: …]`). A tagged section is accepted only
// when it spans the whole prompt block, then mapped to the bracket form so the
// trust checks below apply unchanged to both formats.
const TAGGED_CONTEXT = /^<context>\r?\n([\s\S]*)\r?\n<\/context>\s*$/u;
const TAGGED_EVENT = /^<buzz-event type="([^"\r\n<>]*)">\r?\n([\s\S]*)\r?\n<\/buzz-event>\s*$/u;

function normalizeBlock(text) {
  const context = text.match(TAGGED_CONTEXT);
  if (context) {
    return `[Context]\n${context[1]}`;
  }
  const event = text.match(TAGGED_EVENT);
  if (event) {
    return `[Buzz event: ${event[1]}]\n${event[2]}`;
  }
  return text;
}

function promptBlocks(message) {
  const prompt = message?.params?.prompt;
  if (!Array.isArray(prompt)) {
    return null;
  }
  return prompt
    .filter((block) => block && typeof block === "object" && typeof block.text === "string")
    .map((block) => normalizeBlock(block.text));
}

function isDirectGreeting(message) {
  const blocks = promptBlocks(message);
  if (!blocks) {
    return false;
  }
  const contextBlock = blocks.find((block) => block.startsWith("[Context]"));
  const eventBlock = [...blocks].reverse().find((block) => block.startsWith("[Buzz event:"));
  if (!contextBlock?.match(/^Scope: dm$/im) || !eventBlock) {
    return false;
  }
  const eventLines = eventBlock.split(/\r?\n/u);
  const contentIndex = eventLines.findIndex((line) => line.startsWith("Content: "));
  const tagsIndex = eventLines.findLastIndex((line) => line.startsWith("Tags: "));
  if (contentIndex < 0 || tagsIndex !== contentIndex + 1) {
    return false;
  }
  const content = eventLines[contentIndex].slice("Content: ".length).trim();
  return /^(?:hi|hello|hey|hiya|howdy|good (?:morning|afternoon|evening))[!.?]*$/iu.test(
    content || "",
  );
}

function trustedReplyInstructions(eventLines, contentIndex, tagsIndex) {
  const instructionPattern = new RegExp(
    "^IMPORTANT: [^\\r\\n]*use `--reply-to (" + EVENT_ID_PATTERN + ")`[^\\r\\n]*$",
    "i",
  );
  const instructions = [];
  for (const [index, line] of eventLines.entries()) {
    const trustedEnvelope = contentIndex < 0 || index < contentIndex ||
      (tagsIndex > contentIndex && index > tagsIndex);
    const instruction = line.match(instructionPattern);
    if (!instruction) {
      if (trustedEnvelope && line.startsWith("IMPORTANT: ") && line.includes("`--reply-to ")) {
        return null;
      }
      continue;
    }
    if (!trustedEnvelope) {
      return null;
    }
    instructions.push(instruction);
  }
  return instructions.length <= 1 ? instructions : null;
}

function parseContext(message) {
  const blocks = promptBlocks(message);
  const contextIndexes = blocks
    ?.map((block, index) => block.startsWith("[Context]") ? index : -1)
    .filter((index) => index >= 0) ?? [];
  if (contextIndexes.length !== 1) {
    return null;
  }
  const contextIndex = contextIndexes[0];
  const contextLines = blocks[contextIndex].split(/\r?\n/u);
  const collected = collectEventBlocks(blocks, contextIndex, contextLines);
  if (!collected || collected.eventBlocks.length === 0) {
    return null;
  }
  const contextHeader = collected.eventMarker < 0
    ? contextLines
    : contextLines.slice(0, collected.eventMarker);
  const channelLines = contextHeader.filter((line) => line.startsWith("Channel: "));
  const channel = channelLines.length === 1
    ? channelLines[0].match(new RegExp(`^Channel: [^\\r\\n]* \\(#(${UUID_PATTERN})\\)$`, "i"))
    : null;
  return channel ? {channel: channel[1], eventBlocks: collected.eventBlocks} : null;
}

function eventIndexes(eventLines) {
  return {
    content: eventLines
      .map((line, index) => line.startsWith("Content: ") ? index : -1)
      .filter((index) => index >= 0),
    tags: eventLines
      .map((line, index) => line.startsWith("Tags: ") ? index : -1)
      .filter((index) => index >= 0),
  };
}

function parseEventIdentity(eventLines, contentIndex) {
  const eventHeader = eventLines.slice(0, contentIndex < 0 ? undefined : contentIndex);
  const eventIdLines = eventHeader.filter((line) => line.startsWith("Event ID: "));
  const eventId = eventIdLines.length === 1
    ? eventIdLines[0].match(new RegExp(`^Event ID: (${EVENT_ID_PATTERN})$`, "i"))
    : null;
  const channelLines = eventHeader.filter((line) => line.startsWith("Channel: "));
  const channel = channelLines.length === 1
    ? channelLines[0].match(new RegExp(`^Channel: [^\\r\\n]* \\(#(${UUID_PATTERN})\\)$`, "i"))
    : null;
  return {channel, channelLineCount: channelLines.length, eventId};
}

function parseEvent(eventBlock, expectedChannel) {
  const {lines: eventLines, structured, requireChannel} = eventBlock;
  const indexes = eventIndexes(eventLines);
  const validStructure = !structured ||
    (indexes.content.length === 1 && indexes.tags.length === 1 &&
      indexes.tags[0] > indexes.content[0]);
  if (!validStructure) {
    return null;
  }
  const contentIndex = indexes.content[0] ?? -1;
  const tagsIndex = indexes.tags.at(-1) ?? -1;
  const identity = parseEventIdentity(eventLines, contentIndex);
  const channelMatches = (!requireChannel || identity.channelLineCount === 1) && identity.channelLineCount <= 1 &&
    (identity.channelLineCount === 0 || identity.channel?.[1] === expectedChannel);
  if (!identity.eventId || !channelMatches) {
    return null;
  }
  const instructedReplies = trustedReplyInstructions(eventLines, contentIndex, tagsIndex);
  const structuredFallback = structured && contentIndex >= 0 && tagsIndex > contentIndex &&
    identity.channelLineCount === 1;
  if (!instructedReplies || (instructedReplies.length === 0 && !structuredFallback)) {
    return null;
  }
  return instructedReplies[0]?.[1] ?? identity.eventId[1];
}

export function trustedReplyDestination(message) {
  const context = parseContext(message);
  const replies = context?.eventBlocks.map((event) => parseEvent(event, context.channel));
  const replyTo = replies?.every(Boolean) ? replies.at(-1) : null;
  if (!context || !replyTo) {
    return null;
  }
  return {
    channel: context.channel,
    directGreeting: isDirectGreeting(message),
    replyTo,
  };
}

export {DIRECT_GREETING_REPLY};
