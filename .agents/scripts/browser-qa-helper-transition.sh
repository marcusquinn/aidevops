#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by browser-qa-helper.sh; uses its verified Playwright runtime.

_generate_transition_script() {
	local script_file="$1"
	_generate_transition_setup "$script_file"
	_generate_transition_capture "$script_file"
	return 0
}

# Keep setup and capture generation separate without changing the emitted module.
_generate_transition_setup() {
	local script_file="$1"
	cat >"$script_file" <<'SCRIPT'
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

const [base, from, selector, hold, holdMsArg, atArg, measureFile, storageState, screencastArg, format, outputDir] = process.argv.slice(2);
const holdMs = Number(holdMsArg);
const at = atArg.split(',').map(Number);
if (!/^\d+$/.test(holdMsArg) || !/^\d+(,\d+)*$/.test(atArg) ||
    !Number.isInteger(holdMs) || holdMs < 1 || holdMs > 60000 ||
    at.length > 50 || at.some(ms => !Number.isInteger(ms) || ms < 0 || ms >= holdMs) ||
    new Set(at).size !== at.length) throw new Error('Use unique --at-ms integers below --hold-ms (1–60000), at most 50');
const url = new URL(from, base);
if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Starting URL must use HTTP(S)');
const measureSource = await readFile(measureFile, 'utf8');
// Function expressions only: no module imports/exports. This is trusted operator code.
if (typeof (0, eval)(`(${measureSource}\n)`) !== 'function') throw new Error('--measure-file must contain a function expression');
const imported = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
const { chromium } = imported.chromium ? imported : imported.default;
const browser = await chromium.launch({ headless: true,
  ...(process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE ? { executablePath: process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE } : {}) });
const report = { url: url.href, hold, holdMs, documentRequests: [], commits: [], measurements: [], frames: [], errors: [] };
const prefix = `AIDEVOPS_TRANSITION_${randomUUID()}:`;
const started = Date.now();
let clickedAt = null, armed = false, held = false, releaseTimer;
let holdStarted = null, releasedAt = null, cdp, framesDuringHold = 0;
const writes = [];
try {
  if (outputDir) await mkdir(outputDir, { recursive: true, mode: 0o700 });
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 },
    serviceWorkers: 'block', ...(storageState ? { storageState } : {}) });
  await context.addInitScript(({ prefix, at, measureSource, selector }) => {
    const measure = (0, eval)(`(${measureSource}\n)`);
    let captured = false;
    document.addEventListener('click', event => {
      if (captured || !event.composedPath().some(el => el instanceof Element && el.matches(selector))) return;
      captured = true;
      const clickTime = performance.now();
      console.log(prefix + JSON.stringify({ kind: 'click', timestamp: Date.now() }));
      for (const requestedMs of at) setTimeout(async () => {
        const result = { kind: 'measurement', requestedMs, elapsedMs: performance.now() - clickTime,
          timestamp: Date.now(), url: location.href };
        try { result.data = await measure(); }
        catch (error) { result.error = String(error.message || error); }
        result.completedTimestamp = Date.now();
        try { console.log(prefix + JSON.stringify(result)); }
        catch (error) { console.log(prefix + JSON.stringify({ ...result, data: null, error: String(error) })); }
      }, requestedMs);
    }, true);
  }, { prefix, at, measureSource, selector });
  const page = await context.newPage();
  page.on('console', message => {
    if (!message.text().startsWith(prefix)) return;
    try {
      const result = JSON.parse(message.text().slice(prefix.length));
      if (result.kind === 'click') clickedAt = result.timestamp;
      else if (result.kind === 'measurement') report.measurements.push(result);
    } catch { report.errors.push('Invalid measurement console payload'); }
  });
  context.on('request', request => {
    const purpose = request.headers()['sec-purpose'] || request.headers().purpose || '';
    if (request.resourceType() === 'document' || /prefetch|prerender/i.test(purpose)) {
      report.documentRequests.push({ url: request.url(), resourceType: request.resourceType(),
        navigation: request.isNavigationRequest(), purpose, timestamp: Date.now() });
    }
  });
  page.on('framenavigated', frame => {
    if (frame === page.mainFrame()) report.commits.push({ url: frame.url(), timestamp: Date.now() });
  });
  // Route the entire context, not just the clicked page. Prefetches are logged but
  // never mistaken for the main-frame navigation we intend to hold.
  await context.route('**/*', async route => {
    const request = route.request();
    if (armed && !held && request.isNavigationRequest() && request.resourceType() === 'document' &&
        request.frame() === page.mainFrame() && request.url().includes(hold)) {
      held = true;
      holdStarted = Date.now();
      report.heldRequest = { url: request.url(), resourceType: request.resourceType(), timestamp: holdStarted };
      await new Promise(resolve => { releaseTimer = setTimeout(resolve, holdMs); });
      releasedAt = Date.now();
      report.release = { timestamp: releasedAt };
    }
    await route.continue();
  });
SCRIPT
	return 0
}

