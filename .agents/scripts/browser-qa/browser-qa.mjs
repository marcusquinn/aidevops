#!/usr/bin/env node

// Browser QA Worker — Playwright-based visual QA for milestone validation
// Part of AI DevOps Framework (t1359)
//
// Launches headless Playwright, navigates pages, screenshots key views,
// checks for broken links, console errors, missing content, and empty pages.
// Outputs a structured JSON report.
//
// Usage: node browser-qa.mjs <base-url> [options]
//
// Options:
//   --output-dir <dir>     Directory for screenshots and report (default: /tmp/browser-qa)
//   --flows <json>         JSON array of flow definitions (URLs or {url, actions} objects)
//   --timeout <ms>         Page load timeout (default: 30000)
//   --viewport <WxH>       Viewport size (default: 1280x720)
//   --check-links          Check all links on each page for broken hrefs (default: true)
//   --no-check-links       Disable link checking
//   --max-links <n>        Max links to check per page (default: 50)
//   --format <type>        Output format: json, summary (default: summary)
//   --help                 Show help

import { chromium } from 'playwright';
import { writeFileSync, mkdirSync, existsSync } from 'fs';
import { join, basename } from 'path';

// ============================================================================
// CLI Argument Parsing
// ============================================================================

function parseArgs() {
  const args = process.argv.slice(2);
  const options = {
    baseUrl: null,
    outputDir: '/tmp/browser-qa',
    flows: null,
    timeout: 30000,
    viewportWidth: 1280,
    viewportHeight: 720,
    checkLinks: true,
    maxLinks: 50,
    format: 'summary',
  };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--output-dir':
        options.outputDir = args[++i];
        break;
      case '--flows':
        options.flows = args[++i];
        break;
      case '--timeout':
        options.timeout = parseInt(args[++i], 10);
        break;
      case '--viewport': {
        const parts = args[++i].split('x');
        options.viewportWidth = parseInt(parts[0], 10);
        options.viewportHeight = parseInt(parts[1], 10);
        break;
      }
      case '--check-links':
        options.checkLinks = true;
        break;
      case '--no-check-links':
        options.checkLinks = false;
        break;
      case '--max-links':
        options.maxLinks = parseInt(args[++i], 10);
        break;
      case '--format':
        options.format = args[++i];
        break;
      case '--help':
      case '-h':
        printUsage();
        process.exit(0);
        break;
      default:
        if (!args[i].startsWith('-') && !options.baseUrl) {
          options.baseUrl = args[i];
        }
        break;
    }
  }

  if (!options.baseUrl) {
    console.error('ERROR: Base URL is required');
    printUsage();
    process.exit(2);
  }

  return options;
}

function printUsage() {
  console.log(`Usage: node browser-qa.mjs <base-url> [options]

Options:
  --output-dir <dir>     Screenshot/report directory (default: /tmp/browser-qa)
  --flows <json>         JSON array of URLs or {url, name, actions} objects
  --timeout <ms>         Page load timeout (default: 30000)
  --viewport <WxH>       Viewport size (default: 1280x720)
  --check-links          Check links for broken hrefs (default: on)
  --no-check-links       Disable link checking
  --max-links <n>        Max links to check per page (default: 50)
  --format <type>        Output: json, summary (default: summary)
  --help                 Show this help

Examples:
  node browser-qa.mjs http://localhost:3000
  node browser-qa.mjs http://localhost:3000 --flows '["/about","/contact"]'
  node browser-qa.mjs http://localhost:8080 --output-dir ./qa-results --format json`);
}

// ============================================================================
// QA Checks
// ============================================================================

/**
 * Capture console errors and failed network requests during page lifecycle.
 * Returns {consoleErrors: string[], networkErrors: string[]}.
 */
function attachErrorListeners(page) {
  const errors = { consoleErrors: [], networkErrors: [] };

  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      errors.consoleErrors.push(msg.text());
    }
  });

  page.on('pageerror', (err) => {
    errors.consoleErrors.push(`Uncaught: ${err.message}`);
  });

  page.on('requestfailed', (req) => {
    const failure = req.failure();
    errors.networkErrors.push(
      `${req.method()} ${req.url()} — ${failure ? failure.errorText : 'unknown'}`
    );
  });

  return errors;
}

/**
 * Navigate to a URL, wait for load, capture screenshot and page metadata.
 */
