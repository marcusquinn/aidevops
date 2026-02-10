#!/usr/bin/env node

// Playwright Contrast Extraction — Computed Style Analysis for All Visible Elements
// Part of AI DevOps Framework (t215.3)
//
// Traverses all visible DOM elements via page.evaluate(), extracts computed
// color/backgroundColor (walking ancestors for transparent), fontSize, fontWeight,
// calculates WCAG contrast ratios, and reports pass/fail per element.
//
// Usage: node playwright-contrast.mjs <url> [--format json|markdown|summary] [--level AA|AAA] [--limit N]
//
// Output: JSON array of contrast issues or Markdown report

import { chromium } from 'playwright';

// ============================================================================
// CLI Argument Parsing
// ============================================================================

function parseArgs() {
  const args = process.argv.slice(2);
  const options = {
    url: null,
    format: 'summary',
    level: 'AA',
    limit: 0,
    failOnly: false,
    timeout: 30000,
  };

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--format' || args[i] === '-f') {
      options.format = args[++i];
    } else if (args[i] === '--level' || args[i] === '-l') {
      options.level = args[++i]?.toUpperCase();
    } else if (args[i] === '--limit' || args[i] === '-n') {
      options.limit = parseInt(args[++i], 10);
    } else if (args[i] === '--fail-only') {
      options.failOnly = true;
    } else if (args[i] === '--timeout') {
      options.timeout = parseInt(args[++i], 10);
    } else if (args[i] === '--help' || args[i] === '-h') {
      printUsage();
      process.exit(0);
    } else if (!args[i].startsWith('-')) {
      options.url = args[i];
    }
  }

  if (!options.url) {
    console.error('ERROR: URL is required');
    printUsage();
    process.exit(1);
  }

  return options;
}

function printUsage() {
  console.log(`Usage: node playwright-contrast.mjs <url> [options]

Options:
  --format, -f   Output format: json, markdown, summary (default: summary)
  --level, -l    WCAG level: AA (default), AAA
  --limit, -n    Max elements to report (0 = all, default: 0)
  --fail-only    Only report failing elements
  --timeout      Page load timeout in ms (default: 30000)
  --help, -h     Show this help

Examples:
  node playwright-contrast.mjs https://example.com
  node playwright-contrast.mjs https://example.com --format json --fail-only
  node playwright-contrast.mjs https://example.com --level AAA --format markdown`);
}

// ============================================================================
// WCAG Contrast Calculation (runs in browser context via page.evaluate)
// ============================================================================

/**
 * This function runs entirely inside the browser via page.evaluate().
 * It traverses all visible elements, extracts computed styles, resolves
 * effective background colors (walking ancestors for transparent), calculates
 * WCAG contrast ratios, and returns structured results.
 */
