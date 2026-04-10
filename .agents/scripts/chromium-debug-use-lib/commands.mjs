// CDP command implementations — each function executes a single browser action.

import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { CACHE_DIR, MIN_TARGET_PREFIX_LEN, NAVIGATION_TIMEOUT_MS, sleep } from './constants.mjs';
export { snapshotStr } from './accessibility.mjs';

export async function getPages(cdp) {
  const { targetInfos } = await cdp.send('Target.getTargets');
  return targetInfos.filter((targetInfo) => targetInfo.type === 'page' && !targetInfo.url.startsWith('chrome://'));
}

export function getDisplayPrefixLength(targetIds) {
  if (targetIds.length === 0) return MIN_TARGET_PREFIX_LEN;

  const maxLength = Math.max(...targetIds.map((targetId) => targetId.length));
  for (let length = MIN_TARGET_PREFIX_LEN; length <= maxLength; length += 1) {
    const prefixes = new Set(targetIds.map((targetId) => targetId.slice(0, length).toUpperCase()));
    if (prefixes.size === targetIds.length) return length;
  }

  return maxLength;
}

export function formatPageList(pages) {
  const prefixLength = getDisplayPrefixLength(pages.map((page) => page.targetId));
  return pages
    .map((page) => {
      const id = page.targetId.slice(0, prefixLength).padEnd(prefixLength);
      const title = page.title.substring(0, 54).padEnd(54);
      return `${id}  ${title}  ${page.url}`;
    })
    .join('\n');
}

export async function evalStr(cdp, sessionId, expression) {
  await cdp.send('Runtime.enable', {}, sessionId);
  const result = await cdp.send(
    'Runtime.evaluate',
    { expression, returnByValue: true, awaitPromise: true },
    sessionId
  );

  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.text || result.exceptionDetails.exception?.description || 'Runtime evaluation failed');
  }

  const value = result.result.value;
  if (typeof value === 'object') return JSON.stringify(value, null, 2);
  return String(value ?? '');
}

export async function shotStr(cdp, sessionId, filePath, targetId) {
  let dpr = 1;
  try {
    const raw = await evalStr(cdp, sessionId, 'window.devicePixelRatio');
    const parsed = Number.parseFloat(raw);
    if (!Number.isNaN(parsed) && parsed > 0) dpr = parsed;
  } catch {
    // ignored
  }

  const { data } = await cdp.send('Page.captureScreenshot', { format: 'png' }, sessionId);
  const outputPath = filePath || resolve(CACHE_DIR, `screenshot-${(targetId || 'unknown').slice(0, 8)}.png`);
  writeFileSync(outputPath, Buffer.from(data, 'base64'));

  const lines = [outputPath];
  lines.push(`Screenshot saved. Device pixel ratio (DPR): ${dpr}`);
  lines.push('Coordinate mapping:');
  lines.push(`  Screenshot pixels -> CSS pixels (for CDP Input events): divide by ${dpr}`);
  lines.push(`  Example: screenshot (${Math.round(100 * dpr)}, ${Math.round(200 * dpr)}) -> CSS (100, 200)`);
  return lines.join('\n');
}

export async function htmlStr(cdp, sessionId, selector) {
  const expression = selector
    ? `document.querySelector(${JSON.stringify(selector)})?.outerHTML || 'Element not found'`
    : 'document.documentElement.outerHTML';
  return evalStr(cdp, sessionId, expression);
}

async function waitForDocumentReady(cdp, sessionId, timeoutMs = NAVIGATION_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs;
  let lastState = '';
  let lastError;

  while (Date.now() < deadline) {
    try {
      const state = await evalStr(cdp, sessionId, 'document.readyState');
      lastState = state;
      if (state === 'complete') return;
    } catch (error) {
      lastError = error;
    }
    await sleep(200);
  }

  if (lastState) throw new Error(`Timed out waiting for navigation to finish (last readyState: ${lastState})`);
  if (lastError) throw new Error(`Timed out waiting for navigation to finish (${lastError.message})`);
  throw new Error('Timed out waiting for navigation to finish');
}

