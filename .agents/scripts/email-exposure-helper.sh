#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Read-only email exposure audit. Output may contain private addresses: keep local.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

scan_urls() {
	command -v python3 >/dev/null || return 2
	command -v curl >/dev/null || return 2
	python3 - "$@" <<'PY' || return $?
import html
import json
import re
import subprocess
import sys
import time
from html.parser import HTMLParser
from urllib.parse import urlsplit, urlunsplit

# Practical harvesting pattern, not an RFC mailbox validator.
EMAIL = re.compile(r"[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)+")
DECODER = re.compile(r"email-decode(?:\.min)?\.js|__cf_email__|data-sps-(?:e|mailto)|sps[-_]?(?:email|decode)", re.I)

class Audit(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.addresses = {}
        self.placeholders = dict.fromkeys(('data-cfemail', 'data-sps-e', 'data-sps-mailto'), 0)
        self.script_context = None
        self.decoder = False

    def record(self, value, context):
        for match in EMAIL.finditer(html.unescape(value)):
            address = match.group().rstrip('.')
            self.addresses.setdefault(address, set()).add(context)

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == 'script':
            self.script_context = 'json-ld' if (values.get('type') or '').lower().split(';')[0].strip() == 'application/ld+json' else 'script'
            self.decoder |= bool(DECODER.search(values.get('src') or ''))
        for name, value in attrs:
            if name in self.placeholders:
                self.placeholders[name] += 1
            if value:
                self.record(value, 'href' if name == 'href' else 'attribute:' + name)

    def handle_endtag(self, tag):
        if tag == 'script':
            self.script_context = None

    def handle_data(self, data):
        self.record(data, self.script_context or 'text')
        if self.script_context == 'script':
            self.decoder |= bool(DECODER.search(data))

    def handle_comment(self, data):
        # Comments are readable by scrapers, even though visitors cannot see them.
        self.record(data, 'text')

status = 0
for url in sys.argv[1:]:
    try:
        parts = urlsplit(url)
        if parts.scheme not in ('http', 'https') or not parts.hostname or parts.username or parts.password:
            raise ValueError('Expected an HTTP(S) URL without embedded credentials')
        query = parts.query + ('&' if parts.query else '') + '_aidevops_email_audit=' + str(time.time_ns())
        target = urlunsplit((parts.scheme, parts.netloc, parts.path, query, ''))
        fetched = subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location',
                                  '--proto', '=http,https', '--proto-redir', '=http,https',
                                  '--connect-timeout', '10', '--max-time', '45',
                                  '--header', 'Cache-Control: no-cache', '--', target],
                                 capture_output=True, check=False)
        if fetched.returncode:
            # Do not echo response bodies, query strings or credentials on errors.
            raise ValueError('curl fetch failed (exit %d)' % fetched.returncode)
        audit = Audit()
        audit.feed(fetched.stdout.decode('utf-8', errors='replace'))
        audit.close()
        print(json.dumps({'url': url,
                          'readable': [{'address': a, 'contexts': sorted(c)} for a, c in sorted(audit.addresses.items())],
                          'placeholders': audit.placeholders, 'decoder_script_present': audit.decoder}))
        if audit.addresses:
            status = max(status, 1)
    except (ValueError, OSError) as error:
        print(json.dumps({'error': str(error)}), file=sys.stderr)
        status = 2
sys.exit(status)
PY
	return 0
}

browser_url() {
	local url="$1"
	# Reuse the Browser QA runtime resolver, never guess a module installation path.
	# shellcheck source=browser-qa-helper-core.sh
	source "${SCRIPT_DIR}/browser-qa-helper-core.sh"
	check_playwright || return 2
	run_playwright_node --input-type=module - "$url" <<'JS' || return $?
const imported = await import(process.env.AIDEVOPS_PLAYWRIGHT_MODULE);
const { chromium } = imported.chromium ? imported : imported.default;
const options = { headless: true };
if (process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE) options.executablePath = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
let browser;
try {
  const target = new URL(process.argv[2]);
  if (!['http:', 'https:'].includes(target.protocol) || target.username || target.password) {
    throw new Error('Expected an HTTP(S) URL without embedded credentials');
  }
  browser = await chromium.launch(options);
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const response = await page.goto(target.href, { waitUntil: 'domcontentloaded', timeout: 45000 });
  if (!response || !response.ok()) throw new Error('Navigation returned an unsuccessful HTTP response');
  // Bounded decoder grace period; do not wait for load/networkidle on third parties.
  await page.waitForTimeout(1000);
  const links = await page.locator('a[href^="mailto:" i]').evaluateAll(elements => elements.map(el => ({
    text: el.textContent,
    attributes: Object.fromEntries([...el.attributes].map(a => [a.name, a.value]))
  })));
  console.log(JSON.stringify({ url: target.href, mailto_links: links, page_errors: errors }));
  process.exitCode = errors.length ? 1 : 0;
} catch (error) {
  console.error(JSON.stringify({ error: error.message }));
  process.exitCode = 2;
} finally {
  if (browser) await browser.close();
}
JS
	return 0
}

main() {
	local command="${1:-help}"
	local url="${2:-}"
	if [[ $# -gt 0 ]]; then shift; fi
	case "$command" in
	scan)
		[[ $# -gt 0 ]] || return 2
		scan_urls "$@"
		return $?
		;;
	browser)
		[[ $# -eq 1 ]] || return 2
		browser_url "$url"
		return $?
		;;
	help | --help | -h)
		printf 'Usage: email-exposure-helper.sh scan <url>... | browser <url>\nScan: 0 none readable, 1 exposed, 2 fetch/usage/dependency error\nBrowser: 0 no page errors, 1 page errors, 2 navigation/runtime error\nDependencies: curl and Python 3; browser also needs the Browser QA Playwright runtime\n'
		return 0
		;;
	*) return 2 ;;
	esac
}

main "$@"
