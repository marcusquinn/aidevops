// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OAuth Pool — Local Callback Server
 *
 * Captures OAuth authorization responses on the loopback callback endpoint.
 *
 * @module oauth-pool-callback-server
 */

import { createServer } from "http";
import { OAUTH_CALLBACK_PORT, OAUTH_CALLBACK_TIMEOUT_MS } from "./oauth-pool-constants.mjs";
import { acquireCallbackLock } from "./oauth-pool-callback-lock.mjs";

function escapeHtml(value) {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#039;");
}

function endResponse(res, status, contentType, body) {
  res.writeHead(status, { "Content-Type": contentType });
  res.end(body);
}

function parseCallbackUrl(req, res) {
  try { return new URL(req.url, `http://localhost:${OAUTH_CALLBACK_PORT}`); }
  catch {
    endResponse(res, 400, "text/plain", "Bad request");
    return null;
  }
}

function rejectMismatchedState(reqUrl, expectedState, res, cleanup, rejectCode) {
  if (!expectedState || reqUrl.searchParams.get("state") === expectedState) return false;
  console.error("[aidevops] OAuth pool: state mismatch in callback — possible CSRF");
  endResponse(res, 400, "text/plain", "State mismatch — authorization rejected");
  cleanup();
  rejectCode(new Error("OAuth state mismatch"));
  return true;
}

function settleCallback(reqUrl, res, cleanup, resolveCode, rejectCode) {
  const code = reqUrl.searchParams.get("code");
  const error = reqUrl.searchParams.get("error");
  if (error) {
    const description = escapeHtml(reqUrl.searchParams.get("error_description") || "");
    endResponse(res, 200, "text/html", `<!DOCTYPE html><html><body><h2>Authorization Failed</h2><p>${escapeHtml(error)}</p><p>${description}</p><p>You can close this tab.</p></body></html>`);
    cleanup();
    rejectCode(new Error(`OAuth error: ${error}`));
  } else if (code) {
    endResponse(res, 200, "text/html", "<!DOCTYPE html><html><body><h2>Authorization Successful</h2><p>The authorization code has been captured. Return to OpenCode.</p><p>You can close this tab.</p></body></html>");
    cleanup();
    resolveCode(code);
  } else {
    endResponse(res, 200, "text/plain", "Waiting for OAuth callback...");
  }
}

function callbackRequestHandler(expectedState, cleanup, resolveCode, rejectCode) {
  return (req, res) => {
    const reqUrl = parseCallbackUrl(req, res);
    if (!reqUrl) return;
    if (reqUrl.pathname !== "/auth/callback") {
      endResponse(res, 404, "text/plain", "Not found");
      return;
    }
    if (rejectMismatchedState(reqUrl, expectedState, res, cleanup, rejectCode)) return;
    settleCallback(reqUrl, res, cleanup, resolveCode, rejectCode);
  };
}

function callbackServerErrorHandler(cleanup, resolveReady, rejectCode) {
  return (error) => {
    cleanup();
    if (error.code === "EADDRINUSE") {
      console.error(`[aidevops] OAuth pool: port ${OAUTH_CALLBACK_PORT} in use`);
      resolveReady(false);
      return;
    }
    console.error(`[aidevops] OAuth pool: callback server error: ${error.message}`);
    resolveReady(false);
    rejectCode(error);
  };
}

function listenAfterCallbackLock(server, closed, setReleaseLock, resolveReady, cleanup) {
  void acquireCallbackLock(closed).then((release) => {
    if (!release || closed()) {
      if (release) release();
      resolveReady(false);
      return;
    }
    setReleaseLock(release);
    server.listen(OAUTH_CALLBACK_PORT, "127.0.0.1", () => {
      console.error(`[aidevops] OAuth pool: callback server listening on port ${OAUTH_CALLBACK_PORT}`);
      resolveReady(true);
    });
  }).catch((error) => {
    console.error(`[aidevops] OAuth pool: callback lock error: ${error.message}`);
    resolveReady(false);
    cleanup();
  });
}

export function startOAuthCallbackServer(expectedState) {
  let resolveCode, rejectCode, server, timeoutId, resolveReady, releaseLock;
  let closed = false;
  const promise = new Promise((resolve, reject) => { resolveCode = resolve; rejectCode = reject; });
  const ready = new Promise((resolve) => { resolveReady = resolve; });

  function cleanup() {
    closed = true;
    if (timeoutId) clearTimeout(timeoutId);
    if (server) { try { server.close(); } catch { /* ignore */ } }
    if (releaseLock) { releaseLock(); releaseLock = null; }
  }

  server = createServer(callbackRequestHandler(expectedState, cleanup, resolveCode, rejectCode));
  server.on("error", callbackServerErrorHandler(cleanup, resolveReady, rejectCode));
  listenAfterCallbackLock(server, () => closed, (release) => { releaseLock = release; }, resolveReady, cleanup);

  timeoutId = setTimeout(() => {
    resolveReady(false);
    cleanup();
    rejectCode(new Error("OAuth callback timeout"));
  }, OAUTH_CALLBACK_TIMEOUT_MS);
  return { promise, ready, close: cleanup };
}
