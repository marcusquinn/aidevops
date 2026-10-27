#!/usr/bin/env node

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { spawnSync } from 'node:child_process';
import { accessSync, constants, mkdirSync, readFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { basename, delimiter, dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const MODULE_ENV = 'AIDEVOPS_PLAYWRIGHT_MODULE';
const NPM_FALLBACK_ENV = 'AIDEVOPS_PLAYWRIGHT_NPX_FALLBACK';
const RUNTIME_DIR_ENV = 'AIDEVOPS_PLAYWRIGHT_RUNTIME_DIR';
const VERSION_ENV = 'AIDEVOPS_PLAYWRIGHT_VERSION';
// Reviewed pin for the framework-owned runtime. Bump deliberately.
const PINNED_VERSION = '1.63.0';
// Optional accessibility package installed beside the owned Playwright with
// `install --with-axe` (GH#35759). Reviewed pin; bump deliberately.
const AXE_PACKAGE = '@axe-core/playwright';
const AXE_PINNED_VERSION = '4.14.0';
const WITH_AXE_FLAG = '--with-axe';
const INSTALL_COMMAND = 'node ~/.aidevops/agents/scripts/playwright-runtime.mjs install';
const INSTALL_HINT =
  `Install the framework-owned runtime with \`${INSTALL_COMMAND}\`, ` +
  `or set ${MODULE_ENV} to an existing Playwright package. Do not install ad-hoc duplicate copies.`;

// Framework-owned install prefix (GH#32589). `npx --no-install` only reuses a
// cache entry matching the registry's current version, so npx caches go stale
// after every upstream release; this prefix is resolved deterministically.
export function playwrightRuntimeDir() {
  return process.env[RUNTIME_DIR_ENV]?.trim() || join(homedir(), '.aidevops', 'runtimes', 'playwright');
}

export function playwrightRuntimeVersion() {
  return process.env[VERSION_ENV]?.trim() || PINNED_VERSION;
}

function installedPackageVersion(runtimeDir, packageName) {
  try {
    const pkg = JSON.parse(readFileSync(join(runtimeDir, 'node_modules', ...packageName.split('/'), 'package.json'), 'utf8'));
    return pkg.version || null;
  } catch {
    return null;
  }
}

function installedRuntimeVersion(runtimeDir) {
  return installedPackageVersion(runtimeDir, 'playwright');
}

function runInherited(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: 'inherit', ...options });
  if (result.error) throw result.error;
  return result.status === 0;
}

// Exact pins for the owned prefix: Playwright always, axe only when requested.
function runtimePackagePins(version, withAxe) {
  const pins = [{ name: 'playwright', version }];
  if (withAxe) pins.push({ name: AXE_PACKAGE, version: AXE_PINNED_VERSION });
  return pins;
}

// Check each pin separately so an already-current Playwright prefix still
// receives axe when it is requested. All specs go in one exact-save install.
function ensureRuntimePackages(runtimeDir, pins) {
  const isCurrent = (pin) => installedPackageVersion(runtimeDir, pin.name) === pin.version;
  if (pins.every(isCurrent)) return;
  // Windows .cmd shims need a shell on current Node; quote the only free-form argument.
  const isWindows = process.platform === 'win32';
  const installed = runInherited(
    isWindows ? 'npm.cmd' : 'npm',
    [
      'install', '--prefix', isWindows ? `"${runtimeDir}"` : runtimeDir,
      '--ignore-scripts', '--no-audit', '--no-fund', '--save-exact',
      ...pins.map((pin) => `${pin.name}@${pin.version}`),
    ],
    { shell: isWindows },
  );
  const missing = pins.find((pin) => !installed || !isCurrent(pin));
  if (missing) throw new Error(`Failed to install ${missing.name}@${missing.version} into ${runtimeDir}`);
}

export function installPlaywrightRuntime(browsers = ['chromium'], { withAxe = false } = {}) {
  const runtimeDir = playwrightRuntimeDir();
  const version = playwrightRuntimeVersion();
  mkdirSync(runtimeDir, { recursive: true });
  ensureRuntimePackages(runtimeDir, runtimePackagePins(version, withAxe));

  // Use the owned CLI so browser revisions match the resolved package.
  const cli = join(runtimeDir, 'node_modules', 'playwright', 'cli.js');
  if (!runInherited(process.execPath, [cli, 'install', ...browsers])) {
    const retryArgs = [...(withAxe ? [WITH_AXE_FLAG] : []), ...browsers].join(' ');
    throw new Error(`Playwright browser installation failed; retry: ${INSTALL_COMMAND} ${retryArgs}`);
  }
  const result = { runtimeDir, version, browsers };
  if (withAxe) result.axeVersion = AXE_PINNED_VERSION;
  return result;
}