_generate_transition_capture() {
	local script_file="$1"
	cat >>"$script_file" <<'SCRIPT'
  await page.goto(url.href, { waitUntil: 'load', timeout: 30000 });
  if (screencastArg === 'true') {
    cdp = await context.newCDPSession(page);
    cdp.on('Page.screencastFrame', frame => {
      const timestamp = Date.now();
      void cdp.send('Page.screencastFrameAck', { sessionId: frame.sessionId }).catch(() => {});
      if (holdStarted !== null && releasedAt === null) framesDuringHold++;
      if (!armed || releasedAt !== null || report.frames.length >= 500) return;
      const file = path.join(outputDir, `frame-${String(report.frames.length).padStart(4, '0')}.jpg`);
      report.frames.push({ timestamp, cdpTimestamp: frame.metadata.timestamp, file });
      writes.push(writeFile(file, Buffer.from(frame.data, 'base64'), { mode: 0o600 })
        .catch(error => { report.errors.push(`Frame write failed: ${error.message}`); }));
    });
    await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 80, maxWidth: 1568, maxHeight: 1568, everyNthFrame: 1 });
  }
  armed = true;
  // Attach before clicking and immediately handle rejection: navigation can commit
  // before the click action resolves, or fail while the source timers still run.
  const navigation = page.waitForNavigation({ waitUntil: 'load', timeout: holdMs + 30000 })
    .catch(error => { report.errors.push(error.message); });
  await page.locator(selector).click({ noWaitAfter: true, timeout: 30000 });
  await navigation;
  if (cdp) await cdp.send('Page.stopScreencast');
  await Promise.all(writes);
  if (!held) report.errors.push('No matching main-frame document was held (check prefetch/prerender and --hold)');
  if (clickedAt === null) report.errors.push('Capture-phase click was not observed');
  for (const ms of at) {
    const measurement = report.measurements.find(item => item.requestedMs === ms);
    if (!measurement) report.errors.push(`Missing source-page measurement at ${ms}ms`);
    else if (measurement.error || measurement.timestamp < holdStarted || measurement.completedTimestamp >= releasedAt)
      report.errors.push(`Measurement at ${ms}ms failed or occurred outside the hold`);
  }
  if (!report.commits.some(commit => releasedAt !== null && commit.timestamp >= releasedAt && commit.url !== url.href))
    report.errors.push('No destination commit observed after release');
  const origin = clickedAt ?? started;
  for (const collection of [report.documentRequests, report.commits, report.measurements, report.frames])
    for (const event of collection) event.timeMs = event.timestamp - origin;
  for (const event of [report.heldRequest, report.release]) if (event) event.timeMs = event.timestamp - origin;
  report.framesDuringHold = framesDuringHold;
  report.frameLimit = 500;
  report.frameLimitReached = report.frames.length === 500;
  report.ok = report.errors.length === 0;
  const json = JSON.stringify(report, null, 2);
  if (outputDir) await writeFile(path.join(outputDir, 'transition.json'), json + '\n', { mode: 0o600 });
  if (format === 'json') console.log(json);
  else {
    console.log(`# Transition QA\n\nResult: ${report.ok ? 'PASS' : 'FAIL'}\n\nFrames during hold: ${report.framesDuringHold}\n\n` +
      '```json\n' + json + '\n```');
  }
  if (!report.ok) process.exitCode = 1;
} finally {
  clearTimeout(releaseTimer);
  await browser.close();
}
SCRIPT
	return 0
}

cmd_transition() {
	local url="" from="/" click="" hold="" hold_ms="4000" at_ms="600,1200"
	local measure_file="" storage_state="" screencast="false" format="json" output_dir=""
	while [[ $# -gt 0 ]]; do
		local option="$1"
		local value="${2:-}"
		if [[ "$option" == "--screencast" ]]; then
			screencast="true"
			shift
			continue
		fi
		if [[ $# -lt 2 || -z "$value" ]]; then
			log_error "Missing value for ${option}"
			return 1
		fi
		case "$option" in
		--url) url="$value" ;;
		--from) from="$value" ;;
		--click) click="$value" ;;
		--hold) hold="$value" ;;
		--hold-ms) hold_ms="$value" ;;
		--at-ms) at_ms="$value" ;;
		--measure-file) measure_file="$value" ;;
		--storage-state) storage_state="$value" ;;
		--format) format="$value" ;;
		--output-dir) output_dir="$value" ;;
		*)
			log_error "Unknown transition option: ${option}"
			return 1
			;;
		esac
		shift 2
	done
	if [[ -z "$url" || -z "$click" || -z "$hold" || ! -f "$measure_file" ]]; then
		log_error "transition requires --url, --click, --hold and an existing --measure-file"
		return 1
	fi
	if [[ "$format" != "json" && "$format" != "markdown" ]] || [[ -n "$storage_state" && ! -f "$storage_state" ]]; then
		log_error "Use --format json|markdown and an existing --storage-state file"
		return 1
	fi
	if [[ "$screencast" == "true" && -z "$output_dir" ]]; then
		output_dir="${QA_RESULTS_DIR}/transition-$(date +%Y%m%d-%H%M%S)-$$"
	fi
	local temp_dir script_file exit_code=0
	temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/browser-qa-transition-XXXXXX")
	script_file="${temp_dir}/script.mjs"
	_generate_transition_script "$script_file"
	run_playwright_node "$script_file" "$url" "$from" "$click" "$hold" "$hold_ms" "$at_ms" \
		"$measure_file" "$storage_state" "$screencast" "$format" "$output_dir" || exit_code=$?
	rm -rf "$temp_dir"
	return "$exit_code"
}
