// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync } from "node:fs";
import { directFileMutationKind, directFileMutations } from "./quality-hooks-git-safety.mjs";
import { REDACTION_TOKEN, PEM_REDACTION_TOKEN } from "./quality-hooks-output-scrub.mjs";

const TOKENS = [REDACTION_TOKEN, PEM_REDACTION_TOKEN];
const GUIDANCE = "Edit blocked: display-redaction placeholders are not original file bytes. "
  + "Use a smaller edit whose oldString and newString exclude the redacted span. "
  + "Do not copy scrubbed Read output into a replacement or recover credentials into tool arguments.";

function tokenCount(text, token) {
  return typeof text === "string" ? text.split(token).length - 1 : 0;
}

/** Fail closed before Edit's fuzzy matching can write a scrubbed display token.
 * Call only after canonical-write and source-access checks have passed.
 * Literal placeholders remain editable when the entire old text exists on disk.
 * No original bytes are returned, logged, cached, or substituted into tool args.
 */
export function checkRedactedEdit(tool, args = {}, repositoryDir = "") {
  if (directFileMutationKind(tool) !== "edit") return;
  const oldText = args.oldString ?? args.old_string;
  const newText = args.newString ?? args.new_string;
  if (!TOKENS.some((token) => tokenCount(oldText, token) || tokenCount(newText, token))) return;

  if (typeof oldText !== "string" || !oldText || typeof newText !== "string"
    || TOKENS.some((token) => tokenCount(newText, token) > tokenCount(oldText, token))) {
    throw new Error(GUIDANCE);
  }
  const [mutation] = directFileMutations(tool, args, repositoryDir);
  let exactMatch = false;
  try {
    exactMatch = Boolean(mutation && readFileSync(mutation.filePath, "utf8").includes(oldText));
  } catch {
    // Missing/unreadable targets cannot establish literal placeholder provenance.
  }
  if (!exactMatch) throw new Error(GUIDANCE);
}