function findExecutable(candidate) {
  if (!candidate) return null;
  const hasPathSeparator = candidate.includes('/') || candidate.includes('\\');
  const locations = hasPathSeparator
    ? [candidate]
    : (process.env.PATH || '').split(delimiter).filter(Boolean).map((entry) => join(entry, candidate));

  for (const location of locations) {
    try {
      accessSync(location, constants.X_OK);
      return location;
    } catch {
      // Keep searching.
    }
  }
  return null;
}

function braveExecutableCandidates() {
  if (process.platform === 'darwin') {
    return ['/Applications/Brave Browser.app/Contents/MacOS/Brave Browser', 'brave-browser', 'brave'];
  }
  if (process.platform === 'win32') {
    return [
      join(process.env.PROGRAMFILES || 'C:\\Program Files', 'BraveSoftware', 'Brave-Browser', 'Application', 'brave.exe'),
      join(process.env['PROGRAMFILES(X86)'] || 'C:\\Program Files (x86)', 'BraveSoftware', 'Brave-Browser', 'Application', 'brave.exe'),
      'brave.exe',
    ];
  }
  return ['brave-browser', 'brave', '/snap/bin/brave'];
}

export function resolvePlaywrightBrowserExecutable(runtime) {
  const configuredExecutable = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE?.trim();
  if (configuredExecutable) return findExecutable(configuredExecutable) || configuredExecutable;

  if (process.env.AIDEVOPS_PLAYWRIGHT_BROWSER !== 'chromium') {
    for (const candidate of braveExecutableCandidates()) {
      const executable = findExecutable(candidate);
      if (executable) return executable;
    }
  }

  try {
    return runtime.chromium.executablePath() || null;
  } catch {
    return null;
  }
}

function moduleUrl(value) {
  if (!value) return null;
  if (value.startsWith('file:')) return value;
  return pathToFileURL(realpathSync(value)).href;
}

function resolveFromAnchor(anchor) {
  try {
    const require = createRequire(pathToFileURL(anchor));
    return pathToFileURL(realpathSync(require.resolve('playwright'))).href;
  } catch {
    return null;
  }
}

function resolutionAnchors() {
  const anchors = [
    fileURLToPath(import.meta.url),
    join(process.cwd(), '.aidevops-playwright-resolver.cjs'),
    join(playwrightRuntimeDir(), 'package.json'),
  ];
  for (const entry of (process.env.PATH || '').split(delimiter)) {
    if (!entry || dirname(entry) === entry) continue;
    if (basename(entry) === '.bin' && basename(dirname(entry)) === 'node_modules') {
      anchors.push(join(dirname(entry), '.aidevops-playwright-resolver.cjs'));
    }
  }
  return [...new Set(anchors)];
}

async function validateModule(resolved) {
  if (!resolved) return null;
  try {
    const imported = await import(resolved);
    const runtime = imported.chromium ? imported : imported.default;
    return runtime?.chromium ? resolved : null;
  } catch {
    return null;
  }
}

async function resolveWithoutNpx() {
  const explicit = process.env[MODULE_ENV];
  if (explicit) {
    const validated = await validateModule(moduleUrl(explicit));
    if (validated) return validated;
  }

  for (const anchor of resolutionAnchors()) {
    const validated = await validateModule(resolveFromAnchor(anchor));
    if (validated) return validated;
  }
  return null;
}