export async function navStr(cdp, sessionId, url) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      throw new Error(`Only http/https URLs allowed, got: ${url}`);
    }
  } catch (error) {
    if (error.message.startsWith('Only')) throw error;
    throw new Error(`Invalid URL: ${url}`);
  }

  await cdp.send('Page.enable', {}, sessionId);
  const loadEvent = cdp.waitForEvent('Page.loadEventFired', NAVIGATION_TIMEOUT_MS);
  const result = await cdp.send('Page.navigate', { url }, sessionId);

  if (result.errorText) {
    loadEvent.cancel();
    throw new Error(result.errorText);
  }

  if (result.loaderId) {
    await loadEvent.promise;
  } else {
    loadEvent.cancel();
  }

  await waitForDocumentReady(cdp, sessionId, 5000);
  return `Navigated to ${url}`;
}

export async function clickStr(cdp, sessionId, selector) {
  if (!selector) throw new Error('CSS selector required');

  const expression = `
    (() => {
      const el = document.querySelector(${JSON.stringify(selector)});
      if (!el) return { ok: false, error: 'Element not found: ' + ${JSON.stringify(selector)} };
      el.scrollIntoView({ block: 'center' });
      el.click();
      return { ok: true, tag: el.tagName, text: (el.textContent || '').trim().substring(0, 80) };
    })()
  `;

  const raw = await evalStr(cdp, sessionId, expression);
  const result = JSON.parse(raw);
  if (!result.ok) throw new Error(result.error);
  return `Clicked <${result.tag}> "${result.text}"`;
}

export async function clickXyStr(cdp, sessionId, x, y) {
  const cssX = Number.parseFloat(x);
  const cssY = Number.parseFloat(y);
  if (Number.isNaN(cssX) || Number.isNaN(cssY)) {
    throw new Error('x and y must be numbers (CSS pixels)');
  }

  const base = { x: cssX, y: cssY, button: 'left', clickCount: 1, modifiers: 0 };
  await cdp.send('Input.dispatchMouseEvent', { ...base, type: 'mouseMoved' }, sessionId);
  await cdp.send('Input.dispatchMouseEvent', { ...base, type: 'mousePressed' }, sessionId);
  await sleep(50);
  await cdp.send('Input.dispatchMouseEvent', { ...base, type: 'mouseReleased' }, sessionId);
  return `Clicked at CSS (${cssX}, ${cssY})`;
}

export async function typeStr(cdp, sessionId, text) {
  if (text == null || text === '') throw new Error('text required');
  await cdp.send('Input.insertText', { text }, sessionId);
  return `Typed ${text.length} characters`;
}

export async function loadAllStr(cdp, sessionId, selector, intervalMs = 1500) {
  if (!selector) throw new Error('CSS selector required');

  let clicks = 0;
  const deadline = Date.now() + 5 * 60 * 1000;
  while (Date.now() < deadline) {
    const exists = await evalStr(cdp, sessionId, `!!document.querySelector(${JSON.stringify(selector)})`);
    if (exists !== 'true') break;

    const clicked = await evalStr(
      cdp,
      sessionId,
      `(() => {
        const el = document.querySelector(${JSON.stringify(selector)});
        if (!el) return false;
        el.scrollIntoView({ block: 'center' });
        el.click();
        return true;
      })()`
    );

    if (clicked !== 'true') break;
    clicks += 1;
    await sleep(intervalMs);
  }

  return `Clicked "${selector}" ${clicks} time(s) until it disappeared`;
}

export async function evalRawStr(cdp, sessionId, method, paramsJson) {
  if (!method) throw new Error('CDP method required (e.g. "DOM.getDocument")');

  let params = {};
  if (paramsJson) {
    try {
      params = JSON.parse(paramsJson);
    } catch {
      throw new Error(`Invalid JSON params: ${paramsJson}`);
    }
  }

  const result = await cdp.send(method, params, sessionId);
  return JSON.stringify(result, null, 2);
}

export async function browserVersionStr(cdp) {
  const version = await cdp.send('Browser.getVersion');
  return JSON.stringify(
    {
      product: version.product,
      protocolVersion: version.protocolVersion,
      revision: version.revision,
      userAgent: version.userAgent,
      jsVersion: version.jsVersion,
    },
    null,
    2
  );
}
