// Browser discovery and WebSocket URL resolution.

import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { IS_WINDOWS } from './constants.mjs';

function normalizeBrowserUrl(raw) {
  if (!raw) return '';
  const trimmed = raw.endsWith('/') ? raw.slice(0, -1) : raw;
  return trimmed;
}

async function tryBrowserUrl(browserUrl) {
  const normalized = normalizeBrowserUrl(browserUrl);
  if (!normalized) return null;

  try {
    const versionUrl = new URL('/json/version', normalized);
    const response = await fetch(versionUrl);
    if (!response.ok) return null;
    const payload = await response.json();
    return payload.webSocketDebuggerUrl || null;
  } catch {
    return null;
  }
}

function buildPortFileCandidates(home) {
  const macBrowsers = [
    'Google/Chrome',
    'Google/Chrome Beta',
    'Google/Chrome for Testing',
    'Chromium',
    'BraveSoftware/Brave-Browser',
    'Microsoft Edge',
    'Vivaldi',
    'Ungoogled Chromium',
  ];
  const linuxBrowsers = [
    'google-chrome',
    'google-chrome-beta',
    'chromium',
    'vivaldi',
    'vivaldi-snapshot',
    'BraveSoftware/Brave-Browser',
    'microsoft-edge',
    'ungoogled-chromium',
  ];
  const flatpakBrowsers = [
    ['org.chromium.Chromium', 'chromium'],
    ['com.google.Chrome', 'google-chrome'],
    ['com.brave.Browser', 'BraveSoftware/Brave-Browser'],
    ['com.microsoft.Edge', 'microsoft-edge'],
    ['com.vivaldi.Vivaldi', 'vivaldi'],
  ];

  return [
    process.env.CDP_PORT_FILE || '',
    ...macBrowsers.flatMap((browserName) => [
      resolve(home, 'Library/Application Support', browserName, 'DevToolsActivePort'),
      resolve(home, 'Library/Application Support', browserName, 'Default/DevToolsActivePort'),
    ]),
    ...linuxBrowsers.flatMap((browserName) => [
      resolve(home, '.config', browserName, 'DevToolsActivePort'),
      resolve(home, '.config', browserName, 'Default/DevToolsActivePort'),
    ]),
    ...flatpakBrowsers.flatMap(([appId, browserName]) => [
      resolve(home, '.var/app', appId, 'config', browserName, 'DevToolsActivePort'),
      resolve(home, '.var/app', appId, 'config', browserName, 'Default/DevToolsActivePort'),
    ]),
    ...(IS_WINDOWS
      ? ['Google/Chrome', 'BraveSoftware/Brave-Browser', 'Microsoft/Edge', 'Vivaldi', 'Chromium'].flatMap((browserName) => {
          const localAppData = process.env.LOCALAPPDATA || resolve(home, 'AppData', 'Local');
          return [
            resolve(localAppData, browserName, 'User Data/DevToolsActivePort'),
            resolve(localAppData, browserName, 'User Data/Default/DevToolsActivePort'),
          ];
        })
      : []),
  ].filter(Boolean);
}

// Profiles started by `chromium-debug-use-helper.sh launch` use a free port
// recorded in their own DevToolsActivePort file. Only a live endpoint counts, so
// stale files left by a closed browser are skipped.
async function findLaunchedProfileWsUrl(home) {
  const base = process.env.AIDEVOPS_BROWSER_PROFILE_DIR
    || resolve(home, '.aidevops/.agent-workspace/browser-profiles');
  let entries = [];
  try {
    entries = readdirSync(base, { withFileTypes: true }).filter((entry) => entry.isDirectory());
  } catch {
    return null;
  }
  for (const entry of entries) {
    const portFile = resolve(base, entry.name, 'DevToolsActivePort');
    if (!existsSync(portFile)) continue;
    const port = readFileSync(portFile, 'utf8').split('\n')[0].trim();
    if (!/^\d+$/.test(port)) continue;
    const wsUrl = await tryBrowserUrl(`http://127.0.0.1:${port}`);
    if (wsUrl) return wsUrl;
  }
  return null;
}

export async function getWsUrl() {
  const explicitWsEndpoint = process.env.CHROMIUM_DEBUG_USE_WS_ENDPOINT || process.env.CDP_WS_ENDPOINT || '';
  if (explicitWsEndpoint) return explicitWsEndpoint;

  const browserUrlCandidates = [
    process.env.CHROMIUM_DEBUG_USE_BROWSER_URL || '',
    process.env.CDP_BROWSER_URL || '',
    'http://127.0.0.1:9222',
  ].filter(Boolean);

  for (const browserUrl of browserUrlCandidates) {
    const wsUrl = await tryBrowserUrl(browserUrl);
    if (wsUrl) return wsUrl;
  }

  const home = homedir();
  const launchedWsUrl = await findLaunchedProfileWsUrl(home);
  if (launchedWsUrl) return launchedWsUrl;

  const candidates = buildPortFileCandidates(home);

  const portFile = candidates.find((candidate) => existsSync(candidate));
  if (!portFile) {
    throw new Error(
      'No Chromium debugging endpoint found. Run "chromium-debug-use-helper.sh launch" for a dedicated profile, or set CHROMIUM_DEBUG_USE_BROWSER_URL.'
    );
  }

  const lines = readFileSync(portFile, 'utf8').trim().split('\n');
  if (lines.length < 2 || !lines[0] || !lines[1]) {
    throw new Error(`Invalid DevToolsActivePort file: ${portFile}`);
  }

  const host = process.env.CDP_HOST || '127.0.0.1';
  return `ws://${host}:${lines[0]}${lines[1]}`;
}
