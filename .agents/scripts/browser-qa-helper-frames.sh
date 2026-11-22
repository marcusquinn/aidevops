#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by browser-qa-helper.sh; uses its verified Playwright runtime.

_generate_frames_script() {
	local script_file="$1"
	_generate_frames_setup "$script_file"
	_generate_frames_capture "$script_file"
	_generate_frames_report "$script_file"
	return 0
}

_generate_frames_setup() {
	local script_file="$1"
	cat >"$script_file" <<'SCRIPT'
import { readFile, mkdir, lstat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

const [urlArg, measureFile, ready, widthsArg, cpuArg, from, afterSelector,
  noAfter, transformFile, settleArg, format, outputDir] = process.argv.slice(2);
const httpUrl = value => {
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('URLs must use HTTP(S)');
  return url.href;
};
const url = httpUrl(urlArg);
if (from) httpUrl(from);
const widths = widthsArg.split(',').map(Number), cpu = Number(cpuArg), settleMs = Number(settleArg);
if (!/^\d+(,\d+)*$/.test(widthsArg) || widths.length > 20 || new Set(widths).size !== widths.length ||
    widths.some(n => !Number.isInteger(n) || n < 1 || n > 10000))
  throw new Error('--widths needs up to 20 unique integers between 1 and 10000');
if (!Number.isFinite(cpu) || cpu < 1 || cpu > 100) throw new Error('--cpu must be between 1 and 100');
if (!/^\d+$/.test(settleArg) || settleMs > 60000) throw new Error('--settle-ms must be an integer between 0 and 60000');
const functionSource = async file => {
  const source = await readFile(file, 'utf8');
  if (typeof (0, eval)(`(${source}\n)`) !== 'function') throw new Error(`${file}: expected a function expression`);
  return source;
};
const measureSource = await functionSource(measureFile);
const transform = transformFile ? (0, eval)(`(${await functionSource(transformFile)}\n)`) : null;
const report = { url, from: from || null, cpu, settleMs, sentinel: noAfter !== 'true', widths: [] };
if (outputDir) {
  const target = path.join(outputDir, 'frames.json');
  let existing;
  try { existing = await lstat(target); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (existing) throw new Error(`${target} already exists; choose a new --output-dir`);
}
const imported = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
const { chromium } = imported.chromium ? imported : imported.default;
const browser = await chromium.launch({ headless: true,
  ...(process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE ? { executablePath: process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE } : {}) });
try {
  for (const width of widths) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, serviceWorkers: 'block' });
    try {
      const page = await context.newPage();
      // Warm visit precedes throttling and interception, preserving the normal HTTP cache here.
      if (from) await page.goto(from, { waitUntil: 'load', timeout: 30000 });
      const errors = { console: [], page: [] }, routingErrors = [];
      page.on('console', message => { if (message.type() === 'error') errors.console.push(message.text()); });
      page.on('pageerror', error => errors.page.push(error.message));
      if (transform) await page.route('**/*', async route => {
        try {
          const request = route.request();
          if (request.resourceType() !== 'document' || request.frame() !== page.mainFrame()) return await route.continue();
          const response = await route.fetch();
          const body = await transform(await response.text());
          if (typeof body !== 'string') throw new Error('Transform must return an HTML string');
          const headers = { ...response.headers() };
          // route.fetch() decodes the body; do not retain stale length/encoding headers.
          delete headers['content-length']; delete headers['content-encoding'];
          await route.fulfill({ response, headers, body });
        } catch (error) {
          routingErrors.push(String(error));
          await route.abort().catch(() => {});
        }
      });
      const cdp = await context.newCDPSession(page);
      await cdp.send('Emulation.setCPUThrottlingRate', { rate: cpu });
      const key = `__aidevopsFrames_${randomUUID().replaceAll('-', '')}`;
SCRIPT
	return 0
}

_generate_frames_capture() {
	local script_file="$1"
	cat >>"$script_file" <<'SCRIPT'
      await page.addInitScript(({ key, ready, afterSelector, noAfter, measureSource, settleMs }) => {
        if (window !== window.top) return;
        const data = { samples: [], windowErrors: [], measurementErrors: [], done: false,
          sentinelAt: null, loadAt: null };
        window[key] = data;
        const measure = (0, eval)(`(${measureSource}\n)`);
        let observer, sentinel, current, frameId, stopped = false, toggle = false;
        const stop = () => {
          stopped = true; cancelAnimationFrame(frameId); observer?.disconnect(); sentinel?.remove(); data.done = true;
        };
        const sample = () => {
          // Copy at capture time, disallow async/undefined results, and detect cyclic/non-JSON values.
          const state = measure();
          if (state === undefined || state?.then) throw new Error('Measurement must synchronously return JSON-able data');
          return { t: performance.now(), state: JSON.parse(JSON.stringify(state)), fonts: document.fonts.status };
        };
        window.addEventListener('error', event => data.windowErrors.push({ t: performance.now(), message: event.message }));
        window.addEventListener('load', () => {
          data.loadAt = performance.now(); setTimeout(stop, settleMs);
        }, { once: true });
        const tick = () => {
          if (stopped) return;
          try {
            current = null;
            if (document.querySelector(ready)) {
              current = { before: sample() };
              data.samples.push(current);
              if (data.samples.length >= 100000) throw new Error('Frame safety limit reached');
            }
            if (!noAfter && !sentinel && document.body && (!afterSelector || document.querySelector(afterSelector))) {
              sentinel = document.createElement('div');
              sentinel.style.cssText = 'all:initial!important;position:absolute!important;visibility:hidden!important;pointer-events:none!important;height:1px!important;top:0!important;left:0!important;';
              document.body.append(sentinel);
              observer = new ResizeObserver(() => {
                if (!current || stopped) return;
                try { current.painted = sample(); }
                catch (error) { data.measurementErrors.push(String(error)); stop(); }
              });
              observer.observe(sentinel);
              data.sentinelAt = performance.now();
            }
            if (sentinel) {
              toggle = !toggle;
              sentinel.style.setProperty('width', toggle ? '1px' : '2px', 'important');
            }
          } catch (error) { data.measurementErrors.push(String(error)); stop(); }
          if (!stopped) frameId = requestAnimationFrame(tick);
        };
        frameId = requestAnimationFrame(tick);
      }, { key, ready, afterSelector, noAfter: noAfter === 'true', measureSource, settleMs });
      try {
        await page.goto(url, { waitUntil: 'load', timeout: 30000 });
        await page.waitForFunction(key => window[key]?.done, key, { timeout: settleMs + 30000 });
      } catch (error) {
        if (!routingErrors.length) throw error;
        throw new Error(`${error.message}; transform errors: ${routingErrors.join('; ')}`, { cause: error });
      }
      const capture = await page.evaluate(key => window[key], key);
SCRIPT
	return 0
}

_generate_frames_report() {
	local script_file="$1"
	cat >>"$script_file" <<'SCRIPT'
      const problems = [...routingErrors, ...capture.measurementErrors];
      if (!capture.samples.length) problems.push('No frames captured: check --ready and --settle-ms');
      if (noAfter !== 'true' && !capture.samples.some(frame => frame.painted))
        problems.push('No sentinel samples: check --after-selector and --settle-ms');
      const runs = [];
      for (const frame of capture.samples) {
        const value = frame.painted || frame.before;
        const phase = frame.painted ? 'painted' : 'raf';
        const differs = frame.painted && JSON.stringify([frame.before.state, frame.before.fonts]) !== JSON.stringify([value.state, value.fonts]);
        const before = differs ? { state: frame.before.state, fonts: frame.before.fonts } : null;
        const identity = JSON.stringify([phase, value.state, value.fonts, before]);
        const last = runs.at(-1);
        if (last?.identity === identity) { last.endMs = value.t; last.frames++; }
        else runs.push({ identity, startMs: value.t, endMs: value.t, frames: 1, phase, state: value.state, fonts: value.fonts, before });
      }
      for (const run of runs) delete run.identity;
      const errorCounts = { window: capture.windowErrors.length,
        resizeObserver: capture.windowErrors.filter(error => /ResizeObserver/i.test(error.message)).length,
        console: errors.console.length, page: errors.page.length };
      report.widths.push({ width, height: 900, ...capture, runs, errors, errorCounts, problems });
    } finally { await context.close(); }
  }
  report.ok = report.widths.every(item => !item.problems.length);
  const json = JSON.stringify(report, null, 2);
  if (outputDir) {
    // mkdir's mode affects only newly created directories; preserve existing permissions.
    await mkdir(outputDir, { recursive: true, mode: 0o700 });
    // Refuse to overwrite prior evidence or follow an existing report symlink.
    await writeFile(path.join(outputDir, 'frames.json'), json + '\n', { mode: 0o600, flag: 'wx' });
  }
  if (format === 'json') console.log(json);
  else {
    console.log('# Frame-by-frame load recording\n');
    for (const item of report.widths) {
      console.log(`\n## ${item.width}px cpu x${cpu}${from ? ' (after warm visit)' : ''}\n`);
      console.log('```text');
      for (const run of item.runs) console.log(`${run.startMs.toFixed(1)}-${run.endMs.toFixed(1)} ms  ${run.frames} frames  ${run.phase}: ${JSON.stringify(run.state)} fonts=${run.fonts}` +
        (run.before ? ` (before observers: ${JSON.stringify(run.before)})` : ''));
      console.log(`window error events (ResizeObserver): ${item.errorCounts.window} (${item.errorCounts.resizeObserver})  console/page errors: ${item.errorCounts.console}/${item.errorCounts.page}`);
      console.log('```');
      for (const problem of item.problems) console.log(`Capture failed: ${problem}`);
    }
  }
  if (!report.ok) process.exitCode = 1;
} finally { await browser.close(); }
SCRIPT
	return 0
}

