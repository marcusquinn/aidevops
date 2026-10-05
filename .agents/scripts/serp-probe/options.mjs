// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// CLI parsing, validation, and dry-run planning for serp-captcha-probe.mjs.

import { readFileSync } from 'node:fs';
import { parseArgs } from 'node:util';

import { ENGINES } from './engines.mjs';

export const SCHEMA = 'aidevops.serp-probe/v1';

export function usage() {
  return `Usage: serp-captcha-probe.mjs --keywords-file <file> | --keyword <kw> [--keyword <kw> ...]
  --engine google|bing      Search engine (default: google)
  --max <n>                 Maximum searches (default: 20, max: 200)
  --min-delay <s>           Minimum gap between searches (default: 45, min: 10)
  --max-delay <s>           Maximum gap between searches (default: 120)
  --gl <cc> --hl <lang>     Country and interface language (default: us, en)
  --headless                Run headless (default: headed)
  --hidden                  macOS: run headed but hidden (Cmd-H style); shown only when you must act
  --on-captcha stop|wait    stop (default) or wait for a human solve (headed only)
  --consent manual|reject   Cookie-consent prompt: wait for you (default) or click "Reject all"
  --fresh-profile           Use a new temporary profile instead of the persistent probe profile
  --no-evidence             Do not keep result HTML
  --shuffle                 Randomize keyword order
  --dry-run                 Validate and print the plan without opening a browser
Proxy: set SERP_PROBE_PROXY in the environment (the wrapper resolves it from aidevops secrets).`;
}

const CLI_OPTIONS = {
  'keywords-file': { type: 'string' },
  keyword: { type: 'string', multiple: true },
  engine: { type: 'string', default: 'google' },
  max: { type: 'string', default: '20' },
  'min-delay': { type: 'string', default: '45' },
  'max-delay': { type: 'string', default: '120' },
  gl: { type: 'string', default: 'us' },
  hl: { type: 'string', default: 'en' },
  locale: { type: 'string' },
  timezone: { type: 'string' },
  headless: { type: 'boolean', default: false },
  hidden: { type: 'boolean', default: false },
  'on-captcha': { type: 'string', default: 'stop' },
  consent: { type: 'string', default: 'manual' },
  'fresh-profile': { type: 'boolean', default: false },
  'no-evidence': { type: 'boolean', default: false },
  shuffle: { type: 'boolean', default: false },
  'dry-run': { type: 'boolean', default: false },
  help: { type: 'boolean', default: false },
};

const fail = (message) => { throw new Error(message); };

function validateChoices(values) {
  const rules = [
    [!Object.hasOwn(ENGINES, values.engine), '--engine must be google or bing'],
    [!['stop', 'wait'].includes(values['on-captcha']), '--on-captcha must be stop or wait'],
    [values['on-captcha'] === 'wait' && values.headless, '--on-captcha wait requires a headed browser'],
    [!['manual', 'reject'].includes(values.consent), '--consent must be manual or reject'],
    [values.hidden && values.headless, '--hidden and --headless are mutually exclusive'],
    [values.hidden && process.platform !== 'darwin', '--hidden is macOS-only'],
    [!/^[a-z]{2}$/i.test(values.gl), '--gl must be a two-letter country code such as us'],
    [!/^[a-z]{2,3}(-[a-z0-9]{2,8})?$/i.test(values.hl), '--hl must be a language code such as en'],
  ];
  const broken = rules.find(([failed]) => failed);
  if (broken) fail(broken[1]);
}

function loadKeywords(values) {
  const raw = [...(values.keyword || [])];
  if (values['keywords-file']) raw.push(...readFileSync(values['keywords-file'], 'utf8').split('\n'));
  const keywords = raw.map((kw) => kw.trim()).filter((kw) => kw && !kw.startsWith('#'));
  if (keywords.length === 0) fail('Provide --keyword or --keywords-file with at least one keyword');
  if (values.shuffle) {
    for (let i = keywords.length - 1; i > 0; i -= 1) {
      const j = Math.floor(Math.random() * (i + 1));
      [keywords[i], keywords[j]] = [keywords[j], keywords[i]];
    }
  }
  return keywords;
}

export function parseOptions(argv) {
  const { values } = parseArgs({ args: argv, options: CLI_OPTIONS, strict: true });
  if (values.help) return { help: true };
  const int = (name, min, max) => {
    const value = Number(values[name]);
    if (!Number.isInteger(value) || value < min || value > max) fail(`--${name} must be an integer from ${min} to ${max}`);
    return value;
  };
  validateChoices(values);
  const keywords = loadKeywords(values);

  const minDelay = int('min-delay', 10, 3600);
  const maxDelay = int('max-delay', minDelay, 7200);
  const max = int('max', 1, 200);
  return {
    engine: values.engine,
    keywords: keywords.slice(0, max),
    minDelay,
    maxDelay,
    gl: values.gl.toLowerCase(),
    hl: values.hl,
    locale: values.locale || `${values.hl}-${values.gl.toUpperCase()}`,
    timezone: values.timezone,
    headless: values.headless,
    hidden: values.hidden,
    onCaptcha: values['on-captcha'],
    consent: values.consent,
    freshProfile: values['fresh-profile'],
    keepEvidence: !values['no-evidence'],
    dryRun: values['dry-run'],
  };
}

export function printPlan(options) {
  const gaps = Math.max(0, options.keywords.length - 1);
  process.stdout.write(`${JSON.stringify({
    schema: SCHEMA,
    dry_run: true,
    engine: options.engine,
    planned: options.keywords.length,
    pacing_seconds: { min: options.minDelay, max: options.maxDelay },
    estimated_minutes: { min: Math.round((gaps * options.minDelay) / 60), max: Math.round((gaps * options.maxDelay) / 60) },
    headless: options.headless,
    hidden: options.hidden,
    gl: options.gl,
    on_captcha: options.onCaptcha,
    egress: process.env.SERP_PROBE_PROXY ? 'proxy' : 'direct',
    contacted_targets: false,
  })}\n`);
}
