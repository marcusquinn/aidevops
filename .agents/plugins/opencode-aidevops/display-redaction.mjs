// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Display-redaction precision (GH#37382).
 *
 * A sensitive name followed by ":" or "=" is not always an assignment.
 * Unquoted code expressions and prose after a label are not literals, so they
 * stay visible. Quoted, bracketed, URL, PEM and token-prefix values are never
 * exempted, and no entropy threshold applies (GH#35829). Unspaced dotenv/shell
 * `NAME=value` keeps only the keyword and Markdown-emphasis exemptions.
 * Mirrored in .agents/hooks/credential-transcript-scrub.py.
 */

const LITERAL_START = /^["'([<]/;
const ARROW_FOLLOWS = /^\s*=>/;
const NON_LITERAL_KEYWORDS = new Set(["async", "await", "false", "function", "lambda", "new", "nil", "true", "typeof", "yield"]);
const TYPE_ANNOTATION_NAMES = new Set([
  "any", "array", "bool", "boolean", "bytes", "dict", "float", "int", "list", "number", "object", "optional",
  "promise", "record", "str", "string", "unknown",
]);
const CODE_EXPRESSION =
  /^(?:[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\(|(?:process\.env|import\.meta\.env|os\.environ|ENV)(?:[.[]|$))/;
const EMPHASIS_ONLY = /^[*_]+$/;
const CONSTANT_REFERENCE = /^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$/;
const PROSE_WORD = /^[A-Za-z][a-z]{0,19}$/;
const PROSE_STOP_WORDS = new Set([
  "a", "an", "and", "are", "as", "be", "by", "for", "if", "in", "is", "it", "not", "of", "on", "or", "the",
  "that", "this", "to", "with", "you", "your",
]);
const TRAILING_COMMENT = /^[ \t]+(?:#|\/\/|;)/;
const MAX_FOLLOWING_CONTEXT = 200;

function isProseLabelValue(value, following) {
  if (!PROSE_WORD.test(value) || !/^[ \t]/.test(following) || TRAILING_COMMENT.test(following)) return false;
  return following.trimStart().split(/[ \t]+/, 4).some((word) => PROSE_STOP_WORDS.has(word.toLowerCase()));
}

const isKeyword = ({ value }) => NON_LITERAL_KEYWORDS.has(value.toLowerCase());
const isEmphasis = ({ value }) => EMPHASIS_ONLY.test(value);
const UNSPACED_RULES = [isKeyword, isEmphasis];
const SPACED_RULES = [
  isKeyword,
  isEmphasis,
  ({ value }) => CODE_EXPRESSION.test(value),
  ({ operator, value }) => operator === ":" && TYPE_ANNOTATION_NAMES.has(value.split(/[[<.]/, 1)[0].toLowerCase()),
  ({ operator, value, following }) => operator === "=" && CONSTANT_REFERENCE.test(value) && following.startsWith(";"),
  ({ operator, value, following }) => operator === ":" && isProseLabelValue(value, following),
];

/** Rest of the matched line, bounded so per-match context stays linear. */
export function followingLineText(source, index) {
  const lineEnd = source.indexOf("\n", index);
  const end = Math.min(lineEnd < 0 ? source.length : lineEnd, index + MAX_FOLLOWING_CONTEXT);
  return source.slice(index, end);
}

/** True when an unquoted value after a sensitive name is code or prose, not a literal. */
export function isCodeOrProseValue(separator, value, following = "") {
  if (ARROW_FOLLOWS.test(following)) return true;
  if (LITERAL_START.test(value)) return false;
  const operator = separator.trim();
  const rules = separator === operator ? UNSPACED_RULES : SPACED_RULES;
  return rules.some((rule) => rule({ operator, value, following }));
}

export const DISPLAY_REDACTION_NOTE_PREFIX = "[aidevops display filter:";

/**
 * In-band notice that placeholders came from this filter, not the source.
 * Without it, models report placeholders as content bugs and copy them into
 * files. The notice never contains a placeholder token itself.
 */
export function displayRedactionNote(count) {
  return `${DISPLAY_REDACTION_NOTE_PREFIX} ${count} span(s) in this tool result were replaced with redaction `
    + "placeholders; the source bytes are unchanged. Check the raw source (for example with rg -c) before "
    + "reporting, quoting or copying redacted text.]";
}

/** Append the notice when redaction placeholders are visible in string tool output. */
export function appendDisplayRedactionNote(output, redactionCount, tokens) {
  if (redactionCount <= 0 || typeof output.output !== "string") return;
  if (!tokens.some((token) => output.output.includes(token))) return;
  output.output = `${output.output}\n\n${displayRedactionNote(redactionCount)}`;
}
