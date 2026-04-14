// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Non-streaming JSON path for the Claude CLI proxy.
 *
 * Extracted from claude-proxy.mjs as part of t2070. The proxy supports two
 * request modes: streaming SSE (lives in claude-proxy.mjs alongside the SSE
 * session orchestration) and one-shot JSON. When OpenAI clients pass
 * `stream: false`, this module spawns `claude --output-format json`,
 * collects stdout/stderr to completion, and returns the assembled response.
 *
 * Account rotation is handled here so the JSON path remains independent of
 * the streaming path's per-account session model.
 */

import { spawn } from "child_process";
import {
  buildChildEnvWithToken,
  detectRateLimitJson,
  getAvailableAccounts,
  getNativeCliFallback,
  markAccountRateLimited,
} from "./claude-proxy-retry.mjs";
import { buildClaudeArgs } from "./claude-proxy-context.mjs";

/** Maximum time (ms) a CLI subprocess may run before being killed. */
const CHILD_TIMEOUT_MS = parseInt(process.env.CLAUDE_PROXY_TIMEOUT || "600000", 10); // 10 min

/**
 * Wire the caller's AbortSignal to a child process so a client disconnect
 * (GH#18621 Finding 1) terminates the in-flight `claude` invocation.
 * @returns {() => void} cleanup function (idempotent)
 */
function attachAbortSignalToChild(abortSignal, child, label) {
  if (!abortSignal) return () => {};

  const onAbort = () => {
    if (child.exitCode === null && !child.killed) {
      try {
        child.kill("SIGTERM");
        console.error(`[aidevops] Claude proxy: ${label} aborted by client, killed child pid=${child.pid}`);
      } catch {
        // best effort
      }
    }
  };

  if (abortSignal.aborted) {
    onAbort();
  } else {
    abortSignal.addEventListener("abort", onAbort, { once: true });
  }

  return () => abortSignal.removeEventListener("abort", onAbort);
}

async function runClaudeJsonWithAccount(body, directory, account, abortSignal) {
  const childEnv = buildChildEnvWithToken(account.token);
  const child = spawn("claude", buildClaudeArgs(body, body.systemPrompt, false), {
    cwd: directory,
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });

  const timeout = setTimeout(() => {
    console.error(`[aidevops] Claude proxy: json child timeout (${CHILD_TIMEOUT_MS}ms), killing`);
    child.kill("SIGKILL");
  }, CHILD_TIMEOUT_MS);

  const detachAbort = attachAbortSignalToChild(abortSignal, child, "json request");

  const stdoutChunks = [];
  const stderrChunks = [];
  child.stdout.on("data", (chunk) => stdoutChunks.push(chunk));
  child.stderr.on("data", (chunk) => stderrChunks.push(chunk));

  const exitCode = await new Promise((resolve) => {
    child.on("close", resolve);
    child.on("error", () => resolve(1));
  });
  clearTimeout(timeout);
  detachAbort();

  const stdout = Buffer.concat(stdoutChunks).toString("utf-8").trim();
  const stderr = Buffer.concat(stderrChunks).toString("utf-8").trim();

  if (!stdout) {
    throw new Error(stderr || `claude exited with status ${exitCode}`);
  }

  const parsed = JSON.parse(stdout);

  // Check for rate limit in JSON response
  const rateLimitResult = detectRateLimitJson(parsed);
  if (rateLimitResult !== undefined) {
    markAccountRateLimited(account.email, rateLimitResult);
    return { rateLimited: true };
  }

  if (exitCode !== 0) {
    throw new Error(parsed.result || stderr || `claude exited with status ${exitCode}`);
  }

  return {
    rateLimited: false,
    content: parsed.result || "",
    usage: parsed.usage || {},
  };
}

/**
 * Run the JSON path: try each available account in priority order, advancing
 * past any account that comes back rate-limited.
 *
 * @returns {Promise<{ content: string, usage: object }>}
 * @throws if no accounts are available or all are rate-limited
 */
export async function runClaudeJson(body, directory, abortSignal) {
  const accounts = await getAvailableAccounts();
  // Always append native CLI auth as final fallback so requests succeed
  // even when all OAuth pool accounts are rate-limited.
  const accountsWithFallback = [...accounts, getNativeCliFallback()];

  for (const account of accountsWithFallback) {
    if (abortSignal && abortSignal.aborted) throw new Error("Request aborted by client");
    console.error(`[aidevops] Claude proxy: trying account ${account.email} (json mode)`);
    const result = await runClaudeJsonWithAccount(body, directory, account, abortSignal);
    if (!result.rateLimited) {
      return result;
    }
    console.error(`[aidevops] Claude proxy: account ${account.email} rate-limited, trying next...`);
  }

  throw new Error("All Anthropic OAuth pool accounts and native CLI auth are rate-limited");
}

/**
 * Build the OpenAI-compatible response body for a non-streaming JSON
 * Claude run. Usage is mapped from Claude's `input_tokens`/`output_tokens`
 * to OpenAI's `prompt_tokens`/`completion_tokens` shape.
 */
export function buildOpenAIResponse(body, content, usage) {
  return {
    id: `chatcmpl-${crypto.randomUUID().replace(/-/g, "").slice(0, 28)}`,
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model: body.model,
    choices: [
      {
        index: 0,
        message: { role: "assistant", content },
        finish_reason: "stop",
      },
    ],
    usage: {
      prompt_tokens: usage.input_tokens || 0,
      completion_tokens: usage.output_tokens || 0,
      total_tokens: (usage.input_tokens || 0) + (usage.output_tokens || 0),
    },
  };
}
