// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { parseImageSse, requestApiImage, requestOAuthImage, requestOpenRouterImage } from "../gpt-image-request.mjs";

const IMAGE_RESULT = "aW1hZ2UtcmVzdWx0";

function splitStream(text, splitAt) {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(text.slice(0, splitAt)));
      controller.enqueue(encoder.encode(text.slice(splitAt)));
      controller.close();
    },
  });
}

function brokenStream() {
  return new ReadableStream({
    pull() {
      throw Object.assign(new Error("private prompt and token"), { code: "ECONNRESET" });
    },
  });
}

function assertSafeTransport(error, route, phase, status) {
  assert.equal(error.code, "IMAGE_TRANSPORT_FAILURE");
  assert.equal(error.route, route);
  assert.equal(error.phase, phase);
  assert.match(error.message, new RegExp(`route=${route} phase=${phase} elapsed_ms=\\d+`));
  assert.equal(error.message.includes("status="), status !== null);
  if (status !== null) assert.match(error.message, new RegExp(`status=${status}`));
  assert.match(error.message, /code=ECONNRESET; provider outcome unconfirmed/);
  assert.equal(error.message.includes("private prompt and token"), false);
  assert.equal(error.cause, undefined);
  return true;
}

describe("GPT image provider requests", () => {
  test("classifies OAuth and API pre-header disconnects without retrying", async () => {
    for (const [route, request] of [["oauth", requestOAuthImage], ["api", requestApiImage]]) {
      let calls = 0;
      await assert.rejects(request(
        { accessToken: "private token" },
        { prompt: "private prompt", quality: "auto", size: "auto" },
        [],
        async () => {
          calls += 1;
          throw Object.assign(new Error("private prompt and token"), { code: "ECONNRESET" });
        },
      ), (error) => assertSafeTransport(error, route, "request", null));
      assert.equal(calls, 1);
    }
  });

  test("classifies API response-body disconnect after headers", async () => {
    let calls = 0;
    await assert.rejects(requestApiImage(
      { accessToken: "private token" }, { prompt: "private prompt" }, [],
      async () => {
        calls += 1;
        return new Response(brokenStream(), { status: 200 });
      },
    ), (error) => assertSafeTransport(error, "api", "response-body", 200));
    assert.equal(calls, 1);
  });

  test("classifies OAuth SSE read disconnect without model fallback", async () => {
    let calls = 0;
    await assert.rejects(requestOAuthImage(
      { accessToken: "private token" }, { prompt: "private prompt" }, [],
      async () => {
        calls += 1;
        return new Response(brokenStream(), { status: 200 });
      },
    ), (error) => assertSafeTransport(error, "oauth", "response-body", 200));
    assert.equal(calls, 1);
  });

  test("parses a completed image from split SSE frames", async () => {
    const event = `data: ${JSON.stringify({
      type: "response.output_item.done",
      item: { type: "image_generation_call", result: IMAGE_RESULT },
    })}\n\n`;
    assert.equal(await parseImageSse(splitStream(event, 17)), IMAGE_RESULT);
  });

  test("surfaces bounded redacted provider details from terminal SSE failures", async () => {
    const exposedBearer = "Bearer provider-secret";
    const exposedKey = "sk-provider-secret";
    const event = `data: ${JSON.stringify({
      type: "response.failed",
      response: {
        error: {
          code: "content_policy_violation",
          message: `Request denied for ${exposedBearer} and ${exposedKey} ${"x".repeat(500)}`,
        },
      },
    })}\n\n`;
    await assert.rejects(
      parseImageSse(splitStream(event, 23)),
      (error) => {
        assert.equal(error.code, "content_policy_violation");
        assert.equal(error.eventType, "response.failed");
        assert.match(error.message, /content_policy_violation/);
        assert.match(error.message, /\[REDACTED\]/);
        assert.equal(error.message.includes("provider-secret"), false);
        assert.ok(error.message.length < 400);
        return true;
      },
    );
  });

  test("surfaces response.incomplete reasons", async () => {
    const event = `data: ${JSON.stringify({
      type: "response.incomplete",
      response: { incomplete_details: { reason: "content_filter" } },
    })}\n\n`;
    await assert.rejects(parseImageSse(splitStream(event, 8)), /content_filter/);
  });

  test("diagnoses a completed response that contains no generated image", async () => {
    const event = `data: ${JSON.stringify({
      type: "response.completed",
      response: { output: [] },
    })}\n\n`;
    await assert.rejects(parseImageSse(splitStream(event, 11)), /image_missing/);
  });

  test("does not retry a terminal SSE provider failure with another model", async () => {
    let calls = 0;
    const event = `data: ${JSON.stringify({
      type: "error",
      code: "server_error",
      message: "generation failed",
    })}\n\n`;
    await assert.rejects(
      requestOAuthImage(
        { accessToken: "[redacted-credential]" },
        { prompt: "draw a test", quality: "auto", size: "auto", format: "png" },
        [],
        async () => {
          calls += 1;
          return new Response(event, { status: 200 });
        },
      ),
      /server_error: generation failed/,
    );
    assert.equal(calls, 1);
  });

  test("builds the OAuth hosted-tool request with references", async () => {
    let captured;
    const event = `data: ${JSON.stringify({
      type: "response.output_item.done",
      item: { type: "image_generation_call", result: IMAGE_RESULT },
    })}\n\n`;
    const fetchImpl = async (url, init) => {
      captured = { url, init };
      return new Response(splitStream(event, 9), { status: 200, headers: { "Content-Type": "text/event-stream" } });
    };
    const result = await requestOAuthImage(
      { accessToken: "oauth-test-token", accountId: "account-test" },
      { prompt: "draw a test", quality: "low", size: "1024x1024", format: "webp" },
      [{ dataUrl: "data:image/png;base64,dGVzdA==" }],
      fetchImpl,
    );
    const body = JSON.parse(captured.init.body);
    assert.equal(captured.url, "https://chatgpt.com/backend-api/codex/responses");
    assert.equal(captured.init.headers.Authorization, "Bearer oauth-test-token");
    assert.equal(body.model, "gpt-6-sol");
    assert.equal(body.tools[0].type, "image_generation");
    assert.equal(body.tools[0].output_format, "webp");
    assert.equal(body.tools[0].size, "1024x1024");
    assert.equal(Object.hasOwn(body.tools[0], "model"), false);
    assert.equal(body.input[0].content[1].type, "input_image");
    assert.equal(result.base64, IMAGE_RESULT);
    assert.equal(result.routerModel, "gpt-6-sol");
    assert.equal(result.requestedModel, null);
    assert.equal(result.providerModel, null);
  });

  test("leaves OAuth hosted-tool size automatic when auto is requested", async () => {
    let captured;
    const event = `data: ${JSON.stringify({
      type: "response.output_item.done",
      item: { type: "image_generation_call", result: IMAGE_RESULT },
    })}\n\n`;
    await requestOAuthImage(
      { accessToken: "oauth-test-token" },
      { prompt: "draw a test", quality: "auto", size: "auto", format: "png" },
      [],
      async (_url, init) => {
        captured = JSON.parse(init.body);
        return new Response(event, { status: 200 });
      },
    );
    assert.equal(Object.hasOwn(captured.tools[0], "size"), false);
  });

  test("does not retry a rejected OAuth router with unsupported workload aliases", async () => {
    const models = [];
    const result = await requestOAuthImage(
      { accessToken: "[redacted-credential]" },
      { prompt: "draw a test", quality: "auto", size: "auto", format: "png" },
      [],
      async (_url, init) => {
        models.push(JSON.parse(init.body).model);
        return Response.json({ error: { code: "model_not_found", message: "unavailable" } }, { status: 400 });
      },
    );
    assert.deepEqual(models, ["gpt-6-sol"]);
    assert.equal(result.error.code, "model_not_found");
    assert.equal(result.base64, "");
  });

  test("reports bounded compatibility failure when live models strip image_generation", async () => {
    const models = [];
    const result = await requestOAuthImage(
      { accessToken: "oauth-test-token" },
      { prompt: "draw a test", quality: "auto", size: "auto", format: "png" },
      [],
      async (_url, init) => {
        if (init.method === "GET") return Response.json({ models: [{ slug: "gpt-reserve" }, { slug: "gpt-6-luna" }] });
        models.push(JSON.parse(init.body).model);
        if (models.length === 1) return Response.json({ error: { code: "model_not_found", message: "no" } }, { status: 400 });
        return Response.json({ error: { message: "Tool choice 'image_generation' not found in 'tools' parameter" } }, { status: 400 });
      },
    );
    assert.deepEqual(models, ["gpt-6-sol", "gpt-reserve", "gpt-6-luna"]);
    assert.equal(result.error.code, "no_compatible_image_model");
    assert.match(result.error.message, /among the attempted candidates/);
    assert.match(result.error.message, /does not establish account-wide image entitlement/);
  });

  test("classifies streamed router failures and skips error-bearing HTTP 200 candidates", async () => {
    const models = [];
    const result = await requestOAuthImage(
      { accessToken: "test" }, { prompt: "draw a test" }, [],
      async (_url, init) => {
        if (init.method === "GET") return Response.json({ models: ["missing-model", "stripped-model", "working-model"] });
        const model = JSON.parse(init.body).model;
        models.push(model);
        const event = model === "working-model"
          ? { type: "response.output_item.done", item: { type: "image_generation_call", result: IMAGE_RESULT } }
          : { type: "response.failed", response: { error: model === "stripped-model"
            ? { message: "Tool choice 'image_generation' not found in 'tools' parameter" }
            : { code: "model_not_found", message: "unavailable" } } };
        return new Response(`data: ${JSON.stringify(event)}\n\n`, { status: 200 });
      },
    );
    assert.deepEqual(models, ["gpt-6-sol", "missing-model", "stripped-model", "working-model"]);
    assert.equal(result.base64, IMAGE_RESULT);
    assert.equal(result.routerModel, "working-model");
    assert.equal(result.error, undefined);
  });

  test("does not claim account-wide entitlement after initial or capped stripped-tool probes", async () => {
    for (const initialStripped of [true, false]) {
      const models = [];
      const result = await requestOAuthImage(
        { accessToken: "test" }, { prompt: "draw a test" }, [],
        async (_url, init) => {
          if (init.method === "GET") return Response.json({ models: ["candidate-1", "candidate-2", "candidate-3", "untried-model"] });
          models.push(JSON.parse(init.body).model);
          const error = !initialStripped && models.length === 1
            ? { code: "model_not_found", message: "unavailable" }
            : { message: "Tool choice 'image_generation' not found in 'tools' parameter" };
          return new Response(`data: ${JSON.stringify({ type: "response.failed", response: { error } })}\n\n`, { status: 200 });
        },
      );
      assert.equal(models.length, initialStripped ? 1 : 4);
      assert.equal(models.includes("untried-model"), false);
      assert.equal(result.base64, "");
      assert.equal(result.error.code, "no_compatible_image_model");
      assert.match(result.error.message, /among the attempted candidates/);
      assert.match(result.error.message, /does not establish account-wide image entitlement/);
    }
  });

  test("retries a rejected router with an image-capable live model", async () => {
    const event = `data: ${JSON.stringify({ type: "response.output_item.done", item: { type: "image_generation_call", result: IMAGE_RESULT } })}\n\n`;
    const result = await requestOAuthImage(
      { accessToken: "oauth-test-token" },
      { prompt: "draw a test", quality: "auto", size: "auto", format: "png" },
      [],
      async (_url, init) => {
        if (init.method === "GET") return Response.json({ models: [{ slug: "gpt-reserve" }] });
        if (JSON.parse(init.body).model === "gpt-6-sol") {
          return Response.json({ error: { code: "model_not_found", message: "no" } }, { status: 400 });
        }
        return new Response(event, { status: 200 });
      },
    );
    assert.equal(result.routerModel, "gpt-reserve");
    assert.equal(result.base64, IMAGE_RESULT);
  });

  test("sends OpenRouter image requests and reads data[0].b64_json", async () => {
    let captured;
    const result = await requestOpenRouterImage(
      { accessToken: "or-test-token" },
      { prompt: "draw a test", quality: "high", size: "1536x1024", format: "png" },
      async (url, init) => {
        captured = { url, body: JSON.parse(init.body) };
        return Response.json({ data: [{ b64_json: "QUJD" }] });
      },
    );
    assert.equal(captured.url, "https://openrouter.ai/api/v1/images");
    assert.equal(captured.body.model, "openai/gpt-image-2.6-sunburst");
    assert.equal(result.base64, "QUJD");
  });

  test("does not retry non-model OAuth errors", async () => {
    let calls = 0;
    const result = await requestOAuthImage(
      { accessToken: "[redacted-credential]" },
      { prompt: "draw a test", quality: "auto", size: "auto", format: "png" },
      [],
      async () => {
        calls += 1;
        return Response.json({ error: { code: "permission_denied", message: "denied" } }, { status: 403 });
      },
    );
    assert.equal(calls, 1);
    assert.equal(result.error.code, "permission_denied");
  });

  test("uses the explicit GPT Image 2 generations endpoint for API auth", async () => {
    let captured;
    const fetchImpl = async (url, init) => {
      captured = { url, init };
      return Response.json({ data: [{ b64_json: IMAGE_RESULT }] });
    };
    const result = await requestApiImage(
      { accessToken: "unit-test-credential-value" },
      { prompt: "draw a test", quality: "auto", size: "auto" },
      [],
      fetchImpl,
    );
    assert.equal(captured.url, "https://api.openai.com/v1/images/generations");
    const body = JSON.parse(captured.init.body);
    assert.equal(body.model, "gpt-image-2");
    assert.equal(body.output_format, "png");
    assert.equal(result.base64, IMAGE_RESULT);
    assert.equal(result.requestedModel, "gpt-image-2");
    assert.equal(result.providerModel, null);
  });

  test("requests a selected API image model and preserves provider-confirmed provenance", async () => {
    let captured;
    const fetchImpl = async (url, init) => {
      captured = { url, init };
      return Response.json({
        model: "gpt-image-2.5-sunburst-2026-09-01",
        data: [{ b64_json: IMAGE_RESULT }],
      });
    };
    const result = await requestApiImage(
      { accessToken: "[redacted-credential]" },
      { prompt: "draw a test", quality: "auto", size: "auto", model: "gpt-image-2.5-sunburst" },
      [],
      fetchImpl,
    );
    assert.equal(JSON.parse(captured.init.body).model, "gpt-image-2.5-sunburst");
    assert.equal(result.requestedModel, "gpt-image-2.5-sunburst");
    assert.equal(result.providerModel, "gpt-image-2.5-sunburst-2026-09-01");
  });

  test("selects JPEG output for API generation", async () => {
    let captured;
    const fetchImpl = async (url, init) => {
      captured = { url, init };
      return Response.json({ data: [{ b64_json: IMAGE_RESULT }] });
    };
    await requestApiImage(
      { accessToken: "unit-test-credential-value" },
      { prompt: "draw a test", quality: "auto", size: "1536x864", format: "jpeg" },
      [],
      fetchImpl,
    );
    const body = JSON.parse(captured.init.body);
    assert.equal(body.output_format, "jpeg");
    assert.equal(body.size, "1536x864");
  });

  test("uses multipart GPT Image 2 edits when API references are present", async () => {
    let captured;
    const fetchImpl = async (url, init) => {
      captured = { url, init };
      return Response.json({ data: [{ b64_json: IMAGE_RESULT }] });
    };
    await requestApiImage(
      { accessToken: "unit-test-credential-value" },
      {
        prompt: "edit a test",
        quality: "high",
        size: "1024x1024",
        format: "webp",
        model: "gpt-image-2.5-flare",
      },
      [{ buffer: Buffer.from("image"), mime: "image/png", name: "source.png" }],
      fetchImpl,
    );
    assert.equal(captured.url, "https://api.openai.com/v1/images/edits");
    assert.ok(captured.init.body instanceof FormData);
    assert.equal(captured.init.body.get("model"), "gpt-image-2.5-flare");
    assert.equal(captured.init.body.get("output_format"), "webp");
    assert.equal(captured.init.body.getAll("image[]").length, 1);
    assert.equal(new Headers(captured.init.headers).has("Content-Type"), false);
    assert.equal(captured.init.body.has("complexity"), false);
    assert.equal(captured.init.body.has("background"), false);
  });

  test("sends 2.6 complexity and background in JSON and multipart API requests", async () => {
    const captured = [];
    const fetchImpl = async (url, init) => {
      captured.push({ url, init });
      return Response.json({ data: [{ b64_json: IMAGE_RESULT }] });
    };
    const auth = { accessToken: "unit-test-token" };
    const args = {
      prompt: "cutout",
      quality: "high",
      size: "auto",
      model: "gpt-image-2.6-sunburst",
      complexity: "high",
      background: "transparent",
    };
    await requestApiImage(auth, args, [], fetchImpl);
    const json = JSON.parse(captured[0].init.body);
    assert.equal(json.model, "gpt-image-2.6-sunburst");
    assert.equal(json.complexity, "high");
    assert.equal(json.background, "transparent");
    await requestApiImage(
      auth,
      args,
      [{ buffer: Buffer.from("image"), mime: "image/png", name: "source.png" }],
      fetchImpl,
    );
    const form = captured[1].init.body;
    assert.equal(form.get("model"), "gpt-image-2.6-sunburst");
    assert.equal(form.get("complexity"), "high");
    assert.equal(form.get("background"), "transparent");
  });
});
