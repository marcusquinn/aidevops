// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { ok as assert } from "node:assert/strict";
import { isAbsolute, win32 } from "node:path";

const PLAYWRIGHT_OUTPUT_TOOLS = new Set([
  "playwright_browser_console_messages",
  "playwright_browser_evaluate",
  "playwright_browser_network_request",
  "playwright_browser_network_requests",
  "playwright_browser_pdf_save",
  "playwright_browser_snapshot",
  "playwright_browser_start_video",
  "playwright_browser_storage_state",
  "playwright_browser_take_screenshot",
]);

/** Reject output filenames that escape the managed Playwright workspace. */
export function enforceManagedMcpArtifactPath(input, output, managedWorkspaces) {
  if (!managedWorkspaces?.playwright || !PLAYWRIGHT_OUTPUT_TOOLS.has(input?.tool)) return;
  const filename = output?.args?.filename;
  if (filename === undefined || filename === null || filename === "") return;
  assert(
    typeof filename === "string",
    new Error("Playwright screenshot filename must be a relative path inside managed temporary storage."),
  );
  const segments = filename.split(/[\\/]+/);
  assert(
    !isAbsolute(filename) && !win32.isAbsolute(filename) && !segments.includes(".."),
    new Error("Playwright screenshot filename must not be absolute or contain '..' traversal."),
  );
}