function resolveViaNpx() {
  if (process.env[NPM_FALLBACK_ENV] === '0') return null;
  const npxCommand = process.platform === 'win32' ? 'npx.cmd' : 'npx';
  const result = spawnSync(
    npxCommand,
    ['--no-install', '--package', 'playwright', 'node', fileURLToPath(import.meta.url), 'resolve-path'],
    {
      encoding: 'utf8',
      env: { ...process.env, [NPM_FALLBACK_ENV]: '0' },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  if (result.status !== 0) return null;
  const resolved = result.stdout.trim().split('\n').at(-1);
  return resolved || null;
}

export async function resolvePlaywrightModule({ allowNpx = true } = {}) {
  const local = await resolveWithoutNpx();
  if (local) return local;

  if (allowNpx) {
    const npxResolved = resolveViaNpx();
    const validated = await validateModule(npxResolved);
    if (validated) return validated;
  }

  throw new Error(
    `Playwright Node package is not importable. CLI availability alone is insufficient. ${INSTALL_HINT}`,
  );
}

export async function loadPlaywright(resolvedModule = null) {
  const resolved = resolvedModule || await resolvePlaywrightModule();
  const imported = await import(resolved);
  return imported.chromium ? imported : imported.default;
}

export async function playwrightStatus() {
  let resolved;
  let runtime;
  try {
    resolved = await resolvePlaywrightModule();
    runtime = await loadPlaywright(resolved);
  } catch (error) {
    return {
      packageImportable: false,
      module: null,
      browserBinaryAvailable: false,
      browserExecutable: null,
      error: error.message,
    };
  }

  const browserExecutable = resolvePlaywrightBrowserExecutable(runtime);
  const verifiedExecutable = findExecutable(browserExecutable);
  return {
    packageImportable: true,
    module: resolved,
    browserBinaryAvailable: Boolean(verifiedExecutable),
    browserExecutable: verifiedExecutable || browserExecutable || null,
  };
}

async function ownedChromiumExecutable(runtimeDir) {
  const ownedModule = await validateModule(resolveFromAnchor(join(runtimeDir, 'package.json')));
  if (!ownedModule) return null;
  try {
    return findExecutable((await loadPlaywright(ownedModule)).chromium.executablePath());
  } catch {
    return null;
  }
}

// Axe is optional: report whether it imports from the owned prefix, i.e.
// beside the owned Playwright, without making it part of runtime readiness.
async function ownedAxeStatus(runtimeDir) {
  const installedVersion = installedPackageVersion(runtimeDir, AXE_PACKAGE);
  let importable = false;
  if (installedVersion) {
    try {
      const require = createRequire(pathToFileURL(join(runtimeDir, 'package.json')));
      await import(pathToFileURL(realpathSync(require.resolve(AXE_PACKAGE))).href);
      importable = true;
    } catch {
      importable = false;
    }
  }
  return {
    package: AXE_PACKAGE,
    version: AXE_PINNED_VERSION,
    installedVersion,
    importable,
    ready: importable && installedVersion === AXE_PINNED_VERSION,
  };
}

// Setup idempotence: the owned prefix holds the pinned version and its Chromium.
export async function ownedRuntimeStatus() {
  const runtimeDir = playwrightRuntimeDir();
  const version = playwrightRuntimeVersion();
  const installedVersion = installedRuntimeVersion(runtimeDir);
  const chromiumExecutable = installedVersion === version ? await ownedChromiumExecutable(runtimeDir) : null;
  const axe = await ownedAxeStatus(runtimeDir);
  return { runtimeDir, version, installedVersion, chromiumExecutable, ready: Boolean(chromiumExecutable), axe };
}

function parseInstallArgs(args) {
  const withAxe = args.includes(WITH_AXE_FLAG);
  const browsers = args.filter((arg) => arg !== WITH_AXE_FLAG);
  return { withAxe, browsers: browsers.length > 0 ? browsers : ['chromium'] };
}

function writeLine(value) {
  process.stdout.write(`${typeof value === 'string' ? value : JSON.stringify(value)}\n`);
}

async function usableStatus() {
  const status = await playwrightStatus();
  if (!status.packageImportable) throw new Error(status.error);
  if (!status.browserBinaryAvailable) {
    throw new Error(
      `Playwright is importable, but no usable standalone browser was found. Install Brave, or run: ${INSTALL_COMMAND}`,
    );
  }
  return status;
}

const COMMANDS = {
  resolve: async () => writeLine(await resolvePlaywrightModule({ allowNpx: true })),
  'resolve-path': async () => writeLine(await resolvePlaywrightModule({ allowNpx: false })),
  status: async () => writeLine(await playwrightStatus()),
  check: async () => writeLine((await usableStatus()).module),
  'browser-executable': async () => writeLine((await usableStatus()).browserExecutable),
  'runtime-check': async () => {
    const status = await ownedRuntimeStatus();
    writeLine(status);
    if (!status.ready) process.exitCode = 1;
  },
  install: async (args) => {
    const { browsers, withAxe } = parseInstallArgs(args);
    writeLine(installPlaywrightRuntime(browsers, { withAxe }));
  },
};

async function main() {
  const command = process.argv[2] || 'status';
  if (!Object.hasOwn(COMMANDS, command)) throw new Error(`Unknown command: ${command}`);
  await COMMANDS[command](process.argv.slice(3));
  return 0;
}

const invokedPath = process.argv[1] ? pathToFileURL(realpathSync(process.argv[1])).href : '';
if (invokedPath === import.meta.url) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
