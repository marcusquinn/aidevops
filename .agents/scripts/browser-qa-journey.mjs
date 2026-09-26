#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// Authenticated browser QA runner. It accepts only declarative read-only steps.

import fs from 'node:fs/promises';
import { installNetworkGuard, runSteps } from './browser-qa-journey-steps.mjs';

const VIEWPORTS = {
  desktop: { width: 1440, height: 900 },
  mobile: { width: 375, height: 667 },
};

function fail(message) {
  throw new Error(message);
}

function exactUrl(value, name) {
  let url;
  try { url = new URL(value); } catch { fail(`${name} must be an absolute URL`); }
  if (!['http:', 'https:'].includes(url.protocol) || url.pathname !== '/' || url.search || url.hash) fail(`${name} must be an exact http(s) origin without path, query or fragment`);
  return url;
}

function validateConfig(config, environmentName) {
  if (config.version !== 1) fail('journey config version must be 1');
  const environment = config.environments?.[environmentName];
  if (!environment) fail(`unknown journey environment: ${environmentName}`);
  const origin = exactUrl(environment.origin, 'environment origin');
  const login = environment.login;
  const logout = environment.logout;
  for (const lifecycle of [login, logout]) {
    if (!lifecycle || typeof lifecycle.path !== 'string' || !['GET', 'POST'].includes(lifecycle.method)) fail('login and logout require exact path and GET or POST method');
    if (!lifecycle.path.startsWith('/') || lifecycle.path.includes('?')) fail('login/logout path must be an exact absolute path without query');
  }
  if (!login.usernameSelector || !login.passwordSelector || !login.submitSelector || typeof login.successPath !== 'string' || !login.successPath.startsWith('/')) fail('login requires selectors and an exact successPath');
  if (!environment.credentials?.usernameEnv || !environment.credentials?.passwordEnv) fail('credentials require usernameEnv and passwordEnv');
  const username = process.env[environment.credentials.usernameEnv];
  const password = process.env[environment.credentials.passwordEnv];
  if (!username || !password) fail('required journey credentials are unavailable');
  if (!Array.isArray(config.steps) || config.steps.length === 0 || config.steps.length > 50) fail('steps must contain 1-50 declarative entries');
  return { environment, origin, login, logout, username, password };
}

async function run(configPath, environmentName) {
  const config = JSON.parse(await fs.readFile(configPath, 'utf8'));
  const { environment, origin, login, logout, username, password } = validateConfig(config, environmentName);
  const playwrightImport = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
  const { chromium } = playwrightImport.chromium ? playwrightImport : playwrightImport.default;
  const launchOptions = { headless: true };
  if (process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE) launchOptions.executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
  const timeout = Number.isInteger(environment.timeoutMs) && environment.timeoutMs > 0 && environment.timeoutMs <= 60000 ? environment.timeoutMs : 30000;
  const viewports = Array.isArray(environment.viewports) ? environment.viewports : ['desktop', 'mobile'];
  if (!viewports.every(viewport => VIEWPORTS[viewport])) fail('viewports must be desktop and/or mobile');
  const report = { environment: environmentName, origin: origin.origin, passed: 0, failed: 0, blockedWrites: 0, viewports: [] };
  const browser = await chromium.launch(launchOptions);
  let cleanupError = null;
  let journeyError = null;
  try {
    for (const viewportName of viewports) {
      const context = await browser.newContext({ viewport: VIEWPORTS[viewportName] });
      const page = await context.newPage();
      const consoleErrors = [];
      page.on('console', message => { if (message.type() === 'error') consoleErrors.push(message.text().slice(0, 160)); });
      await installNetworkGuard(page, origin, login, logout, report);
      const result = { viewport: viewportName, steps: [], consoleErrors: 0 };
      try {
        await page.goto(new URL(login.path, origin).href, { waitUntil: 'domcontentloaded', timeout });
        await page.locator(login.usernameSelector).fill(username, { timeout });
        await page.locator(login.passwordSelector).fill(password, { timeout });
        await page.locator(login.submitSelector).click({ timeout });
        await page.waitForURL(url => url.origin === origin.origin && url.pathname === login.successPath, { timeout });
        journeyError = await runSteps(page, config.steps, origin, timeout, result, report);
      } finally {
        result.consoleErrors = consoleErrors.length;
        try {
          const logoutUrl = new URL(logout.path, origin).href;
          const response = await page.evaluate(async ({ url, method }) => {
            const result = await fetch(url, { method, credentials: 'same-origin' });
            return { ok: result.ok, status: result.status };
          }, { url: logoutUrl, method: logout.method });
          if (!response.ok) cleanupError = new Error(`logout returned ${response.status}`);
        } catch (error) { cleanupError = error; }
        await context.close();
      }
      report.viewports.push(result);
      if (journeyError) break;
    }
  } finally {
    await browser.close();
  }
  console.log(JSON.stringify(report));
  if (cleanupError) fail('logout cleanup could not be confirmed');
  if (journeyError) fail('journey assertion failed');
  if (report.blockedWrites) fail('non-allowlisted state-changing request was blocked');
}

const [configPath, environmentName] = process.argv.slice(2);
if (!configPath || !environmentName) fail('usage: browser-qa-journey.mjs CONFIG ENVIRONMENT');
run(configPath, environmentName).catch(error => { console.error(`Journey failed: ${error.message}`); process.exit(1); });
