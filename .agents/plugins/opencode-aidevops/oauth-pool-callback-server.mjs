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
import {
  mkdirSync, readFileSync, rmdirSync, statSync, unlinkSync, writeFileSync,
} from "fs";
import { randomUUID } from "crypto";
import { homedir } from "os";
import { dirname, join } from "path";
import { OAUTH_CALLBACK_PORT, OAUTH_CALLBACK_TIMEOUT_MS } from "./oauth-pool-constants.mjs";

const LOCK_POLL_MS = 250;
const LOCK_LEASE_GRACE_MS = 30_000;

function callbackLockDir() {
  return process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_DIR
    || join(homedir(), ".aidevops", ".agent-workspace", "locks", `opencode-oauth-${OAUTH_CALLBACK_PORT}.lock`);
}

function callbackLockLeaseMs() {
  const configured = Number.parseInt(process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_LEASE_MS || "", 10);
  return Number.isFinite(configured) && configured > 0
    ? configured
    : OAUTH_CALLBACK_TIMEOUT_MS + LOCK_LEASE_GRACE_MS;
}

function removeStaleCallbackLock(lockDir) {
  const ownerPath = join(lockDir, "pid");
  let ageMs = 0;
  try { ageMs = Date.now() - statSync(lockDir).mtimeMs; }
  catch { return true; }
  if (ageMs < callbackLockLeaseMs()) return false;

  let observedOwner = "";
  try { observedOwner = readFileSync(ownerPath, "utf8"); }
  catch { /* incomplete or abandoned lock */ }
  let currentOwner = "";
  try { currentOwner = readFileSync(ownerPath, "utf8"); }
  catch { /* incomplete or abandoned lock */ }
  if (currentOwner !== observedOwner) return false;

  try { unlinkSync(ownerPath); } catch { /* absent owner file */ }
  try { rmdirSync(lockDir); return true; }
  catch { return false; }
}

async function acquireCallbackLock(cancelled) {
  const lockDir = callbackLockDir();
  const ownerPath = join(lockDir, "pid");
  mkdirSync(dirname(lockDir), { recursive: true, mode: 0o700 });
  let announcedWait = false;

  while (!cancelled()) {
    try {
      mkdirSync(lockDir, { mode: 0o700 });
      const owner = JSON.stringify({ pid: process.pid, token: randomUUID() });
      try { writeFileSync(ownerPath, `${owner}\n`, { mode: 0o600, flag: "wx" }); }
      catch (error) { try { rmdirSync(lockDir); } catch { /* ignore */ } throw error; }
      let released = false;
      return () => {
        if (released) return;
        released = true;
        let currentOwner = "";
        try { currentOwner = readFileSync(ownerPath, "utf8").trim(); }
        catch { /* lock already cleaned */ }
        if (currentOwner !== owner) return;
        try { unlinkSync(ownerPath); } catch { /* ignore */ }
        try { rmdirSync(lockDir); } catch { /* ignore */ }
      };
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      if (removeStaleCallbackLock(lockDir)) continue;
      if (!announcedWait) {
        console.error("[aidevops] OAuth pool: waiting for another interactive login to finish");
        announcedWait = true;
      }
      await new Promise((resolve) => setTimeout(resolve, LOCK_POLL_MS));
    }
  }
  return null;
}

export function startOAuthCallbackServer(expectedState) {
  let resolveCode, rejectCode, server, timeoutId, resolveReady, releaseLock;
  let closed = false;
  const promise = new Promise((resolve, reject) => { resolveCode = resolve; rejectCode = reject; });
  const ready = new Promise((resolve) => { resolveReady = resolve; });
  const escapeHtml = (s) =>
    s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#039;");

  function cleanup() {
    closed = true;
    if (timeoutId) clearTimeout(timeoutId);
    if (server) { try { server.close(); } catch { /* ignore */ } }
    if (releaseLock) { releaseLock(); releaseLock = null; }
  }

  server = createServer((req, res) => {
    let reqUrl;
    try { reqUrl = new URL(req.url, `http://localhost:${OAUTH_CALLBACK_PORT}`); }
    catch { res.writeHead(400, { "Content-Type": "text/plain" }); res.end("Bad request"); return; }

    if (reqUrl.pathname !== "/auth/callback") {
      res.writeHead(404, { "Content-Type": "text/plain" }); res.end("Not found"); return;
    }

    const code = reqUrl.searchParams.get("code");
    const error = reqUrl.searchParams.get("error");

    // Validate OAuth state to prevent CSRF / account-mixup attacks.
    if (expectedState) {
      const returnedState = reqUrl.searchParams.get("state");
      if (returnedState !== expectedState) {
        console.error("[aidevops] OAuth pool: state mismatch in callback — possible CSRF");
        res.writeHead(400, { "Content-Type": "text/plain" });
        res.end("State mismatch — authorization rejected");
        cleanup();
        rejectCode(new Error("OAuth state mismatch"));
        return;
      }
    }

    if (error) {
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(`<!DOCTYPE html><html><body><h2>Authorization Failed</h2><p>${escapeHtml(error)}</p><p>${escapeHtml(reqUrl.searchParams.get("error_description") || "")}</p><p>You can close this tab.</p></body></html>`);
      cleanup();
      rejectCode(new Error(`OAuth error: ${error}`));
    } else if (code) {
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(`<!DOCTYPE html><html><body><h2>Authorization Successful</h2><p>The authorization code has been captured. Return to OpenCode.</p><p>You can close this tab.</p></body></html>`);
      cleanup();
      resolveCode(code);
    } else {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("Waiting for OAuth callback...");
    }
  });

  server.on("error", (err) => {
    cleanup();
    if (err.code === "EADDRINUSE") {
      console.error(`[aidevops] OAuth pool: port ${OAUTH_CALLBACK_PORT} in use`);
      resolveReady(false);
      return;
    }
    console.error(`[aidevops] OAuth pool: callback server error: ${err.message}`);
    resolveReady(false);
    rejectCode(err);
  });

  void acquireCallbackLock(() => closed).then((release) => {
    if (!release || closed) { if (release) release(); resolveReady(false); return; }
    releaseLock = release;
    server.listen(OAUTH_CALLBACK_PORT, "127.0.0.1", () => {
      console.error(`[aidevops] OAuth pool: callback server listening on port ${OAUTH_CALLBACK_PORT}`);
      resolveReady(true);
    });
  }).catch((error) => {
    console.error(`[aidevops] OAuth pool: callback lock error: ${error.message}`);
    resolveReady(false);
    cleanup();
  });

  timeoutId = setTimeout(() => {
    resolveReady(false);
    cleanup();
    rejectCode(new Error("OAuth callback timeout"));
  }, OAUTH_CALLBACK_TIMEOUT_MS);
  return { promise, ready, close: cleanup };
}
