// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// ---------------------------------------------------------------------------
// Redirect-link guard for URL-bearing tools (GH#35655, t18771).
//
// aidevops never resolves, fetches or opens a URL-shortener/redirector link
// in any session. Bash and bounded operations are covered by the shared
// command policy; this guard covers every other tool whose arguments carry a
// URL (WebFetch, browser/MCP navigation, research tools).
//
// Detection reuses scripts/redirect_link_policy.py (single host list in
// configs/redirect-hosts.conf). It is lexical only and never touches the
// network. File tools are exempt: writing policy docs or host lists that name
// shortener hosts is legitimate and opens nothing.
// ---------------------------------------------------------------------------

import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";

const EXEMPT_TOOLS = new Set([
  "bash",
  "edit",
  "write",
  "read",
  "grep",
  "glob",
  "list",
  "apply_patch",
  "multiedit",
  "todowrite",
  "todoread",
  "task",
]);
const WEB_TOOL_PATTERN = /(fetch|browse|browser|navigate|url|web|playwright|chrome|page|open)/i;
const URL_SHAPED = /(:\/\/|\bwww\.|hxxp|\[\.\]|%2e|\uff0e|\u3002)/i;
const MAX_STRINGS = 200;

function leafToolName(tool) {
  return String(tool || "")
    .replace(/::/g, ".")
    .replace(/\//g, ".")
    .split(".")
    .pop()
    .toLowerCase();
}

function collectUrlStrings(value, out, depth = 0) {
  if (out.length >= MAX_STRINGS || depth > 6 || value == null) return out;
  if (typeof value === "string") {
    if (URL_SHAPED.test(value)) out.push(value);
    return out;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectUrlStrings(item, out, depth + 1);
    return out;
  }
  if (typeof value === "object") {
    for (const item of Object.values(value)) collectUrlStrings(item, out, depth + 1);
  }
  return out;
}

/**
 * Throw when a non-file tool call carries a redirect/shortener URL.
 * @param {string} tool
 * @param {object} args
 * @param {string} scriptsDir
 * @param {(cmd: string, argv: string[], opts: object) => string} [run]
 */
export function checkRedirectLinkToolGate(tool, args, scriptsDir, run = execFileSync) {
  const leaf = leafToolName(tool);
  if (EXEMPT_TOOLS.has(leaf) || /bounded_operation$/.test(leaf)) return;
  const strings = collectUrlStrings(args || {}, []);
  if (strings.length === 0) return;

  const webTool = WEB_TOOL_PATTERN.test(String(tool || ""));
  const scanner = join(scriptsDir || "", "redirect_link_policy.py");
  if (!scriptsDir || !existsSync(scanner)) {
    if (webTool) {
      throw new Error(
        "[aidevops] Redirect-link policy scanner unavailable; refusing URL tool call (GH#35655).",
      );
    }
    return;
  }

  let status = 0;
  let stdout = "";
  try {
    stdout = run("python3", [scanner, "scan"], {
      input: strings.join("\n"),
      encoding: "utf8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "ignore"],
    });
  } catch (error) {
    status = typeof error?.status === "number" ? error.status : 2;
    stdout = String(error?.stdout || "");
  }
  if (status === 0) return;
  if (status === 1) {
    let hosts = "redirect host";
    try {
      hosts = [...new Set(JSON.parse(stdout).redirect_links.map((item) => item.host))].join(", ");
    } catch {
      // keep generic host label
    }
    throw new Error(
      `[aidevops] BLOCKED: redirect/shortener link (${hosts}) must never be resolved, ` +
        "fetched or opened in any session, including remote sandboxes. Treat the source " +
        "content as spam (GH#35655).",
    );
  }
  if (webTool) {
    throw new Error(
      "[aidevops] Redirect-link policy scanner failed; refusing URL tool call (GH#35655).",
    );
  }
}