async function visitPage(page, url, outputDir, options) {
  const result = {
    url,
    status: null,
    title: '',
    screenshot: null,
    ariaSnapshot: null,
    isEmpty: false,
    hasErrorState: false,
    consoleErrors: [],
    networkErrors: [],
    linkResults: [],
    loadTimeMs: 0,
    passed: true,
    failures: [],
  };

  const errors = attachErrorListeners(page);
  const startTime = Date.now();

  try {
    const response = await page.goto(url, {
      waitUntil: 'load',
      timeout: options.timeout,
    });

    result.status = response ? response.status() : null;
    result.loadTimeMs = Date.now() - startTime;

    // Wait for dynamic content to settle
    await page.waitForTimeout(1500);

    result.title = await page.title();

    // Check for HTTP error status
    if (result.status && result.status >= 400) {
      result.passed = false;
      result.failures.push(`HTTP ${result.status} response`);
    }

    // Check for empty page
    const bodyText = await page.evaluate(() =>
      document.body ? document.body.innerText.trim() : ''
    );
    if (bodyText.length < 10) {
      result.isEmpty = true;
      result.passed = false;
      result.failures.push(
        `Page appears empty (body text: ${bodyText.length} chars)`
      );
    }

    // Check for common error states
    const errorIndicators = await page.evaluate(() => {
      const body = document.body ? document.body.innerText.toLowerCase() : '';
      const indicators = [];
      const patterns = [
        'application error',
        'internal server error',
        'something went wrong',
        'page not found',
        'cannot get',
        'module not found',
        'unhandled runtime error',
        'hydration failed',
        'chunk load error',
      ];
      for (const pattern of patterns) {
        if (body.includes(pattern)) {
          indicators.push(pattern);
        }
      }
      return indicators;
    });

    if (errorIndicators.length > 0) {
      result.hasErrorState = true;
      result.passed = false;
      result.failures.push(
        `Error state detected: ${errorIndicators.join(', ')}`
      );
    }

    // Capture ARIA snapshot (lightweight structural representation)
    try {
      result.ariaSnapshot = await page
        .locator('body')
        .ariaSnapshot({ timeout: 5000 });
    } catch {
      // ARIA snapshot may fail on some pages — non-fatal
      result.ariaSnapshot = null;
    }

    // Take screenshot
    const screenshotName = sanitizeFilename(url) + '.png';
    const screenshotPath = join(outputDir, screenshotName);
    await page.screenshot({ path: screenshotPath, fullPage: true });
    result.screenshot = screenshotPath;

    // Check links on the page
    if (options.checkLinks) {
      result.linkResults = await checkPageLinks(
        page,
        url,
        options.maxLinks
      );
      const brokenLinks = result.linkResults.filter(
        (l) => l.status >= 400 || l.status === 0
      );
      if (brokenLinks.length > 0) {
        result.passed = false;
        result.failures.push(
          `${brokenLinks.length} broken link(s): ${brokenLinks.map((l) => `${l.href} (${l.status})`).join(', ')}`
        );
      }
    }
  } catch (err) {
    result.passed = false;
    result.failures.push(`Navigation error: ${err.message}`);
    result.loadTimeMs = Date.now() - startTime;

    // Try to take a screenshot even on error
    try {
      const screenshotName = sanitizeFilename(url) + '-error.png';
      const screenshotPath = join(outputDir, screenshotName);
      await page.screenshot({ path: screenshotPath });
      result.screenshot = screenshotPath;
    } catch {
      // Screenshot may fail if page didn't load at all
    }
  }

  // Collect errors from listeners
  result.consoleErrors = errors.consoleErrors;
  result.networkErrors = errors.networkErrors;

  if (result.consoleErrors.length > 0) {
    result.passed = false;
    result.failures.push(
      `${result.consoleErrors.length} console error(s)`
    );
  }

  return result;
}

/**
 * Check all <a> links on the current page for broken hrefs.
 * Uses HEAD requests to avoid downloading full pages.
 */
async function checkPageLinks(page, pageUrl, maxLinks) {
  const links = await page.evaluate((max) => {
    const anchors = document.querySelectorAll('a[href]');
    const results = [];
    const seen = new Set();

    for (const a of anchors) {
      if (results.length >= max) break;

      let href = a.href;
      // Skip non-HTTP links
      if (
        !href ||
        href.startsWith('javascript:') ||
        href.startsWith('mailto:') ||
        href.startsWith('tel:') ||
        href.startsWith('#') ||
        href.startsWith('data:')
      ) {
        continue;
      }

      // Deduplicate
      if (seen.has(href)) continue;
      seen.add(href);

      results.push({
        href,
        text: a.textContent.trim().substring(0, 60),
      });
    }

    return results;
  }, maxLinks);

  const results = [];

  for (const link of links) {
    try {
      const response = await page.request.head(link.href, {
        timeout: 10000,
        ignoreHTTPSErrors: true,
      });
      results.push({
        href: link.href,
        text: link.text,
        status: response.status(),
      });
    } catch {
      results.push({
        href: link.href,
        text: link.text,
        status: 0,
        error: 'Request failed',
      });
    }
  }

  return results;
}

/**
 * Convert a URL to a safe filename.
 */