cmd_frames() {
	local url="" measure_file="" ready="body" widths="1280" cpu="1" from="" after_selector=""
	local no_after="false" transform_file="" settle_ms="1000" format="json" output_dir=""
	while [[ $# -gt 0 ]]; do
		local option="$1" value="${2:-}"
		case "$option" in
		--help | -h) cmd_help; return 0 ;;
		--no-after) no_after="true"; shift; continue ;;
		esac
		if [[ $# -lt 2 || -z "$value" || "$value" == --* ]]; then
			log_error "Missing value for ${option}"
			return 1
		fi
		case "$option" in
		--url) url="$value" ;;
		--measure-file) measure_file="$value" ;;
		--ready) ready="$value" ;;
		--widths) widths="$value" ;;
		--cpu) cpu="$value" ;;
		--from) from="$value" ;;
		--after-selector) after_selector="$value" ;;
		--transform-file) transform_file="$value" ;;
		--settle-ms) settle_ms="$value" ;;
		--format) format="$value" ;;
		--output-dir) output_dir="$value" ;;
		*) log_error "Unknown frames option: ${option}"; return 1 ;;
		esac
		shift 2
	done
	if [[ -z "$url" || ! -f "$measure_file" || ( -n "$transform_file" && ! -f "$transform_file" ) ]]; then
		log_error "frames requires --url and a regular --measure-file (and regular --transform-file if specified)"
		return 1
	fi
	if [[ "$format" != "json" && "$format" != "markdown" ]] || [[ "$no_after" == "true" && -n "$after_selector" ]]; then
		log_error "Use --format json|markdown and only one of --after-selector or --no-after"
		return 1
	fi
	local temp_dir script_file exit_code=0
	temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/browser-qa-frames-XXXXXX")
	script_file="${temp_dir}/script.mjs"
	_generate_frames_script "$script_file"
	chmod 600 "$script_file"
	run_playwright_node "$script_file" "$url" "$measure_file" "$ready" "$widths" "$cpu" "$from" \
		"$after_selector" "$no_after" "$transform_file" "$settle_ms" "$format" "$output_dir" || exit_code=$?
	rm -rf "$temp_dir"
	return "$exit_code"
}
