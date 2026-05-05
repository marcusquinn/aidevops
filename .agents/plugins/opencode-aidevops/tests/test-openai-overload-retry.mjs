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
    retryInput: "https://api.openai.example/v1/responses",
    init: {},
    buildRetryRequest: (input) => input,
  });

  await readStreamFailure(wrapped);
});
