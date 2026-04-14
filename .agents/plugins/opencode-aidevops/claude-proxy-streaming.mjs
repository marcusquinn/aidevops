// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * SSE streaming orchestration for the Claude CLI proxy.
 *
 * This module owns the full streaming path:
 *   - per-account session lifecycle (probe → commit → drain)
 *   - child spawn + timeout + abort signal wiring
 *   - account fail-over on rate limit
 *   - the public `streamClaudeResponse(body, directory)` ReadableStream factory
 *
 * Pure event-handler logic (text / tool_use / task / message_delta dispatch)
 * lives in claude-proxy-stream.mjs and is consumed via `processStreamEvent`.
 *
 * Extracted from claude-proxy.mjs as part of t2070 to drop file complexity.
 */

import { spawn } from "child_process";
import {
  buildChildEnvWithToken,
  detectRateLimitStream,
  getAvailableAccounts,
  getNativeCliFallback,
  markAccountRateLimited,
} from "./claude-proxy-retry.mjs";
import {
  createOpenAIChunk,
  isCommitTrigger,
  processStreamEvent,
} from "./claude-proxy-stream.mjs";
import { buildClaudeArgs } from "./claude-proxy-context.mjs";

/** Maximum time (ms) a CLI subprocess may run before being killed. */
const CHILD_TIMEOUT_MS = parseInt(process.env.CLAUDE_PROXY_TIMEOUT || "600000", 10); // 10 min

// ---------------------------------------------------------------------------
// Per-account session state
// ---------------------------------------------------------------------------

/**
 * Per-account streaming session. Bundles all mutable state for one
 * `tryStreamWithAccount` invocation so the spawn/handler wiring stays small.
 */
function createStreamSession(streamCtx, account, resolve) {
  const session = {
    // wiring
    controller: streamCtx.controller,
    encoder: streamCtx.encoder,
    completionId: streamCtx.completionId,
    created: streamCtx.created,
    body: streamCtx.body,
    model: streamCtx.body.model,
    account,
    resolve,
    // child + lifecycle
    child: null,
    timeout: null,
    closed: false,
    finishSent: false,
    // probe phase: buffer events until we know the account isn't rate-limited
    probePhase: true,
    rateLimitBailed: false,
    bufferedEvents: [],
    // line-parsing buffer
    buffer: "",
    stderrText: "",
    // counters / dedup (consumed by claude-proxy-stream.mjs handlers)
    textChunkCount: 0,
    textCharCount: 0,
    seenToolUseIds: new Map(),
    seenTaskIds: new Set(),
    seenToolResults: new Set(),
    send(payload) {
      if (this.closed) return;
      try {
        this.controller.enqueue(this.encoder.encode(`data: ${JSON.stringify(payload)}\n\n`));
      } catch {
        this.closed = true;
      }
    },
  };
  return session;
}

