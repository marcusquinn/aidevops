/**
 * Thinking-tag filter and SSE streaming helpers for cursor/proxy.js.
 * Extracted to keep per-file complexity below the threshold.
 */

const THINKING_TAG_NAMES = ['think', 'thinking', 'reasoning', 'thought', 'think_intent'];
const MAX_THINKING_TAG_LEN = 16;
const THINKING_TAG_RE_SRC = `<(/?)(?:${THINKING_TAG_NAMES.join('|')})\\s*>`;

export const SSE_HEADERS = {
  "Content-Type": "text/event-stream",
  "Cache-Control": "no-cache",
  Connection: "keep-alive",
};

/**
 * Scan a string for thinking-tag boundaries.
 * @param {string} input @param {boolean} initialInThinking
 */
export function classifyTagSections(input, initialInThinking) {
  let content = '';
  let reasoning = '';
  let lastIdx = 0;
  let inThinking = initialInThinking;
  const re = new RegExp(THINKING_TAG_RE_SRC, 'gi');
  let match;
  while ((match = re.exec(input)) !== null) {
    const before = input.slice(lastIdx, match.index);
    if (inThinking) reasoning += before;
    else content += before;
    inThinking = match[1] !== '/';
    lastIdx = re.lastIndex;
  }
  return { content, reasoning, rest: input.slice(lastIdx), inThinking };
}

/**
 * Check whether the trailing portion of a string looks like a partial thinking tag.
 * @param {string} rest
 */
export function checkForPartialTag(rest) {
  const ltPos = rest.lastIndexOf('<');
  if (ltPos >= 0 && rest.length - ltPos < MAX_THINKING_TAG_LEN && /^<\/?[a-z_]*$/i.test(rest.slice(ltPos))) {
    return { buffer: rest.slice(ltPos), before: rest.slice(0, ltPos) };
  }
  return { buffer: '', before: rest };
}

/** Create a stateful thinking-tag filter for streamed text. */
export function createThinkingTagFilter() {
  let buffer = '';
  let inThinking = false;
  return {
    process(text) {
      const input = buffer + text;
      buffer = '';
      const sections = classifyTagSections(input, inThinking);
      inThinking = sections.inThinking;
      const { buffer: newBuf, before } = checkForPartialTag(sections.rest);
      buffer = newBuf;
      const content = sections.content + (inThinking ? '' : before);
      const reasoning = sections.reasoning + (inThinking ? before : '');
      return { content, reasoning };
    },
    flush() {
      const b = buffer;
      buffer = '';
      if (!b) return { content: '', reasoning: '' };
      return inThinking ? { content: '', reasoning: b } : { content: b, reasoning: '' };
    },
  };
}

/** Build SSE sender helpers bound to a ReadableStream controller. */
export function createSSESenders(controller, completionId, created, modelId) {
  const encoder = new TextEncoder();
  let closed = false;
  const sendSSE = (data) => { if (!closed) controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`)); };
  const sendDone = () => { if (!closed) controller.enqueue(encoder.encode("data: [DONE]\n\n")); };
  const closeController = () => { if (!closed) { closed = true; controller.close(); } };
  const makeChunk = (delta, finishReason = null) => ({
    id: completionId, object: "chat.completion.chunk", created, model: modelId,
    choices: [{ index: 0, delta, finish_reason: finishReason }],
  });
  return { sendSSE, sendDone, closeController, makeChunk };
}

/** Flush tag filter and send any buffered reasoning/content as SSE. */
export function flushTagFilterToSSE(tagFilter, makeChunk, sendSSE) {
  const flushed = tagFilter.flush();
  if (flushed.reasoning) sendSSE(makeChunk({ reasoning_content: flushed.reasoning }));
  if (flushed.content) sendSSE(makeChunk({ content: flushed.content }));
}
