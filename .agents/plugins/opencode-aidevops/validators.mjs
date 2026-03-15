import { readFileSync } from "fs";

/**
 * Try to match a shell function definition on a line.
 * @param {string} trimmed - Trimmed line content
 * @returns {string|null} Function name if matched, null otherwise
 */
function matchFunctionDef(trimmed) {
  const funcMatch = trimmed.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)\s*\{/);
  if (funcMatch) return funcMatch[1];

  const funcMatch2 = trimmed.match(/^function\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
  if (funcMatch2) return funcMatch2[1];

  return null;
}

/**
 * Count brace depth change in a line.
 * @param {string} trimmed - Trimmed line content
 * @returns {number} Net brace depth change
 */
function braceDepthDelta(trimmed) {
  let delta = 0;
  for (const ch of trimmed) {
    if (ch === "{") delta++;
    else if (ch === "}") delta--;
  }
  return delta;
}

/**
 * Check if a line contains a shell return statement.
 * @param {string} trimmed - Trimmed line content
 * @returns {boolean}
 */
function hasReturnStatement(trimmed) {
  return /\breturn\s+[0-9]/.test(trimmed) || /\breturn\s*$/.test(trimmed);
}

/**
 * Record a missing-return violation.
 * @param {string[]} details - Mutable details array
 * @param {number} functionStart - 1-based line number
 * @param {string} functionName
 * @returns {number} 1 (violation count increment)
 */
function recordMissingReturn(details, functionStart, functionName) {
  details.push(
    `  Line ${functionStart}: function '${functionName}' missing explicit return`,
  );
  return 1;
}

/**
 * Check if the current function (being tracked) is missing a return and record it.
 * @param {object} state - Mutable function-tracking state
 * @param {string[]} details - Mutable details array
 * @returns {number} 0 or 1
 */
function checkAndRecordMissingReturn(state, details) {
  if (state.inFunction && !state.hasReturn) {
    return recordMissingReturn(details, state.functionStart, state.functionName);
  }
  return 0;
}

/**
 * Begin tracking a new function definition.
 * @param {object} state - Mutable function-tracking state
 * @param {string} name - Function name
 * @param {number} lineIndex - 0-based line index
 * @param {string} trimmed - Trimmed line content
 */
function beginFunction(state, name, lineIndex, trimmed) {
  state.inFunction = true;
  state.functionName = name;
  state.functionStart = lineIndex + 1;
  state.braceDepth = trimmed.includes("{") ? 1 : 0;
  state.hasReturn = false;
}

/**
 * Walk shell script lines tracking function boundaries and return statements.
 * @param {string[]} lines - File lines
 * @param {string[]} details - Mutable details array
 * @returns {number} Total violation count
 */
export function walkFunctionsForReturns(lines, details) {
  let violations = 0;
  const state = { inFunction: false, functionName: "", functionStart: 0, braceDepth: 0, hasReturn: false };

  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    const name = matchFunctionDef(trimmed);

    if (name) {
      violations += checkAndRecordMissingReturn(state, details);
      beginFunction(state, name, i, trimmed);
      continue;
    }

    if (!state.inFunction) continue;

    state.braceDepth += braceDepthDelta(trimmed);
    if (hasReturnStatement(trimmed)) state.hasReturn = true;

    if (state.braceDepth <= 0) {
      violations += checkAndRecordMissingReturn(state, details);
      state.inFunction = false;
    }
  }

  violations += checkAndRecordMissingReturn(state, details);
  return violations;
}

/**
 * Validate shell script return statements.
 * Checks that functions have explicit return statements (aidevops convention).
 * @param {string} filePath
 * @returns {{ violations: number, details: string[] }}
 */
export function validateReturnStatements(filePath) {
  const details = [];
  let violations = 0;

  try {
    const content = readFileSync(filePath, "utf-8");
    violations = walkFunctionsForReturns(content.split("\n"), details);
  } catch {
    // File read error — skip validation
  }

  return { violations, details };
}

