// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
// Contrast report formatting shared by the Playwright extraction CLI.

function getLevel(element, level) {
  return level === 'AAA' ? element.aaa : element.aa;
}

export function isFailingAtLevel(element, level) {
  return !element.complexBackground && getLevel(element, level).pass === false;
}

function formatFailureLines(f, level) {
  const { threshold, criterion } = getLevel(f, level);
  const lines = [`  ${f.selector}`, `    Ratio: ${f.ratio}:1 (need ${threshold}:1) — SC ${criterion}`, `    FG: ${f.foreground} | BG: ${f.background}`, `    Size: ${f.fontSize} weight: ${f.fontWeight}${f.isLargeText ? ' (large text)' : ''}`];
  if (f.text) lines.push(`    Text: "${f.text}"`);
  if (f.complexBackground) lines.push(`    WARNING: ${f.complexBackground.join(', ')} — manual review needed`);
  lines.push('');
  return lines;
}

export function formatSummary(results, level) {
  const failures = results.filter((r) => isFailingAtLevel(r, level));
  const complex = results.filter((r) => r.complexBackground);
  const lines = ['', '--- Playwright Contrast Extraction ---', `  Elements analysed: ${results.length}`, `  WCAG ${level} Pass: ${results.length - failures.length - complex.length}`, `  WCAG ${level} Fail: ${failures.length}`];
  if (complex.length > 0) lines.push(`  Complex backgrounds (manual review): ${complex.length}`);
  lines.push('');
  if (failures.length > 0) {
    lines.push(`--- Failing Elements (WCAG ${level}) ---`);
    for (const f of failures) lines.push(...formatFailureLines(f, level));
  }
  if (complex.length > 0) {
    lines.push('--- Elements with Complex Backgrounds ---');
    for (const r of complex) lines.push(`  ${r.selector} — ${r.complexBackground.join(', ')} — needs manual/pixel check`);
    lines.push('');
  }
  return lines.join('\n');
}

export function formatMarkdown(results, level) {
  const failures = results.filter((r) => isFailingAtLevel(r, level));
  const complex = results.filter((r) => r.complexBackground);
  const lines = [`## Contrast Analysis Report (WCAG ${level})`, '', `| Metric | Value |`, `|--------|-------|`, `| Elements analysed | ${results.length} |`, `| Pass | ${results.length - failures.length - complex.length} |`, `| Fail | ${failures.length} |`, `| Needs manual/pixel check | ${complex.length} |`, ''];
  if (failures.length > 0) {
    lines.push(`### Failing Elements`, '', `| Element | Ratio | Required | FG | BG | Size | WCAG |`, `|---------|-------|----------|----|----|------|------|`);
    for (const f of failures) {
      const { threshold, criterion } = getLevel(f, level);
      const sel = f.selector.length > 40 ? `${f.selector.substring(0, 37)}...` : f.selector;
      lines.push(`| \`${sel}\` | ${f.ratio}:1 | ${threshold}:1 | ${f.foreground} | ${f.background} | ${f.fontSize} ${f.fontWeight}${f.isLargeText ? ' (L)' : ''} | SC ${criterion} |`);
    }
    lines.push('');
  }
  if (complex.length > 0) {
    lines.push('### Needs manual/pixel check', '');
    for (const r of complex) lines.push(`- \`${r.selector}\`: ${r.complexBackground.join(', ')}`);
    lines.push('');
  }
  return lines.join('\n');
}
