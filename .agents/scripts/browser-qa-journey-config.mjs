// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// Versioned, declarative journey schema validation for browser-qa-journey.mjs.
// Everything here runs before any browser launch or authentication attempt.

export const SCHEMA_VERSION = 1;

export const VIEWPORTS = {
  desktop: { width: 1440, height: 900 },
  mobile: { width: 375, height: 667 },
};

const MAX_STEPS = 50;
const MAX_TEXT_LENGTH = 500;
const LAYOUT_EDGES = new Set(['top', 'bottom', 'left', 'right', 'width', 'height', 'centerX', 'centerY']);
const ACTION_TIMEOUT = { fallback: 15000, max: 60000, label: 'timeoutMs' };
const RUN_TIMEOUT = { fallback: 180000, max: 600000, label: 'runTimeoutMs' };
const AUTH_METHODS = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE']);
// Sign-in must be a body-carrying write so it takes the no-redirect sign-in path
// and credentials never travel in a URL query string.
const LOGIN_METHODS = new Set(['POST', 'PUT', 'PATCH']);
const ENV_NAME_PATTERN = /^[A-Z_][A-Z0-9_]*$/;

// Declarative step types and their required fields. No step executes config-supplied code.
export const STEP_FIELDS = {
  navigate: { path: 'navigationPath' },
  click: { selector: 'text' },
  visible: { selector: 'text' },
  count: { selector: 'text', equals: 'count' },
  text: { selector: 'text', includes: 'text' },
  attribute: { selector: 'text', name: 'text', equals: 'text' },
  layout: { selector: 'text', compare: 'text', match: 'layoutMatch' },
  'no-horizontal-overflow': {},
};

function fail(message) {
  throw new Error(message);
}

function isText(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= MAX_TEXT_LENGTH;
}

// Absolute same-origin path; rejects protocol-relative (//host) and backslash tricks.
function isNavigationPath(value) {
  return isText(value) && /^\/(?![/\\])[^\\\s]*$/.test(value);
}

