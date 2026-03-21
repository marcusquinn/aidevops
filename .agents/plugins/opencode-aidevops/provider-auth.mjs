/**
 * Anthropic Provider Auth (t1543)
 *
 * Handles OAuth authentication for the built-in "anthropic" provider.
 * Re-implements the essential functionality of the removed opencode-anthropic-auth
 * plugin with our fixes applied:
 *   - Token endpoint: platform.claude.com (not console.anthropic.com)
 *   - Updated scopes including user:sessions:claude_code
 *   - User-Agent matching current Claude CLI version
 *   - Deprecated beta header filtering
 *   - Pool token injection on session start
 *
 * The pool (oauth-pool.mjs) manages multiple account tokens.
 * This module makes the built-in provider use them correctly.
 */

import { ensureValidToken, getAccounts, patchAccount, getAnthropicUserAgent } from "./oauth-pool.mjs";

const TOOL_PREFIX = "mcp_";

const REQUIRED_BETAS = [
  "oauth-2025-04-20",
  "interleaved-thinking-2025-05-14",
];

const DEPRECATED_BETAS = new Set([
  "code-execution-2025-01-24",
  "extended-cache-ttl-2025-04-11",
]);

/** Priority order for account status during pool rotation (lower = tried first). */
const STATUS_ORDER = { active: 0, idle: 1, "rate-limited": 2, "auth-error": 3 };

/**
 * Create the auth hook for the built-in "anthropic" provider.
 * Provides OAuth loader with custom fetch that handles:
 *   - Bearer auth with pool tokens
 *   - Beta headers (required + filtered)
 *   - System prompt sanitization (OpenCode → Claude Code)
 *   - Tool name prefixing (mcp_)
 *   - ?beta=true query param
 *   - Response stream tool name de-prefixing
 *
 * @param {any} client - OpenCode SDK client
 * @returns {import('@opencode-ai/plugin').AuthHook}
 */
