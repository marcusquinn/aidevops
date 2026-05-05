import assert from "node:assert/strict";
import test from "node:test";

function streamResponse(text, init = {}) {
  return new Response(new Blob([text]).stream(), {
    status: init.status || 200,
    headers: { "content-type": "text/event-stream" },
  });
}

async function readStreamFailure(response) {
  const reader = response.body.getReader();
  await assert.rejects(async () => {
    while (true) {
      const { done } = await reader.read();
      if (done) return;
    }
  }, /OpenAI provider: retry response missing body \(status: 204\)/);
}

test("retry missing-body errors include retry response status", async () => {
  process.env.AIDEVOPS_OPENAI_OVERLOAD_RETRY_DELAYS_MS = "0";
  const { wrapOpenAIOverloadStream } = await import(`../openai-overload-retry.mjs?test=${Date.now()}-${Math.random()}`);
  const response = streamResponse('{"type":"error","error":{"code":"server_is_overloaded"}}');
  const wrapped = wrapOpenAIOverloadStream({
    response,
    originalFetch: async () => new Response(null, { status: 204 }),
    retryInput: "https://api.openai.com/v1/responses",
    init: {},
    buildRetryRequest: (input) => input,
  });

  await readStreamFailure(wrapped);
});

test("default overload retry delays span minutes", async () => {
  delete process.env.AIDEVOPS_OPENAI_OVERLOAD_RETRY_DELAYS_MS;
  const { overloadRetryDelaysMs } = await import(`../openai-overload-retry.mjs?test=${Date.now()}-${Math.random()}`);
  assert.deepEqual(overloadRetryDelaysMs(), [3_000, 10_000, 30_000, 60_000, 120_000, 180_000]);
});

test("stream retries notify before delay and annotate exhausted overload", async () => {
  process.env.AIDEVOPS_OPENAI_OVERLOAD_RETRY_DELAYS_MS = "0";
  const { wrapOpenAIOverloadStream } = await import(`../openai-overload-retry.mjs?test=${Date.now()}-${Math.random()}`);
  const retries = [];
  const response = streamResponse('data: {"type":"error","error":{"type":"service_unavailable_error","code":"server_is_overloaded","message":"Our servers are currently overloaded. Please try again later."}}\n\n');
  const wrapped = wrapOpenAIOverloadStream({
    response,
    originalFetch: async () => streamResponse('data: {"type":"error","error":{"type":"service_unavailable_error","code":"server_is_overloaded","message":"Our servers are currently overloaded. Please try again later."}}\n\n'),
    retryInput: "https://api.openai.com/v1/responses",
    init: {},
    buildRetryRequest: (input) => input,
    onRetry: (retry) => retries.push(retry),
  });

  const text = await wrapped.text();
  assert.equal(retries.length, 1);
  assert.equal(retries[0].delayLabel, "0ms");
  assert.match(text, /aidevops attempted automatic recovery/);
});

test("annotated overload responses drop stale content length", async () => {
  const { annotateOpenAIOverloadResponse } = await import(`../openai-overload-retry.mjs?test=${Date.now()}-${Math.random()}`);
  const response = new Response('{"error":{"code":"server_is_overloaded","message":"overloaded"}}', {
    status: 529,
    headers: {
      "content-length": "63",
      "content-type": "application/json",
    },
  });

  const annotated = await annotateOpenAIOverloadResponse(response);
  assert.equal(annotated.headers.get("content-length"), null);
  assert.equal(annotated.headers.get("content-type"), "application/json");
  assert.match(await annotated.text(), /aidevops attempted automatic recovery/);
});