function extractContrastData() {
  // --- Color parsing utilities ---

  function parseColor(colorStr) {
    if (!colorStr || colorStr === 'transparent') {
      return { r: 0, g: 0, b: 0, a: 0 };
    }

    // Handle rgba(r, g, b, a)
    const rgbaMatch = colorStr.match(
      /rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+))?\s*\)/
    );
    if (rgbaMatch) {
      return {
        r: parseInt(rgbaMatch[1], 10),
        g: parseInt(rgbaMatch[2], 10),
        b: parseInt(rgbaMatch[3], 10),
        a: rgbaMatch[4] !== undefined ? parseFloat(rgbaMatch[4]) : 1,
      };
    }

    // Handle hex colors (shouldn't appear in computed styles, but just in case)
    const hexMatch = colorStr.match(/^#([0-9a-f]{3,8})$/i);
    if (hexMatch) {
      const hex = hexMatch[1];
      if (hex.length === 3) {
        return {
          r: parseInt(hex[0] + hex[0], 16),
          g: parseInt(hex[1] + hex[1], 16),
          b: parseInt(hex[2] + hex[2], 16),
          a: 1,
        };
      }
      if (hex.length === 6) {
        return {
          r: parseInt(hex.substring(0, 2), 16),
          g: parseInt(hex.substring(2, 4), 16),
          b: parseInt(hex.substring(4, 6), 16),
          a: 1,
        };
      }
      if (hex.length === 8) {
        return {
          r: parseInt(hex.substring(0, 2), 16),
          g: parseInt(hex.substring(2, 4), 16),
          b: parseInt(hex.substring(4, 6), 16),
          a: parseInt(hex.substring(6, 8), 16) / 255,
        };
      }
    }

    return null;
  }

  // Alpha-composite foreground over background (both RGBA)
  function alphaComposite(fg, bg) {
    const a = fg.a + bg.a * (1 - fg.a);
    if (a === 0) return { r: 0, g: 0, b: 0, a: 0 };
    return {
      r: Math.round((fg.r * fg.a + bg.r * bg.a * (1 - fg.a)) / a),
      g: Math.round((fg.g * fg.a + bg.g * bg.a * (1 - fg.a)) / a),
      b: Math.round((fg.b * fg.a + bg.b * bg.a * (1 - fg.a)) / a),
      a,
    };
  }

  // WCAG relative luminance
  function relativeLuminance(r, g, b) {
    const [rs, gs, bs] = [r, g, b].map((c) => {
      const s = c / 255;
      return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * rs + 0.7152 * gs + 0.0722 * bs;
  }

  // WCAG contrast ratio
  function contrastRatio(l1, l2) {
    const lighter = Math.max(l1, l2);
    const darker = Math.min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
  }

  // Determine if text is "large" per WCAG (>= 18pt or >= 14pt bold)
  function isLargeText(fontSize, fontWeight) {
    const sizeInPt = parseFloat(fontSize) * 0.75; // px to pt
    const isBold =
      fontWeight === 'bold' ||
      fontWeight === 'bolder' ||
      parseInt(fontWeight, 10) >= 700;
    return sizeInPt >= 18 || (sizeInPt >= 14 && isBold);
  }

  // Generate a CSS selector for an element
  function getSelector(el) {
    if (el.id) return `#${CSS.escape(el.id)}`;

    const parts = [];
    let current = el;
    let depth = 0;

    while (current && current !== document.body && depth < 4) {
      let selector = current.tagName.toLowerCase();

      if (current.id) {
        selector = `#${CSS.escape(current.id)}`;
        parts.unshift(selector);
        break;
      }

      if (current.className && typeof current.className === 'string') {
        const classes = current.className
          .trim()
          .split(/\s+/)
          .filter((c) => c && !c.includes(':') && c.length < 40)
          .slice(0, 2);
        if (classes.length > 0) {
          selector += '.' + classes.map((c) => CSS.escape(c)).join('.');
        }
      }

      // Add nth-child if needed for disambiguation
      const parent = current.parentElement;
      if (parent) {
        const siblings = [...parent.children].filter(
          (s) => s.tagName === current.tagName
        );
        if (siblings.length > 1) {
          const index = siblings.indexOf(current) + 1;
          selector += `:nth-child(${index})`;
        }
      }

      parts.unshift(selector);
      current = current.parentElement;
      depth++;
    }

    return parts.join(' > ');
  }

  // Walk ancestors to find effective background color (resolve transparent)
  function getEffectiveBackground(el) {
    let bg = { r: 255, g: 255, b: 255, a: 1 }; // Default: white
    const ancestors = [];
    let current = el;

    // Collect ancestors from element up to body
    while (current) {
      ancestors.push(current);
      current = current.parentElement;
    }

    // Process from root (body) down to element, compositing backgrounds
    bg = { r: 255, g: 255, b: 255, a: 1 }; // Start with white (page default)
    for (let i = ancestors.length - 1; i >= 0; i--) {
      const style = window.getComputedStyle(ancestors[i]);
      const bgColor = parseColor(style.backgroundColor);
      if (bgColor && bgColor.a > 0) {
        bg = alphaComposite(bgColor, bg);
      }

      // Factor in element opacity
      const opacity = parseFloat(style.opacity);
      if (opacity < 1) {
        bg = { ...bg, a: bg.a * opacity };
      }
    }

    return bg;
  }

  // Check if element has a background image or gradient (flag for manual review)
  function hasComplexBackground(el) {
    const flags = [];
    let current = el;
    let depth = 0;

    while (current && depth < 6) {
      const style = window.getComputedStyle(current);
      const bgImage = style.backgroundImage;

      if (bgImage && bgImage !== 'none') {
        if (bgImage.includes('gradient')) {
          flags.push('gradient');
        } else if (bgImage.includes('url(')) {
          flags.push('background-image');
        }
      }

      current = current.parentElement;
      depth++;
    }

    return flags.length > 0 ? [...new Set(flags)] : null;
  }

  // Check if element is visible
  function isVisible(el) {
    if (!el.offsetParent && el.tagName !== 'BODY' && el.tagName !== 'HTML') {
      return false;
    }
    const style = window.getComputedStyle(el);
    if (
      style.display === 'none' ||
      style.visibility === 'hidden' ||
      parseFloat(style.opacity) === 0
    ) {
      return false;
    }
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) return false;
    return true;
  }

  // Check if element contains direct text content
  function hasDirectText(el) {
    for (const node of el.childNodes) {
      if (node.nodeType === Node.TEXT_NODE && node.textContent.trim().length > 0) {
        return true;
      }
    }
    return false;
  }

  // --- Main extraction ---

  const results = [];
  const allElements = document.querySelectorAll('*');
  const seen = new Set(); // Deduplicate by selector

  for (const el of allElements) {
    // Skip non-visible elements
    if (!isVisible(el)) continue;

    // Skip elements without direct text content (we care about text contrast)
    if (!hasDirectText(el)) continue;

    // Skip script, style, meta elements
    const tag = el.tagName.toLowerCase();
    if (['script', 'style', 'meta', 'link', 'noscript', 'br', 'hr'].includes(tag)) {
      continue;
    }

    const selector = getSelector(el);
    if (seen.has(selector)) continue;
    seen.add(selector);

    const style = window.getComputedStyle(el);
    const fgColor = parseColor(style.color);
    if (!fgColor) continue;

    const bgColor = getEffectiveBackground(el);
    const complexBg = hasComplexBackground(el);

    // Apply element opacity to foreground color
    const elOpacity = parseFloat(style.opacity);
    const effectiveFg =
      elOpacity < 1
        ? { ...fgColor, a: fgColor.a * elOpacity }
        : fgColor;

    // Composite foreground over background for final colors
    const finalFg = alphaComposite(effectiveFg, bgColor);
    const finalBg = bgColor;

    // Calculate luminance and contrast ratio
    const fgLum = relativeLuminance(finalFg.r, finalFg.g, finalFg.b);
    const bgLum = relativeLuminance(finalBg.r, finalBg.g, finalBg.b);
    const ratio = contrastRatio(fgLum, bgLum);

    // Determine text size category
    const fontSize = style.fontSize;
    const fontWeight = style.fontWeight;
    const largeText = isLargeText(fontSize, fontWeight);

    // WCAG thresholds
    const aaThreshold = largeText ? 3.0 : 4.5;
    const aaaThreshold = largeText ? 4.5 : 7.0;

    // Get a text snippet for context
    let textSnippet = '';
    for (const node of el.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        textSnippet += node.textContent.trim() + ' ';
      }
    }
    textSnippet = textSnippet.trim().substring(0, 80);

    results.push({
      selector,
      tag,
      text: textSnippet,
      foreground: `rgb(${finalFg.r}, ${finalFg.g}, ${finalFg.b})`,
      background: `rgb(${finalBg.r}, ${finalBg.g}, ${finalBg.b})`,
      foregroundRaw: style.color,
      backgroundRaw: style.backgroundColor,
      fontSize,
      fontWeight,
      isLargeText: largeText,
      ratio: Math.round(ratio * 100) / 100,
      aa: {
        threshold: aaThreshold,
        pass: ratio >= aaThreshold,
        criterion: largeText ? '1.4.3 (large text)' : '1.4.3',
      },
      aaa: {
        threshold: aaaThreshold,
        pass: ratio >= aaaThreshold,
        criterion: largeText ? '1.4.6 (large text)' : '1.4.6',
      },
      complexBackground: complexBg,
    });
  }

  return results;
}