function sanitizeFilename(url) {
  try {
    const parsed = new URL(url);
    const path = parsed.pathname.replace(/\//g, '_').replace(/^_/, '');
    return (parsed.hostname + '_' + (path || 'index')).replace(
      /[^a-zA-Z0-9_.-]/g,
      '_'
    );
  } catch {
    return url.replace(/[^a-zA-Z0-9_.-]/g, '_').substring(0, 100);
  }
}

// ============================================================================
// Flow Parsing
// ============================================================================

/**
 * Parse flow definitions from --flows JSON or generate default flows.
 * Returns array of {url, name} objects.
 */
function parseFlows(baseUrl, flowsJson) {
  if (!flowsJson) {
    // Default: just visit the base URL
    return [{ url: baseUrl, name: 'homepage' }];
  }

  let flows;
  try {
    flows = JSON.parse(flowsJson);
  } catch (err) {
    console.error(`ERROR: Invalid --flows JSON: ${err.message}`);
    process.exit(2);
  }

  if (!Array.isArray(flows)) {
    console.error('ERROR: --flows must be a JSON array');
    process.exit(2);
  }

  return flows.map((flow) => {
    if (typeof flow === 'string') {
      // Relative or absolute URL
      const url = flow.startsWith('http')
        ? flow
        : new URL(flow, baseUrl).toString();
      const name = flow.replace(/^\//, '') || 'homepage';
      return { url, name };
    }
    if (typeof flow === 'object' && flow.url) {
      const url = flow.url.startsWith('http')
        ? flow.url
        : new URL(flow.url, baseUrl).toString();
      return { url, name: flow.name || flow.url };
    }
    console.error(`ERROR: Invalid flow entry: ${JSON.stringify(flow)}`);
    process.exit(2);
  });
}

// ============================================================================
// Report Generation
// ============================================================================

function generateSummary(report) {
  const lines = [];
  lines.push('');
  lines.push('========================================');
  lines.push('  Browser QA Report');
  lines.push('========================================');
  lines.push('');
  lines.push(`Base URL:    ${report.baseUrl}`);
  lines.push(`Timestamp:   ${report.timestamp}`);
  lines.push(`Pages:       ${report.pages.length}`);
  lines.push(`Viewport:    ${report.viewport}`);
  lines.push('');

  const passed = report.pages.filter((p) => p.passed).length;
  const failed = report.pages.length - passed;
  const totalBrokenLinks = report.pages.reduce(
    (sum, p) => sum + p.linkResults.filter((l) => l.status >= 400 || l.status === 0).length,
    0
  );
  const totalConsoleErrors = report.pages.reduce(
    (sum, p) => sum + p.consoleErrors.length,
    0
  );

  lines.push(`  Pages passed:      ${passed}`);
  lines.push(`  Pages failed:      ${failed}`);
  lines.push(`  Broken links:      ${totalBrokenLinks}`);
  lines.push(`  Console errors:    ${totalConsoleErrors}`);
  lines.push('');

  for (const page of report.pages) {
    const status = page.passed ? 'PASS' : 'FAIL';
    lines.push(
      `  [${status}] ${page.url} (${page.status || 'N/A'}, ${page.loadTimeMs}ms)`
    );

    if (!page.passed) {
      for (const failure of page.failures) {
        lines.push(`         - ${failure}`);
      }
    }

    if (page.screenshot) {
      lines.push(`         Screenshot: ${page.screenshot}`);
    }
  }

  lines.push('');

  if (failed > 0) {
    lines.push('BROWSER QA: FAILED');
  } else {
    lines.push('BROWSER QA: PASSED');
  }
  lines.push('');

  return lines.join('\n');
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  const options = parseArgs();

  // Ensure output directory exists
  if (!existsSync(options.outputDir)) {
    mkdirSync(options.outputDir, { recursive: true });
  }

  // Parse flows
  const flows = parseFlows(options.baseUrl, options.flows);

  let browser;
  try {
    browser = await chromium.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage'],
    });

    const context = await browser.newContext({
      viewport: {
        width: options.viewportWidth,
        height: options.viewportHeight,
      },
      ignoreHTTPSErrors: true,
    });

    const page = await context.newPage();

    const report = {
      baseUrl: options.baseUrl,
      timestamp: new Date().toISOString(),
      viewport: `${options.viewportWidth}x${options.viewportHeight}`,
      outputDir: options.outputDir,
      pages: [],
      passed: true,
    };

    // Visit each flow
    for (const flow of flows) {
      const result = await visitPage(page, flow.url, options.outputDir, options);
      result.name = flow.name;
      report.pages.push(result);

      if (!result.passed) {
        report.passed = false;
      }
    }

    await browser.close().catch(() => {});

    // Write JSON report
    const reportPath = join(options.outputDir, 'qa-report.json');
    writeFileSync(reportPath, JSON.stringify(report, null, 2));

    // Output
    if (options.format === 'json') {
      console.log(JSON.stringify(report, null, 2));
    } else {
      console.log(generateSummary(report));
      console.log(`Full report: ${reportPath}`);
    }

    process.exit(report.passed ? 0 : 1);
  } catch (err) {
    console.error(`ERROR: ${err.message}`);
    if (browser) {
      await browser.close().catch(() => {});
    }
    process.exit(2);
  }
}

main();
