// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// Network and navigation guard for authenticated read-only journeys.
// Policy: only the exact-origin login endpoint may change state, and only during the
// sign-in phase. Every other non-safe request, off-origin page navigation or
// credential-bearing third-party request is aborted and counted as a violation.
// Sign-out is issued by the runner itself (browser-qa-journey.mjs), not by page code.

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);
const VIOLATION_KEYS = ['blockedWrites', 'blockedThirdParty', 'offOriginNavigations', 'guardErrors'];

export function createGuard(journey) {
  return {
    origin: journey.origin,
    login: journey.login,
    phase: 'setup',
    counts: Object.fromEntries(VIOLATION_KEYS.map((key) => [key, 0])),
  };
}

export function guardViolations(guard) {
  return VIOLATION_KEYS.reduce((total, key) => total + guard.counts[key], 0);
}

export function assertGuardClean(guard) {
  const violated = VIOLATION_KEYS.filter((key) => guard.counts[key] > 0);
  if (violated.length > 0) throw new Error(`guard blocked: ${violated.join(', ')}`);
}

function originOf(value) {
  try {
    return new URL(value).origin;
  } catch {
    return 'null';
  }
}

function isMainFrameNavigation(request) {
  try {
    return request.isNavigationRequest() && request.frame().parentFrame() === null;
  } catch {
    return false;
  }
}

function isSignInRequest(guard, request) {
  const url = new URL(request.url());
  const matchesEndpoint = url.pathname === guard.login.path && request.method() === guard.login.method;
  return guard.phase === 'login' && matchesEndpoint;
}

async function carriesCredentials(request) {
  const headers = await request.allHeaders();
  return Boolean(headers.cookie || headers.authorization);
}

function classifySameOrigin(guard, request) {
  if (SAFE_METHODS.has(request.method())) return null;
  return isSignInRequest(guard, request) ? 'signIn' : 'blockedWrites';
}

async function classifyOffOrigin(request) {
  if (isMainFrameNavigation(request)) return 'offOriginNavigations';
  if (!SAFE_METHODS.has(request.method())) return 'blockedWrites';
  return (await carriesCredentials(request)) ? 'blockedThirdParty' : null;
}

async function classify(guard, request) {
  if (originOf(request.url()) === guard.origin) return classifySameOrigin(guard, request);
  return classifyOffOrigin(request);
}

// Sign-in submissions are fetched without following redirects so an off-origin
// redirect (including a body-replaying 307/308) never leaves the allowed origin.
async function forwardSignIn(guard, route) {
  const response = await route.fetch({ maxRedirects: 0 });
  const location = response.headers().location;
  if (location && originOf(new URL(location, route.request().url()).href) !== guard.origin) {
    guard.counts.offOriginNavigations += 1;
    return route.abort('blockedbyclient');
  }
  return route.fulfill({ response });
}

async function applyVerdict(guard, route) {
  const verdict = await classify(guard, route.request());
  if (verdict === 'signIn') return forwardSignIn(guard, route);
  if (verdict === null) return route.continue();
  guard.counts[verdict] += 1;
  return route.abort('blockedbyclient');
}

async function handleRoute(guard, route) {
  try {
    await applyVerdict(guard, route);
  } catch {
    guard.counts.guardErrors += 1;
    await route.abort('blockedbyclient').catch(() => undefined);
  }
}

// Route handlers only see the first URL of a redirect chain; committed main-frame
// navigations catch any later hop that lands off-origin.
function watchNavigations(guard, page) {
  page.on('framenavigated', (frame) => {
    const url = frame.url();
    const isWebUrl = /^https?:/.test(url);
    if (frame === page.mainFrame() && isWebUrl && originOf(url) !== guard.origin) {
      guard.counts.offOriginNavigations += 1;
    }
  });
}

// WebSockets bypass context.route. Never connect them to the server so no frame can
// write to the app; the page sees a socket that closes. Reported, not a failure,
// because read-only pages commonly open sockets for live updates.
function blockWebSocket(guard, webSocket) {
  guard.webSocketsBlocked += 1;
  webSocket.close({ code: 1008, reason: 'blocked by read-only journey' }).catch(() => undefined);
}

export async function installGuard(context, guard) {
  guard.webSocketsBlocked = 0;
  context.on('page', (page) => watchNavigations(guard, page));
  await context.routeWebSocket(/.*/, (webSocket) => blockWebSocket(guard, webSocket));
  await context.route('**/*', (route) => handleRoute(guard, route));
}
