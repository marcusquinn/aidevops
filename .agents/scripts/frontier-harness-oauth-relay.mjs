// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { randomBytes, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";

const ENDPOINT = "https://chatgpt.com/backend-api/codex/responses";
const BODY_LIMIT = 16 * 1024 * 1024;
const RESPONSE_LIMIT = 2 * 1024 * 1024;

const boundedInteger = (value, min, max) => Number.isInteger(value) && value >= min && value <= max;

function requestStatus(req, expected, state, maxRequests) {
  const supplied = Buffer.from(req.headers.authorization || "");
  if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return 401;
  if (req.method !== "POST" || req.url !== "/v1/responses") return 404;
  if (state.disabled || state.requests >= maxRequests) return 429;
  return state.active ? 409 : null;
}

async function readBody(req, model, reject) {
  let bytes = 0;
  const chunks = [];
  for await (const chunk of req) {
    bytes += chunk.length;
    if (bytes > BODY_LIMIT) { reject(413); return null; }
    chunks.push(chunk);
  }
  let body;
  try { body = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { reject(400); return null; }
  if (body?.model !== model || !Array.isArray(body.input)) { reject(400); return null; }
  // Codex subscription transport requires non-stored streaming responses.
  body.store = false;
  body.stream = true;
  body.instructions ??= "You are a coding assistant.";
  delete body.max_output_tokens;
  delete body.temperature;
  delete body.top_p;
  return body;
}

function completedUsage(line) {
  if (!line.startsWith("data: ")) return null;
  let event;
  try { event = JSON.parse(line.slice(6)); } catch { return null; }
  if (event.type !== "response.completed") return null;
  const value = event.response?.usage;
  const numeric = (n) => Number.isFinite(n) && n >= 0 ? n : null;
  return {
    input_tokens: numeric(value?.input_tokens),
    output_tokens: numeric(value?.output_tokens),
    cached_tokens: numeric(value?.input_tokens_details?.cached_tokens),
  };
}

function createUsageMeter(usage) {
  let responseBytes = 0;
  let pending = "";
  let recorded = false;
  return new Transform({ transform(chunk, _encoding, done) {
    responseBytes += chunk.length;
    if (responseBytes > RESPONSE_LIMIT) return done(new Error("Response ceiling reached"));
    pending += chunk.toString("utf8");
    const lines = pending.split("\n");
    pending = lines.pop();
    for (const line of lines) {
      if (recorded) continue;
      const value = completedUsage(line);
      if (!value) continue;
      recorded = true;
      usage.push(value);
    }
    done(null, chunk);
  } });
}

async function forwardResponse(body, res, { account, fetchImpl, controller, state, reject }) {
  const headers = {
    "content-type": "application/json", accept: "text/event-stream",
    authorization: `Bearer ${account.access}`,
  };
  if (account.accountId) headers["chatgpt-account-id"] = account.accountId;
  const upstream = await fetchImpl(ENDPOINT, {
    method: "POST", headers, body: JSON.stringify(body),
    redirect: "error", signal: controller.signal,
  });
  state.lastUpstreamStatus = upstream.status;
  if (!upstream.ok || !upstream.body) {
    // Stop rather than rotate around subscription or authentication limits.
    if ([401, 403, 429].includes(upstream.status)) state.disabled = true;
    await upstream.body?.cancel();
    reject(upstream.ok ? 502 : upstream.status);
    return;
  }
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
  await pipeline(Readable.fromWeb(upstream.body), createUsageMeter(state.usage), res, { signal: controller.signal });
}

function createRequestHandler({ model, account, maxRequests, fetchImpl }, expected, state) {
  return async (req, res) => {
    const reject = (status) => { res.writeHead(status); res.end(); };
    const status = requestStatus(req, expected, state, maxRequests);
    if (status !== null) return reject(status);
    state.active = true;
    state.requests++;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 120000);
    const disconnected = () => { if (!res.writableEnded) controller.abort(); };
    res.on("close", disconnected);
    try {
      const body = await readBody(req, model, reject);
      if (body) await forwardResponse(body, res, { account, fetchImpl, controller, state, reject });
    } catch {
      state.streamFailures++;
      if (!res.headersSent) reject(502);
      else res.destroy();
    } finally {
      clearTimeout(timeout);
      res.removeListener("close", disconnected);
      state.active = false;
    }
  };
}

/** Local, bounded inference capability. OAuth credentials never enter Docker.
 * No API-key path, provider fallback, refresh, rotation, or retry exists here.
 * Caller owns close() in a finally block and must not publish the capability key.
 */
export async function createRelay({ model, account, maxRequests = 64, lifetimeMs = 1800000, fetchImpl = fetch }) {
  if (!/^[a-zA-Z0-9._-]+$/.test(model || "") || !account?.access) {
    throw new Error("A pinned model and OAuth account are required");
  }
  if (!boundedInteger(maxRequests, 1, 256) || !boundedInteger(lifetimeMs, 1000, 3600000)) {
    throw new Error("Invalid relay limits");
  }
  const key = randomBytes(32).toString("hex");
  const expected = Buffer.from(`Bearer ${key}`);
  const state = { requests: 0, active: false, disabled: false, lastUpstreamStatus: null,
    streamFailures: 0, usage: [] };
  const server = createServer(createRequestHandler({ model, account, maxRequests, fetchImpl }, expected, state));
  server.requestTimeout = 120000;
  server.headersTimeout = 10000;
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const close = () => {
    state.disabled = true;
    server.closeAllConnections();
    server.close();
  };
  const timer = setTimeout(close, lifetimeMs);
  timer.unref();
  return {
    key, port: server.address().port,
    stats: () => ({ requests: state.requests, disabled: state.disabled, active: state.active,
      last_upstream_status: state.lastUpstreamStatus,
      stream_failures: state.streamFailures, response_byte_limit: RESPONSE_LIMIT,
      upstream_usage: state.usage.map((entry) => ({ ...entry })) }),
    close: () => { clearTimeout(timer); close(); },
  };
}