function spawnClaudeStreamChild(body, directory, account) {
  const childEnv = buildChildEnvWithToken(account.token);
  return spawn("claude", buildClaudeArgs(body, body.systemPrompt, true), {
    cwd: directory,
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

// ---------------------------------------------------------------------------
// stdout / stderr / close / error handlers
// ---------------------------------------------------------------------------

/**
 * Flush probe-phase buffered events through the real handler and drop
 * probe mode for the rest of the stream.
 */
function commitBufferedEvents(session) {
  session.probePhase = false;
  for (const evt of session.bufferedEvents) {
    processStreamEvent(evt, session);
  }
  session.bufferedEvents.length = 0;
}

/**
 * Probe-phase event handler. Watches for rate-limit signals before any
 * content has been emitted to the controller, so we can silently fail over
 * to the next account without leaking partial output to the client.
 *
 * @returns {boolean} true if the session should stop processing further
 *   events (the probe bailed out and resolved "rate_limited").
 */
function handleProbeEvent(session, event) {
  const rl = detectRateLimitStream(event);
  if (rl.rateLimited) {
    markAccountRateLimited(session.account.email, rl.resetsAt);
    session.rateLimitBailed = true;
    session.child.kill("SIGTERM");
    session.resolve("rate_limited");
    return true;
  }
  session.bufferedEvents.push(event);
  if (isCommitTrigger(event)) {
    commitBufferedEvents(session);
  }
  return false;
}

function parseEventLine(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function onStreamStdout(session, chunk) {
  session.buffer += chunk.toString("utf-8");
  const lines = session.buffer.split("\n");
  session.buffer = lines.pop() || "";

  for (const line of lines) {
    if (!line.trim()) continue;
    const event = parseEventLine(line);
    if (!event) continue;

    if (session.probePhase) {
      const stopped = handleProbeEvent(session, event);
      if (stopped) return;
      continue;
    }

    processStreamEvent(event, session);
  }
}

function onStreamStderr(session, chunk) {
  if (session.stderrText.length < 4000) {
    session.stderrText += chunk.toString("utf-8");
  }
}

function finalizeStream(session) {
  if (session.closed) return;
  session.closed = true;
  try {
    session.controller.enqueue(session.encoder.encode("data: [DONE]\n\n"));
  } catch {
    // already closed
  }
  try {
    session.controller.close();
  } catch {
    // already closed by runtime
  }
}

function emitStderrTransportError(session) {
  if (!session.stderrText.trim()) return;
  session.send(createOpenAIChunk(session.completionId, session.created, session.model, {
    content: `\n[Claude CLI transport error: ${session.stderrText.trim().slice(0, 500)}]`,
  }));
}

function emitStopChunkIfNeeded(session) {
  if (session.finishSent) return;
  session.finishSent = true;
  session.send(createOpenAIChunk(session.completionId, session.created, session.model, {}, "stop"));
}

function logStreamComplete(session, exitCode) {
  console.error(
    `[aidevops] Claude proxy: stream complete model=${session.model} account=${session.account.email} exitCode=${exitCode} textChunks=${session.textChunkCount} textChars=${session.textCharCount} stderr=${JSON.stringify(session.stderrText.trim().slice(0, 300))}`,
  );
}

function onStreamClose(session, exitCode) {
  if (session.timeout) clearTimeout(session.timeout);

  // If we bailed due to rate limiting, the controller belongs to the next
  // account attempt — do NOT write to it or close it.
  if (session.rateLimitBailed) {
    console.error(
      `[aidevops] Claude proxy: killed rate-limited child account=${session.account.email} exitCode=${exitCode}`,
    );
    return;
  }

  // If we never exited probe phase (e.g. very short response), flush now
  if (session.probePhase) commitBufferedEvents(session);

  if (exitCode !== 0) emitStderrTransportError(session);
  emitStopChunkIfNeeded(session);
  logStreamComplete(session, exitCode);
  finalizeStream(session);
  session.resolve("done");
}

function onStreamError(session, err) {
  if (session.timeout) clearTimeout(session.timeout);
  if (session.probePhase) {
    session.resolve("error");
    return;
  }
  session.controller.error(err);
  session.resolve("done");
}

// ---------------------------------------------------------------------------
// Per-attempt + multi-account orchestration
// ---------------------------------------------------------------------------

/**
 * Wire the abort ref into a freshly spawned child so client cancel
 * (GH#18621 Finding 1) terminates the in-flight request.
 */
function attachAbortRef(abortRef, child) {
  if (!abortRef) return;
  abortRef.child = child;
  if (abortRef.cancelled) child.kill("SIGTERM");
}

/**
 * Attempt to stream with a specific account. Buffers initial events to detect
 * rate limiting before committing to the stream. Resolves with `"rate_limited"`
 * if the account is rate-limited (caller advances to next), `"error"` if the
 * child failed to launch during probe, or `"done"` if the stream completed.
 *
 * @returns {Promise<"done"|"rate_limited"|"error">}
 */
function tryStreamWithAccount(streamCtx, account) {
  return new Promise((resolve) => {
    const session = createStreamSession(streamCtx, account, resolve);
    const child = spawnClaudeStreamChild(streamCtx.body, streamCtx.directory, account);
    session.child = child;

    attachAbortRef(streamCtx.abortRef, child);

    session.timeout = setTimeout(() => {
      console.error(`[aidevops] Claude proxy: stream child timeout (${CHILD_TIMEOUT_MS}ms), killing`);
      child.kill("SIGKILL");
    }, CHILD_TIMEOUT_MS);

    child.stdout.on("data", (chunk) => onStreamStdout(session, chunk));
    child.stderr.on("data", (chunk) => onStreamStderr(session, chunk));
    child.on("close", (exitCode) => onStreamClose(session, exitCode));
    child.on("error", (err) => onStreamError(session, err));
  });
}

/**
 * Emit an "all accounts rate-limited" SSE message and close the stream.
 * Used both when no accounts are available at start and when every account
 * was exhausted mid-iteration (including the native CLI fallback).
 */
function emitAllAccountsRateLimited(controller, encoder, completionId, created, model) {
  const errChunk = createOpenAIChunk(completionId, created, model, {
    content: "[Claude CLI transport: all Anthropic OAuth pool accounts are rate-limited and native CLI fallback also failed]",
  });
  try {
    controller.enqueue(encoder.encode(`data: ${JSON.stringify(errChunk)}\n\n`));
    controller.enqueue(encoder.encode(`data: ${JSON.stringify(createOpenAIChunk(completionId, created, model, {}, "stop"))}\n\n`));
    controller.enqueue(encoder.encode("data: [DONE]\n\n"));
    controller.close();
  } catch {
    // already closed
  }
}

/**
 * Iterate through available accounts, starting a new stream attempt for each
 * and stopping at the first non-rate-limited result.
 */
async function iterateAccounts(streamCtx, accounts) {
  for (const account of accounts) {
    if (streamCtx.abortRef.cancelled) return; // client already bailed
    console.error(`[aidevops] Claude proxy: trying account ${account.email} (stream mode)`);
    const result = await tryStreamWithAccount(streamCtx, account);
    if (result === "rate_limited") {
      console.error(`[aidevops] Claude proxy: account ${account.email} rate-limited, trying next...`);
      continue;
    }
    return; // stream completed (done or error already handled)
  }

  // All accounts exhausted
  emitAllAccountsRateLimited(
    streamCtx.controller,
    streamCtx.encoder,
    streamCtx.completionId,
    streamCtx.created,
    streamCtx.body.model,
  );
}

/**
 * Handle a client-initiated cancel from the ReadableStream `cancel` callback.
 * Terminates whichever child is currently running so it stops consuming
 * quota and touching the workspace (GH#18621 Finding 1).
 */
function handleStreamCancel(abortRef, reason) {
  abortRef.cancelled = true;
  const child = abortRef.child;
  if (!child || child.exitCode !== null || child.killed) return;
  try {
    child.kill("SIGTERM");
    console.error(`[aidevops] Claude proxy: stream cancelled by client (${reason || "no-reason"}), killed child pid=${child.pid}`);
  } catch {
    // best effort
  }
}

/**
 * Public entry point: build a ReadableStream that feeds the OpenAI-compatible
 * SSE chat-completion response by spawning `claude --output-format stream-json`
 * against the OAuth pool, with rate-limit-aware account fail-over.
 */
export function streamClaudeResponse(body, directory) {
  const completionId = `chatcmpl-${crypto.randomUUID().replace(/-/g, "").slice(0, 28)}`;
  const created = Math.floor(Date.now() / 1000);
  const encoder = new TextEncoder();

  // Shared ref between start() and cancel() so the cancel callback can kill
  // whatever child is currently running. `child` is mutated by
  // tryStreamWithAccount as each retry spawns.
  const abortRef = { child: null, cancelled: false };

  return new ReadableStream({
    async start(controller) {
      const accounts = await getAvailableAccounts();
      // Always append native CLI auth as final fallback so streams succeed
      // even when all OAuth pool accounts are rate-limited.
      const accountsWithFallback = [...accounts, getNativeCliFallback()];
      const streamCtx = { controller, encoder, completionId, created, body, directory, abortRef };
      await iterateAccounts(streamCtx, accountsWithFallback);
    },
    cancel(reason) {
      handleStreamCancel(abortRef, reason);
    },
  });
}