/** Patterns for shell constructs where direct $N usage is acceptable. */
export const ALLOWED_POSITIONAL_PATTERNS = [
  /^\s*shift/,
  /case\s+.*\$[1-9]/,
  /getopts/,
  /"\$@"/,
  /"\$\*"/,
];

/**
 * Check if a line uses a shift, case, or getopts pattern that allows direct $N.
 * @param {string} trimmed - Trimmed line content
 * @returns {boolean}
 */
function isShiftOrCasePattern(trimmed) {
  return ALLOWED_POSITIONAL_PATTERNS.some((re) => re.test(trimmed));
}

/** Patterns that indicate currency/pricing/table contexts (false-positives for $N params). */
export const PRICE_TABLE_PATTERNS = [
  { re: /\$[1-9][0-9.,]/, useStripped: true },
  { re: /\$[1-9]\/(?:mo(?:nth)?|yr|year|day|week|hr|hour)\b/, useStripped: true },
  { re: /\$[1-9]\s+(?:per|mo(?:nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)\b/, useStripped: true },
  { re: /^\s*\|/, useStripped: false },
  { re: /\$[1-9]\s*\|/, useStripped: true },
];

/**
 * Check if a line contains a currency/pricing pattern (false-positive for $N params).
 * @param {string} stripped - Line with escaped dollar signs removed
 * @param {string} rawLine - Original unstripped line
 * @returns {boolean}
 */
function isPriceOrTablePattern(stripped, rawLine) {
  return PRICE_TABLE_PATTERNS.some((p) => p.re.test(p.useStripped ? stripped : rawLine));
}

/**
 * Check whether a trimmed line has a bare positional $N that isn't in a local assignment.
 * @param {string} trimmed - Trimmed line content
 * @returns {boolean}
 */
export function hasBarePositionalParam(trimmed) {
  return /\$[1-9]/.test(trimmed) && !/local\s+\w+=.*\$[1-9]/.test(trimmed);
}

/**
 * Check whether stripped content still contains unescaped $N after removing \$N.
 * Also returns false if the remaining $N matches a price/table pattern.
 * @param {string} trimmed - Trimmed line content
 * @param {string} rawLine - Original unstripped line
 * @returns {boolean} true if a real positional param violation exists
 */
export function hasUnescapedPositionalParam(trimmed, rawLine) {
  const stripped = trimmed.replace(/\\\$[1-9]/g, "");
  if (!/\$[1-9]/.test(stripped)) return false;
  if (isPriceOrTablePattern(stripped, rawLine)) return false;
  return true;
}

/**
 * Check a single line for positional parameter violations.
 * @param {string} line - Raw line content
 * @param {string} trimmed - Trimmed line content
 * @param {number} lineNum - 1-based line number
 * @param {string[]} details - Mutable details array
 * @returns {number} 0 or 1 (violation count increment)
 */
export function checkPositionalParamLine(line, trimmed, lineNum, details) {
  if (trimmed.startsWith("#") || !hasBarePositionalParam(trimmed)) return 0;
  if (isShiftOrCasePattern(trimmed)) return 0;
  if (!hasUnescapedPositionalParam(trimmed, line)) return 0;

  details.push(`  Line ${lineNum}: direct positional parameter: ${trimmed.substring(0, 80)}`);
  return 1;
}

/**
 * Validate positional parameter usage in shell scripts.
 * Checks that $1, $2, etc. are assigned to local variables (aidevops convention).
 * @param {string} filePath
 * @returns {{ violations: number, details: string[] }}
 */
export function validatePositionalParams(filePath) {
  const details = [];
  let violations = 0;

  try {
    const content = readFileSync(filePath, "utf-8");
    const lines = content.split("\n");

    for (let i = 0; i < lines.length; i++) {
      violations += checkPositionalParamLine(lines[i], lines[i].trim(), i + 1, details);
    }
  } catch {
    // File read error — skip validation
  }

  return { violations, details };
}