// Exact endpoint path: no query or fragment, so allowlists cannot be widened.
function isExactPath(value) {
  return isNavigationPath(value) && !/[?#]/.test(value);
}

const FIELD_CHECKS = {
  text: isText,
  count: (value) => Number.isInteger(value) && value >= 0,
  navigationPath: isNavigationPath,
  exactPath: isExactPath,
  layoutMatch: (value) => Array.isArray(value) && value.length > 0 && value.every((edge) => LAYOUT_EDGES.has(edge)) && new Set(value).size === value.length,
  tolerancePx: (value) => Number.isInteger(value) && value >= 0 && value <= 8,
};

function requireField(value, check, label) {
  if (!FIELD_CHECKS[check](value)) fail(`${label} is missing or invalid`);
}

function parseOrigin(value) {
  let url = null;
  try {
    url = new URL(value);
  } catch {
    url = null;
  }
  const exact = url !== null && ['http:', 'https:'].includes(url.protocol) && url.href === `${url.origin}/`;
  if (!exact) fail('environment origin must be an exact http(s) origin without path, query, fragment or credentials');
  return url.origin;
}

function validateEndpoint(endpoint, label, methods = AUTH_METHODS) {
  if (endpoint === null || typeof endpoint !== 'object') fail(`${label} endpoint is required`);
  requireField(endpoint.path, 'exactPath', `${label}.path`);
  if (!methods.has(endpoint.method)) fail(`${label}.method must be one of ${[...methods].join(', ')}`);
  return { path: endpoint.path, method: endpoint.method };
}

function validateLogin(login) {
  const endpoint = validateEndpoint(login, 'login', LOGIN_METHODS);
  const pagePath = login.pagePath ?? login.path;
  requireField(pagePath, 'exactPath', 'login.pagePath');
  requireField(login.successPath, 'exactPath', 'login.successPath');
  for (const key of ['usernameSelector', 'passwordSelector', 'submitSelector']) {
    requireField(login[key], 'text', `login.${key}`);
  }
  return {
    ...endpoint,
    pagePath,
    successPath: login.successPath,
    usernameSelector: login.usernameSelector,
    passwordSelector: login.passwordSelector,
    submitSelector: login.submitSelector,
  };
}

function boundedMs(value, limits) {
  if (value === undefined) return limits.fallback;
  if (!Number.isInteger(value) || value < 1000 || value > limits.max) {
    fail(`${limits.label} must be an integer between 1000 and ${limits.max}`);
  }
  return value;
}

const VIEWPORT_NAME = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;

function inRange(value, min, max) {
  return Number.isInteger(value) && value >= min && value <= max;
}

function isCustomViewport(viewport) {
  return viewport !== null && typeof viewport === 'object' && !Array.isArray(viewport)
    && VIEWPORT_NAME.test(String(viewport.name))
    && inRange(viewport.width, 320, 3840) && inRange(viewport.height, 320, 2160);
}

function viewportName(viewport) {
  if (typeof viewport === 'string' && Object.hasOwn(VIEWPORTS, viewport)) return viewport;
  if (isCustomViewport(viewport)) return viewport.name;
  return fail('viewports require desktop/mobile or a custom name, integer width 320-3840 and height 320-2160');
}

function validateViewports(value) {
  const viewports = value ?? Object.keys(VIEWPORTS);
  if (!Array.isArray(viewports) || !inRange(viewports.length, 1, 8)) fail('viewports must contain 1-8 named or custom entries');
  const names = viewports.map(viewportName);
  if (new Set(names).size !== names.length) fail('viewports require unique names');
  return viewports;
}

function validateStep(step, index) {
  const label = `step ${index + 1}`;
  if (step === null || typeof step !== 'object' || !Object.hasOwn(STEP_FIELDS, String(step.type))) {
    fail(`${label}: unsupported journey step type`);
  }
  for (const [key, check] of Object.entries(STEP_FIELDS[step.type])) requireField(step[key], check, `${label} ${key}`);
  if (step.name !== undefined) requireField(step.name, 'text', `${label} name`);
  if (step.type === 'layout' && step.tolerancePx !== undefined) requireField(step.tolerancePx, 'tolerancePx', `${label} tolerancePx`);
}

function validateSteps(steps) {
  if (!Array.isArray(steps) || steps.length === 0 || steps.length > MAX_STEPS) {
    fail(`steps must contain 1-${MAX_STEPS} declarative entries`);
  }
  steps.forEach(validateStep);
  return steps;
}

// Reads credential values from named environment variables, then removes them from
// this process environment so the launched browser never inherits them.
function readCredentials(credentials) {
  const names = [credentials?.usernameEnv, credentials?.passwordEnv];
  if (!names.every((name) => typeof name === 'string' && ENV_NAME_PATTERN.test(name))) {
    fail('credentials require usernameEnv and passwordEnv variable names');
  }
  const [username, password] = names.map((name) => process.env[name] || '');
  for (const name of names) delete process.env[name];
  if (!username || !password) fail('required journey credentials are unavailable');
  return { username, password };
}

export function validateJourney(config, environmentName) {
  if (config?.version !== SCHEMA_VERSION) fail(`journey config version must be ${SCHEMA_VERSION}`);
  const environments = config.environments ?? {};
  if (typeof environments !== 'object' || !Object.hasOwn(environments, environmentName)) {
    fail(`unknown journey environment: ${environmentName}`);
  }
  const environment = environments[environmentName] ?? {};
  const journey = {
    environmentName,
    origin: parseOrigin(environment.origin),
    login: validateLogin(environment.login ?? {}),
    logout: validateEndpoint(environment.logout, 'logout'),
    viewports: validateViewports(environment.viewports),
    actionTimeoutMs: boundedMs(environment.timeoutMs, ACTION_TIMEOUT),
    runTimeoutMs: boundedMs(environment.runTimeoutMs, RUN_TIMEOUT),
    steps: validateSteps(config.steps),
  };
  return { ...journey, credentials: readCredentials(environment.credentials) };
}
