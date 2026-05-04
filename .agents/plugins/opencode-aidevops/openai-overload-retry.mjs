// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const DEFAULT_OVERLOAD_RETRY_DELAYS_MS = [2_000, 5_000, 10_000];
const OVERLOAD_MARKERS = ["service_unavailable_error", "server_is_overloaded", "servers are currently overloaded"];
const STREAM_CONTENT_MARKERS = [
  "response.output_text.delta",
  "response.function_call_arguments.delta",
  "response.code_interpreter_call_code.delta",
  "response.reasoning_summary_text.delta",
];

export function overloadRetryDelaysMs() {
  const raw = process.env.AIDEVOPS_OPENAI_OVERLOAD_RETRY_DELAYS_MS || "";
  const parsed = raw
    .split(",")
    .map((part) => Number.parseInt(part.trim(), 10))
    .filter((value) => Number.isFinite(value) && value >= 0);
  return parsed.length > 0 ? parsed : DEFAULT_OVERLOAD_RETRY_DELAYS_MS;
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function isOpenAIOverloadText(text) {
  const lowered = String(text || "").toLowerCase();
  return OVERLOAD_MARKERS.some((marker) => lowered.includes(marker));
}

function isOpenAIStreamContentText(text) {
  return STREAM_CONTENT_MARKERS.some((marker) => String(text || "").includes(marker));
}

function enqueueChunks(controller, chunks) {
  for (const chunk of chunks) controller.enqueue(chunk);
}

async function pipeRemainingStream(reader, controller) {
  while (true) {
    const { done, value } = await reader.read();
    if (done) return controller.close();
    controller.enqueue(value);
  }
}

async function inspectStreamPrefix(reader, controller, decoder, retryAvailable) {
  const buffered = [];
  let bufferedText = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      enqueueChunks(controller, buffered);
      controller.close();
      return "closed";
    }

    buffered.push(value);
    bufferedText += decoder.decode(value, { stream: true });

    if (isOpenAIOverloadText(bufferedText)) {
      if (!retryAvailable) {
        enqueueChunks(controller, buffered);
        return "pipe";
      }
      await reader.cancel().catch(() => {});
      return "retry";
    }

    if (isOpenAIStreamContentText(bufferedText) || bufferedText.length > 65_536) {
      enqueueChunks(controller, buffered);
      return "pipe";
    }
  }
}

async function retryOpenAIOverloadStream(ctx) {
  const { originalFetch, response, retryInput, init, controller, retryDelays, buildRetryRequest } = ctx;
  const decoder = new TextDecoder();
  let currentResponse = response;

  for (let attempt = 0; ; attempt += 1) {
    const reader = currentResponse.body.getReader();
    const outcome = await inspectStreamPrefix(reader, controller, decoder, attempt < retryDelays.length);
    if (outcome === "closed") return;
    if (outcome === "pipe") return pipeRemainingStream(reader, controller);

    const delayMs = retryDelays[attempt];
    console.error(`[aidevops] OpenAI provider: overloaded stream error — retrying request (${attempt + 1}/${retryDelays.length})`);
    if (delayMs > 0) await sleep(delayMs);
    currentResponse = await originalFetch(buildRetryRequest(retryInput), init);
    if (!currentResponse.body) return controller.close();
  }
}

export function wrapOpenAIOverloadStream(ctx) {
  const { response } = ctx;
  if (!response.body) return response;
  const contentType = response.headers?.get?.("content-type") || "";
  if (!contentType.includes("text/event-stream")) return response;

  const retryDelays = overloadRetryDelaysMs();
  const stream = new ReadableStream({
    async start(controller) {
      try {
        await retryOpenAIOverloadStream({ ...ctx, controller, retryDelays });
      } catch (err) {
        controller.error(err);
      }
    },
  });

  return new Response(stream, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}
