// Browser discovery and WebSocket URL resolution.

import { existsSync, readFileSync } from 'node:fs';
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
  const candidates = buildPortFileCandidates(home);

  const portFile = candidates.find((candidate) => existsSync(candidate));
  if (!portFile) {
    throw new Error(
      'No Chromium debugging endpoint found. Launch a browser with --remote-debugging-port=9222 or set CHROMIUM_DEBUG_USE_BROWSER_URL.'
    );
  }

  const lines = readFileSync(portFile, 'utf8').trim().split('\n');
  if (lines.length < 2 || !lines[0] || !lines[1]) {
    throw new Error(`Invalid DevToolsActivePort file: ${portFile}`);
  }

  const host = process.env.CDP_HOST || '127.0.0.1';
  return `ws://${host}:${lines[0]}${lines[1]}`;
}
