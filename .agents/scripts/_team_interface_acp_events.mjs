// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const TAGGED_EVENTS = /^<(buzz-events|new-message-arrived-while-you-were-working|new-request-supersedes-previous)(?: count="(\d+)")?>\r?\n([\s\S]*)\r?\n<\/\1>\s*$/u;
const BATCH_OPEN = /^<(?:buzz-events|new-message-arrived-while-you-were-working|new-request-supersedes-previous)[\s>]/u;
const BATCH_SEPARATOR = /^--- Event (\d+) \([^\r\n]*\) ---\r?$/mu;

// Event blocks for a tagged batch wrapper, or null when invalid. Content can
// forge separators, so a wrapper must declare a matching count; a count-less
// wrapper is accepted only for a single event.
function parseBatch(batch) {
  const parts = batch[3].split(BATCH_SEPARATOR);
  const events = (parts.length - 1) / 2;
  const countOk = batch[2] ? Number(batch[2]) === events : events === 1;
  if (parts[0].trim() || parts.length < 3 || !countOk) {
    return null;
  }
  const found = [];
  for (let part = 1; part < parts.length; part += 2) {
    if (Number(parts[part]) !== (part + 1) / 2) {
      return null;
    }
    found.push({lines: parts[part + 1].split(/\r?\n/u), structured: true, requireChannel: true});
  }
  return found;
}

// Event blocks in one prompt block; null for a malformed batch wrapper,
// empty for unrelated text.
function blockEvents(block) {
  if (block.startsWith("[Buzz event:")) {
    return [{lines: block.split(/\r?\n/u), structured: true}];
  }
  const batch = block.match(TAGGED_EVENTS);
  if (batch) {
    return parseBatch(batch);
  }
  return BATCH_OPEN.test(block) ? null : [];
}

export function collectEventBlocks(blocks, contextIndex, contextLines) {
  const eventMarker = contextLines.indexOf("[Event]");
  const eventBlocks = [];
  let eventGroups = 0;
  if (eventMarker >= 0) {
    eventGroups = 1;
    eventBlocks.push({lines: contextLines.slice(eventMarker + 1), structured: false});
  }
  for (const [index, block] of blocks.entries()) {
    const found = blockEvents(block);
    if (!found || (found.length > 0 && index <= contextIndex)) {
      return null;
    }
    if (found.length > 0) {
      eventGroups += 1;
      eventBlocks.push(...found);
    }
  }
  return eventGroups === 1 ? {eventBlocks, eventMarker} : null;
}
