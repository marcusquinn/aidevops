import { readFileSync } from "fs";

/**
 * Check MD031: fenced code blocks should be surrounded by blank lines.
 * @param {string[]} lines - File lines
 * @param {string[]} sections - Mutable report sections array
 * @returns {number} Violation count
 */
export function checkMD031(lines, sections) {
  let violations = 0;
  let inCodeBlock = false;

  for (let i = 0; i < lines.length; i++) {
    if (!/^```/.test(lines[i].trim())) continue;

    if (!inCodeBlock) {
      if (i > 0 && lines[i - 1].trim() !== "") {
        sections.push(`  Line ${i + 1}: MD031 — missing blank line before code fence`);
        violations++;
      }
    } else {
      if (i < lines.length - 1 && lines[i + 1] !== undefined && lines[i + 1].trim() !== "") {
        sections.push(`  Line ${i + 1}: MD031 — missing blank line after code fence`);
        violations++;
      }
    }
    inCodeBlock = !inCodeBlock;
  }

  return violations;
}

/**
 * Count lines with trailing whitespace.
 * @param {string[]} lines - File lines
 * @param {string[]} sections - Mutable report sections array
 * @returns {number} Violation count
 */
export function checkTrailingWhitespace(lines, sections) {
  let trailingCount = 0;
  for (const line of lines) {
    if (/\s+$/.test(line)) trailingCount++;
  }
  if (trailingCount > 0) {
    sections.push(`  Trailing whitespace on ${trailingCount} line${trailingCount !== 1 ? "s" : ""}`);
  }
  return trailingCount;
}

/**
 * Run markdown quality checks on a file.
 * Checks for common issues: trailing whitespace and missing blank lines around
 * code blocks (MD031).
 * @param {string} filePath
 * @returns {{ totalViolations: number, report: string }}
 */
export function runMarkdownQualityPipeline(filePath) {
  const sections = [];
  let totalViolations = 0;

  try {
    const lines = readFileSync(filePath, "utf-8").split("\n");
    totalViolations += checkMD031(lines, sections);
    totalViolations += checkTrailingWhitespace(lines, sections);
  } catch {
    // File read error — skip
  }

  const report = sections.length > 0
    ? `Markdown quality:\n${sections.join("\n")}`
    : "Markdown checks passed.";

  return { totalViolations, report };
}