// ============================================================================
// Output Formatters
// ============================================================================

function formatSummary(results, level) {
  const failures = results.filter(
    (r) => !(level === 'AAA' ? r.aaa.pass : r.aa.pass)
  );
  const passes = results.length - failures.length;
  const complexBgCount = results.filter((r) => r.complexBackground).length;

  const lines = [];
  lines.push('');
  lines.push('--- Playwright Contrast Extraction ---');
  lines.push(`  Elements analysed: ${results.length}`);
  lines.push(`  WCAG ${level} Pass: ${passes}`);
  lines.push(`  WCAG ${level} Fail: ${failures.length}`);
  if (complexBgCount > 0) {
    lines.push(
      `  Complex backgrounds (manual review): ${complexBgCount}`
    );
  }
  lines.push('');

  if (failures.length > 0) {
    lines.push(`--- Failing Elements (WCAG ${level}) ---`);
    for (const f of failures) {
      const threshold =
        level === 'AAA' ? f.aaa.threshold : f.aa.threshold;
      const criterion =
        level === 'AAA' ? f.aaa.criterion : f.aa.criterion;
      lines.push(`  ${f.selector}`);
      lines.push(
        `    Ratio: ${f.ratio}:1 (need ${threshold}:1) — SC ${criterion}`
      );
      lines.push(`    FG: ${f.foreground} | BG: ${f.background}`);
      lines.push(
        `    Size: ${f.fontSize} weight: ${f.fontWeight}${f.isLargeText ? ' (large text)' : ''}`
      );
      if (f.text) {
        lines.push(`    Text: "${f.text}"`);
      }
      if (f.complexBackground) {
        lines.push(
          `    WARNING: ${f.complexBackground.join(', ')} — manual review needed`
        );
      }
      lines.push('');
    }
  }

  if (complexBgCount > 0) {
    lines.push('--- Elements with Complex Backgrounds ---');
    for (const r of results.filter((r) => r.complexBackground)) {
      lines.push(
        `  ${r.selector} — ${r.complexBackground.join(', ')} (ratio: ${r.ratio}:1)`
      );
    }
    lines.push('');
  }

  return lines.join('\n');
}