export function createProviderAuthHook(client) {
  return {
    provider: "anthropic",

    async loader(getAuth, provider) {
      const auth = await getAuth();
      if (auth.type !== "oauth") return {};

      // Zero out costs for Max plan
      for (const model of Object.values(provider.models)) {
        model.cost = {
          input: 0,
          output: 0,
          cache: { read: 0, write: 0 },
        };
      }

      return {
        apiKey: "",
        async fetch(input, init) {
          const auth = await getAuth();
          if (auth.type !== "oauth") return fetch(input, init);

          // Refresh token if expired
          let accessToken = auth.access;
          if (!accessToken || auth.expires < Date.now()) {
            // Try refreshing via the pool's ensureValidToken (handles
            // rotation across multiple accounts and cooldown logic).
            // Sort by least-recently-used so we try the freshest account
            // first, maximising the chance of finding one not rate-limited.
            const accounts = getAccounts("anthropic");
            let refreshed = false;

            // Sort accounts: active first (by LRU), then others
            const sorted = [...accounts].sort((a, b) => {
              // Prefer active/idle accounts over rate-limited/auth-error
              const aOrder = STATUS_ORDER[a.status] ?? 99;
              const bOrder = STATUS_ORDER[b.status] ?? 99;
              if (aOrder !== bOrder) return aOrder - bOrder;
              // Within same status, prefer least recently used
              return new Date(a.lastUsed || 0) - new Date(b.lastUsed || 0);
            });

            for (const account of sorted) {
              // Skip accounts in cooldown
              if (account.cooldownUntil && account.cooldownUntil > Date.now()) {
                console.error(`[aidevops] provider-auth: skipping ${account.email} — cooldown active`);
                continue;
              }
              const token = await ensureValidToken("anthropic", account);
              if (token) {
                await client.auth.set({
                  path: { id: "anthropic" },
                  body: {
                    type: "oauth",
                    refresh: account.refresh,
                    access: account.access,
                    expires: account.expires,
                  },
                });
                patchAccount("anthropic", account.email, {
                  lastUsed: new Date().toISOString(),
                  status: "active",
                });
                accessToken = token;
                refreshed = true;
                console.error(`[aidevops] provider-auth: refreshed via pool account ${account.email}`);
                break;
              }
            }

            if (!refreshed) {
              // All pool accounts exhausted (rate-limited or auth-error).
              // Log which accounts were tried and their status for debugging.
              const accountSummary = accounts.map((a) => {
                const cooldown = a.cooldownUntil && a.cooldownUntil > Date.now()
                  ? ` (cooldown: ${Math.ceil((a.cooldownUntil - Date.now()) / 60000)}m)`
                  : "";
                return `${a.email}[${a.status}${cooldown}]`;
              }).join(", ");
              console.error(
                `[aidevops] provider-auth: all pool accounts exhausted. ` +
                `Accounts: ${accountSummary || "none"}. ` +
                `Use /model-accounts-pool reset-cooldowns to clear cooldowns, ` +
                `or wait for cooldowns to expire.`,
              );
              throw new Error(
                `Token refresh failed: all ${accounts.length} pool account(s) exhausted ` +
                `(rate-limited or auth-error). Use /model-accounts-pool reset-cooldowns to retry.`,
              );
            }
          }

          // Build headers
          const requestInit = init ?? {};
          const requestHeaders = new Headers();

          if (input instanceof Request) {
            input.headers.forEach((value, key) => {
              requestHeaders.set(key, value);
            });
          }

          if (requestInit.headers) {
            if (requestInit.headers instanceof Headers) {
              requestInit.headers.forEach((value, key) => {
                requestHeaders.set(key, value);
              });
            } else if (Array.isArray(requestInit.headers)) {
              for (const [key, value] of requestInit.headers) {
                if (typeof value !== "undefined") {
                  requestHeaders.set(key, String(value));
                }
              }
            } else {
              for (const [key, value] of Object.entries(requestInit.headers)) {
                if (typeof value !== "undefined") {
                  requestHeaders.set(key, String(value));
                }
              }
            }
          }

          // Merge betas, filtering deprecated ones
          const incomingBeta = requestHeaders.get("anthropic-beta") || "";
          const incomingBetasList = incomingBeta
            .split(",")
            .map((b) => b.trim())
            .filter((b) => b && !DEPRECATED_BETAS.has(b));
          const mergedBetas = [
            ...new Set([...REQUIRED_BETAS, ...incomingBetasList]),
          ].join(",");

          requestHeaders.set("authorization", `Bearer ${accessToken}`);
          requestHeaders.set("anthropic-beta", mergedBetas);
          requestHeaders.set("user-agent", getAnthropicUserAgent());
          requestHeaders.delete("x-api-key");

          // Transform request body
          let body = requestInit.body;
          if (body && typeof body === "string") {
            try {
              const parsed = JSON.parse(body);

              // Sanitize system prompt
              if (parsed.system && Array.isArray(parsed.system)) {
                parsed.system = parsed.system.map((item) => {
                  if (item.type === "text" && item.text) {
                    return {
                      ...item,
                      text: item.text
                        .replace(/OpenCode/g, "Claude Code")
                        .replace(/opencode/gi, "Claude"),
                    };
                  }
                  return item;
                });
              }

              // Prefix tool definitions
              if (parsed.tools && Array.isArray(parsed.tools)) {
                parsed.tools = parsed.tools.map((tool) => ({
                  ...tool,
                  name: tool.name ? `${TOOL_PREFIX}${tool.name}` : tool.name,
                }));
              }

              // Prefix tool_use blocks in messages
              if (parsed.messages && Array.isArray(parsed.messages)) {
                parsed.messages = parsed.messages.map((msg) => {
                  if (msg.content && Array.isArray(msg.content)) {
                    msg.content = msg.content.map((block) => {
                      if (block.type === "tool_use" && block.name) {
                        return { ...block, name: `${TOOL_PREFIX}${block.name}` };
                      }
                      return block;
                    });
                  }
                  return msg;
                });
              }

              body = JSON.stringify(parsed);
            } catch {
              // ignore parse errors
            }
          }

          // Add ?beta=true
          let requestInput = input;
          let requestUrl = null;
          try {
            if (typeof input === "string" || input instanceof URL) {
              requestUrl = new URL(input.toString());
            } else if (input instanceof Request) {
              requestUrl = new URL(input.url);
            }
          } catch {
            requestUrl = null;
          }

          if (
            requestUrl &&
            requestUrl.pathname === "/v1/messages" &&
            !requestUrl.searchParams.has("beta")
          ) {
            requestUrl.searchParams.set("beta", "true");
            requestInput =
              input instanceof Request
                ? new Request(requestUrl.toString(), input)
                : requestUrl;
          }

          const response = await fetch(requestInput, {
            ...requestInit,
            body,
            headers: requestHeaders,
          });

          // Transform streaming response — strip mcp_ prefix from tool names
          if (response.body) {
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            const encoder = new TextEncoder();

            const stream = new ReadableStream({
              async pull(controller) {
                const { done, value } = await reader.read();
                if (done) {
                  controller.close();
                  return;
                }
                let text = decoder.decode(value, { stream: true });
                text = text.replace(
                  /"name"\s*:\s*"mcp_([^"]+)"/g,
                  '"name": "$1"',
                );
                controller.enqueue(encoder.encode(text));
              },
            });

            return new Response(stream, {
              status: response.status,
              statusText: response.statusText,
              headers: response.headers,
            });
          }

          return response;
        },
      };
    },
  };
}