function formatMarkdown(results, level) {
  const failures = results.filter(
    (r) => !(level === 'AAA' ? r.aaa.pass : r.aa.pass)
  );
  const passes = results.length - failures.length;

  const lines = [];
  lines.push(`## Contrast Analysis Report (WCAG ${level})`);
  lines.push('');
  lines.push(`| Metric | Value |`);
  lines.push(`|--------|-------|`);
  lines.push(`| Elements analysed | ${results.length} |`);
  lines.push(`| Pass | ${passes} |`);
  lines.push(`| Fail | ${failures.length} |`);
  lines.push('');

  if (failures.length > 0) {
    lines.push(`### Failing Elements`);
    lines.push('');
    lines.push(
      `| Element | Ratio | Required | FG | BG | Size | WCAG |`
    );
    lines.push(
      `|---------|-------|----------|----|----|------|------|`
    );
    for (const f of failures) {
      const threshold =
        level === 'AAA' ? f.aaa.threshold : f.aa.threshold;
      const criterion =
        level === 'AAA' ? f.aaa.criterion : f.aa.criterion;
      const sizeInfo = `${f.fontSize} ${f.fontWeight}${f.isLargeText ? ' (L)' : ''}`;
      const selectorShort =
        f.selector.length > 40
          ? f.selector.substring(0, 37) + '...'
          : f.selector;
      lines.push(
        `| \`${selectorShort}\` | ${f.ratio}:1 | ${threshold}:1 | ${f.foreground} | ${f.background} | ${sizeInfo} | SC ${criterion} |`
      );
    }
    lines.push('');
  }

  return lines.join('\n');
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  const options = parseArgs();
  let browser;

  try {
    browser = await chromium.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-gpu'],
    });

    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
    });

    const page = await context.newPage();

    // Navigate to URL — use 'load' instead of 'networkidle' to avoid hanging
    // on sites with persistent connections (analytics, websockets, etc.)
    await page.goto(options.url, {
      waitUntil: 'load',
      timeout: options.timeout,
    });

    // Allow dynamic content to settle (CSS, web fonts, lazy styles)
    await page.waitForTimeout(1500);

    // Extract contrast data from all visible elements
    const results = await page.evaluate(extractContrastData);

    // Apply filters
    let filtered = results;
    if (options.failOnly) {
      filtered = results.filter(
        (r) => !(options.level === 'AAA' ? r.aaa.pass : r.aa.pass)
      );
    }
    if (options.limit > 0) {
      filtered = filtered.slice(0, options.limit);
    }

    // Output
    switch (options.format) {
      case 'json':
        console.log(JSON.stringify(filtered, null, 2));
        break;
      case 'markdown':
        console.log(formatMarkdown(results, options.level));
        break;
      case 'summary':
      default:
        console.log(formatSummary(results, options.level));
        break;
    }

    // Exit code: 1 if any failures at the requested level
    const hasFailures = results.some(
      (r) => !(options.level === 'AAA' ? r.aaa.pass : r.aa.pass)
    );

    await browser.close().catch(() => {});
    process.exit(hasFailures ? 1 : 0);
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    if (browser) {
      await browser.close().catch(() => {});
    }
    process.exit(2);
  }
}

main();
