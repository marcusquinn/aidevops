#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for the opt-in authenticated read-only journey runner (GH#32375).
# Schema/validation cases always run. Browser cases start two disposable local
# fixture apps (different ports, credentials and journeys) and are skipped when
# no Playwright runtime + browser is available.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
RUNNER="${SCRIPT_DIR}/../browser-qa-journey.mjs"
HELPER="${SCRIPT_DIR}/../browser-qa-helper.sh"
PLAYWRIGHT_RUNTIME="${SCRIPT_DIR}/../playwright-runtime.mjs"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
JOURNEY_TEST_TEMP_DIR=""
FIXTURE_PIDS=()
ALPHA_PORT=""
BETA_PORT=""
STARTED_PORT=""
RUN_OUTPUT=""
RUN_EXIT=0

readonly ALPHA_USER_VALUE="alpha-user"
readonly ALPHA_PASSWORD_VALUE="alpha-Secret-7731"
readonly BETA_USER_VALUE="beta-user"
readonly BETA_PASSWORD_VALUE="beta-Secret-9054"

cleanup() {
	local pid
	for pid in "${FIXTURE_PIDS[@]+"${FIXTURE_PIDS[@]}"}"; do
		kill "$pid" 2>/dev/null || true
	done
	rm -rf "${JOURNEY_TEST_TEMP_DIR:-}"
	return 0
}

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '     %s\n' "${detail:0:600}"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

check() {
	local name="$1"
	local condition_status="$2"
	local detail="${3:-}"
	if [[ "$condition_status" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "$detail"
	fi
	return 0
}

assert_rejected() {
	local name="$1"
	local config="$2"
	local expected="$3"
	local output exit_code=0
	output=$(node "$RUNNER" "$config" test 2>&1) || exit_code=$?
	if [[ "$exit_code" -ne 0 ]] && [[ "$output" == *"$expected"* ]]; then
		pass "$name"
	else
		fail "$name" "exit=${exit_code} output=${output}"
	fi
	return 0
}

run_validation_tests() {
	local dir="$JOURNEY_TEST_TEMP_DIR"
	local env_ok='"credentials":{"usernameEnv":"QA_USER","passwordEnv":"QA_PASSWORD"},"login":{"path":"/login","method":"POST","successPath":"/home","usernameSelector":"#user","passwordSelector":"#password","submitSelector":"button"},"logout":{"path":"/logout","method":"POST"}'
	printf '%s' '{"version":2,"environments":{},"steps":[]}' >"${dir}/version.json"
	printf '%s' '{"version":1,"environments":{"test":{"origin":"https://example.invalid/path","credentials":{"usernameEnv":"QA_USER","passwordEnv":"QA_PASSWORD"},"login":{},"logout":{}}},"steps":[{"type":"visible","selector":"body"}]}' >"${dir}/origin.json"
	printf '{"version":1,"environments":{"test":{"origin":"https://example.invalid",%s}},"steps":[{"type":"visible","selector":"body"}]}' "$env_ok" >"${dir}/credentials.json"
	printf '{"version":1,"environments":{"test":{"origin":"https://example.invalid",%s}},"steps":[{"type":"navigate","path":"//evil.invalid/x"}]}' "$env_ok" >"${dir}/protocol-relative.json"
	printf '{"version":1,"environments":{"test":{"origin":"https://example.invalid",%s}},"steps":[{"type":"evaluate","script":"1"}]}' "$env_ok" >"${dir}/step-type.json"
	printf '{"version":1,"environments":{"test":{"origin":"https://example.invalid",%s}},"steps":[{"type":"constructor"}]}' "$env_ok" >"${dir}/prototype-step.json"

	assert_rejected "unknown schema version fails before authentication" "${dir}/version.json" "version must be 1"
	assert_rejected "origin path fails closed" "${dir}/origin.json" "exact http(s) origin"
	assert_rejected "missing credential fails before browser launch" "${dir}/credentials.json" "credentials are unavailable"
	QA_USER=u QA_PASSWORD=p assert_rejected "protocol-relative navigate path is rejected" "${dir}/protocol-relative.json" "step 1 path is missing or invalid"
	QA_USER=u QA_PASSWORD=p assert_rejected "executable/unknown step type is rejected" "${dir}/step-type.json" "unsupported journey step type"
	QA_USER=u QA_PASSWORD=p assert_rejected "prototype-named step type is rejected" "${dir}/prototype-step.json" "unsupported journey step type"
	return 0
}

write_fixture_server() {
	cat >"${JOURNEY_TEST_TEMP_DIR}/fixture-server.mjs" <<'FIXTURE'
import http from 'node:http';
import crypto from 'node:crypto';

const [user, pass, title] = process.argv.slice(2);
const sessions = new Set();
let stats = {};
const resetStats = () => { stats = { logins: 0, logouts: 0, writes: 0, foreignCookies: 0, offOriginHits: 0 }; sessions.clear(); };
resetStats();
const sid = (req) => (/(?:^|;\s*)sid=([^;]+)/.exec(req.headers.cookie || '') || [])[1] || null;
const send = (res, status, body, headers = {}) => { res.writeHead(status, { 'content-type': 'text/html', ...headers }); res.end(body); };
const readBody = (req) => new Promise((resolve) => { let data = ''; req.on('data', (c) => { data += c; }); req.on('end', () => resolve(data)); });
const form = (action) => `<!doctype html><form method="post" action="${action}"><input id="user" name="user"><input id="password" name="password" type="password"><button type="submit">Sign in</button></form>`;
const home = (port) => `<!doctype html><title>${title}</title><h1 id="title">${title} dashboard</h1>
<ul><li class="clip">A</li><li class="clip">B</li></ul>
<button id="open">Open</button><div id="modal" hidden role="dialog"><h2 id="modal-title">${title} clip</h2><video id="player" src="/media/${title}.mp4"></video></div>
<button id="save">Save</button><p id="save-result"></p><a id="leave" href="http://localhost:${port}/home">Leave</a>
<script>
document.getElementById('open').onclick = () => { document.getElementById('modal').hidden = false; };
document.getElementById('save').onclick = () => fetch('/save', { method: 'POST' })
  .then((r) => 'status ' + r.status, () => 'blocked')
  .then((s) => { document.getElementById('save-result').textContent = 'save: ' + s; });
</script>`;

const routes = {
  'GET /login': (req, res) => send(res, 200, form('/login')),
  'GET /sso-login': (req, res) => send(res, 200, form('/sso')),
  'POST /sso': (req, res, port) => send(res, 307, '', { location: `http://localhost:${port}/steal` }),
  'POST /login': async (req, res) => {
    const body = new URLSearchParams(await readBody(req));
    if (body.get('user') !== user || body.get('password') !== pass) return send(res, 401, 'denied');
    const id = crypto.randomUUID();
    sessions.add(id);
    stats.logins += 1;
    return send(res, 303, '', { location: '/home', 'set-cookie': `sid=${id}; HttpOnly; Path=/; SameSite=Lax` });
  },
  'GET /home': (req, res, port) => {
    const id = sid(req);
    if (sessions.has(id)) return send(res, 200, home(port));
    if (id) stats.foreignCookies += 1;
    return send(res, 302, '', { location: '/login' });
  },
  'POST /logout': (req, res) => {
    if (sessions.delete(sid(req))) stats.logouts += 1;
    return send(res, 200, 'bye');
  },
  'POST /save': (req, res) => { stats.writes += 1; send(res, 200, 'saved'); },
  'GET /stats': (req, res) => send(res, 200, JSON.stringify({ ...stats, active: sessions.size }), { 'content-type': 'application/json' }),
  'POST /reset': (req, res) => { resetStats(); send(res, 200, 'reset'); },
};

const server = http.createServer((req, res) => {
  const port = server.address().port;
  if ((req.headers.host || '').startsWith('localhost')) { stats.offOriginHits += 1; return send(res, 200, 'off-origin'); }
  const handler = routes[`${req.method} ${new URL(req.url, 'http://x').pathname}`];
  return handler ? handler(req, res, port) : send(res, 404, 'not found');
});
server.listen(0, '127.0.0.1', () => { process.stdout.write(`${server.address().port}\n`); });
FIXTURE
	return 0
}

# Starts one fixture app on an ephemeral port; sets STARTED_PORT.
start_fixture() {
	local name="$1"
	local user="$2"
	local password="$3"
	local port_file="${JOURNEY_TEST_TEMP_DIR}/${name}.port"
	local attempt
	STARTED_PORT=""
	node "${JOURNEY_TEST_TEMP_DIR}/fixture-server.mjs" "$user" "$password" "$name" >"$port_file" 2>/dev/null &
	FIXTURE_PIDS+=("$!")
	for attempt in $(seq 1 50); do
		if [[ -s "$port_file" ]]; then
			STARTED_PORT=$(tr -d '[:space:]' <"$port_file")
			return 0
		fi
		sleep 0.1
	done
	printf 'fixture %s did not start after %s attempts\n' "$name" "$attempt" >&2
	return 1
}

fixture_stats() {
	local port="$1"
	curl -fsS "http://127.0.0.1:${port}/stats"
	return 0
}

reset_fixtures() {
	curl -fsS -X POST "http://127.0.0.1:${ALPHA_PORT}/reset" >/dev/null
	curl -fsS -X POST "http://127.0.0.1:${BETA_PORT}/reset" >/dev/null
	return 0
}

# Args: $1=file name, $2=environment JSON body (without braces), $3=steps JSON array
write_journey() {
	local file="$1"
	local environment="$2"
	local steps="$3"
	printf '{"version":1,"environments":{%s},"steps":%s}' "$environment" "$steps" >"${JOURNEY_TEST_TEMP_DIR}/${file}"
	return 0
}

# Args: $1=port, $2=credential env prefix, $3=optional extra environment JSON members,
#       $4=optional login endpoint members (default: POST /login)
environment_json() {
	local port="$1"
	local prefix="$2"
	local extra="${3:-}"
	local login_endpoint="${4:-\"path\":\"/login\",\"method\":\"POST\"}"
	printf '"origin":"http://127.0.0.1:%s","credentials":{"usernameEnv":"%s_USER","passwordEnv":"%s_PASSWORD"},"login":{%s,"successPath":"/home","usernameSelector":"#user","passwordSelector":"#password","submitSelector":"button[type=submit]"},"logout":{"path":"/logout","method":"POST"}%s' \
		"$port" "$prefix" "$prefix" "$login_endpoint" "$extra"
	return 0
}

run_journey() {
	local config="$1"
	local environment="$2"
	RUN_EXIT=0
	RUN_OUTPUT=$(QA_ALPHA_USER="$ALPHA_USER_VALUE" QA_ALPHA_PASSWORD="$ALPHA_PASSWORD_VALUE" \
		QA_BETA_USER="$BETA_USER_VALUE" QA_BETA_PASSWORD="$BETA_PASSWORD_VALUE" \
		bash "$HELPER" journey --config "${JOURNEY_TEST_TEMP_DIR}/${config}" --environment "$environment" 2>&1) || RUN_EXIT=$?
	printf '%s\n' "$RUN_OUTPUT" >>"${JOURNEY_TEST_TEMP_DIR}/all-output.log"
	return 0
}

stats_match() {
	local port="$1"
	shift
	local stats pattern
	stats=$(fixture_stats "$port")
	for pattern in "$@"; do
		if [[ "$stats" != *"$pattern"* ]]; then
			printf '%s' "$stats"
			return 1
		fi
	done
	return 0
}

test_alpha_journey_passes() {
	local alpha_env detail status=0
	alpha_env="\"alpha\":{$(environment_json "$ALPHA_PORT" QA_ALPHA)}"
	write_journey alpha.json "$alpha_env" '[{"name":"dashboard","type":"navigate","path":"/home"},{"type":"visible","selector":"#title"},{"type":"text","selector":"#title","includes":"alpha dashboard"},{"type":"count","selector":".clip","equals":2},{"name":"open media","type":"click","selector":"#open"},{"type":"text","selector":"#modal-title","includes":"alpha clip"},{"type":"attribute","selector":"#player","name":"src","equals":"/media/alpha.mp4"},{"type":"no-horizontal-overflow"}]'
	run_journey alpha.json alpha
	[[ "$RUN_EXIT" -eq 0 && "$RUN_OUTPUT" == *'"status":"passed"'* && "$RUN_OUTPUT" == *'"viewport":"desktop"'* && "$RUN_OUTPUT" == *'"viewport":"mobile"'* ]] || status=1
	check "alpha journey passes at desktop and mobile via CLI" "$status" "exit=${RUN_EXIT} ${RUN_OUTPUT}"
	status=0
	detail=$(stats_match "$ALPHA_PORT" '"logins":2' '"logouts":2' '"writes":0' '"active":0') || status=1
	check "alpha: each viewport signed in, signed out and wrote nothing" "$status" "$detail"
	return 0
}

test_beta_journey_isolated() {
	local beta_env detail status=0
	beta_env="\"beta\":{$(environment_json "$BETA_PORT" QA_BETA ',"viewports":["mobile","desktop"]')}"
	write_journey beta.json "$beta_env" '[{"type":"visible","selector":"#title"},{"type":"text","selector":"h1","includes":"beta"},{"type":"click","selector":"#open"},{"type":"visible","selector":"[role=dialog]"}]'
	run_journey beta.json beta
	[[ "$RUN_EXIT" -eq 0 && "$RUN_OUTPUT" == *'"status":"passed"'* ]] || status=1
	check "beta: second environment and journey definition pass" "$status" "exit=${RUN_EXIT} ${RUN_OUTPUT}"
	status=0
	detail=$(stats_match "$BETA_PORT" '"logins":2' '"logouts":2' '"foreignCookies":0' '"active":0') || status=1
	check "beta: no cookies leaked between runs or environments" "$status" "$detail"
	return 0
}

test_non_api_write_blocked() {
	local env detail status=0
	env="\"alpha\":{$(environment_json "$ALPHA_PORT" QA_ALPHA ',"viewports":["desktop"]')}"
	write_journey write.json "$env" '[{"type":"click","selector":"#save"},{"type":"text","selector":"#save-result","includes":"save:"}]'
	run_journey write.json alpha
	[[ "$RUN_EXIT" -ne 0 && "$RUN_OUTPUT" == *'"blockedWrites":1'* ]] || status=1
	check "non-/api POST from page is blocked and fails the run" "$status" "exit=${RUN_EXIT} ${RUN_OUTPUT}"
	status=0
	detail=$(stats_match "$ALPHA_PORT" '"writes":0' '"logouts":1' '"active":0') || status=1
	check "blocked write never reached the app and sign-out still ran" "$status" "$detail"
	return 0
}

test_wrong_origin_navigation_blocked() {
	local env detail status=0
	env="\"alpha\":{$(environment_json "$ALPHA_PORT" QA_ALPHA ',"viewports":["desktop"],"timeoutMs":3000')}"
	write_journey leave.json "$env" '[{"type":"click","selector":"#leave"},{"type":"visible","selector":"#title"}]'
	run_journey leave.json alpha
	[[ "$RUN_EXIT" -ne 0 && "$RUN_OUTPUT" == *'"offOriginNavigations":1'* ]] || status=1
	check "wrong-origin navigation fails closed" "$status" "exit=${RUN_EXIT} ${RUN_OUTPUT}"
	status=0
	detail=$(stats_match "$ALPHA_PORT" '"offOriginHits":0' '"active":0') || status=1
	check "wrong-origin request never left the browser" "$status" "$detail"
	return 0
}

test_off_origin_auth_redirect_blocked() {
	local env detail status=0
	env="\"alpha\":{$(environment_json "$ALPHA_PORT" QA_ALPHA ',"viewports":["desktop"],"timeoutMs":3000' '"path":"/sso","method":"POST","pagePath":"/sso-login"')}"
	write_journey sso.json "$env" '[{"type":"visible","selector":"#title"}]'
	run_journey sso.json alpha
	[[ "$RUN_EXIT" -ne 0 && "$RUN_OUTPUT" == *'"offOriginNavigations":1'* ]] || status=1
	check "off-origin 307 auth redirect fails closed" "$status" "exit=${RUN_EXIT} ${RUN_OUTPUT}"
	status=0
	detail=$(stats_match "$ALPHA_PORT" '"offOriginHits":0') || status=1
	check "credentials were not replayed to the off-origin target" "$status" "$detail"
	return 0
}

test_timeout_still_signs_out() {
	local env detail status=0
	env="\"alpha\":{$(environment_json "$ALPHA_PORT" QA_ALPHA ',"viewports":["desktop"],"timeoutMs":1000')}"
	write_journey timeout.json "$env" '[{"type":"visible","selector":"#never-rendered"}]'
	run_journey timeout.json alpha
	[[ "$RUN_EXIT" -ne 0 && "$RUN_OUTPUT" == *'Timeout'* && "$RUN_OUTPUT" == *'"signOut":{"status":"passed"}'* ]] || status=1
	check "step timeout fails and still signs out" "$status" "exit=${RUN_EXIT} ${RUN_OUTPUT}"
	status=0
	detail=$(stats_match "$ALPHA_PORT" '"logouts":1' '"active":0') || status=1
	check "timed-out run left no active session" "$status" "$detail"
	return 0
}

test_wrong_password_fails_without_leak() {
	local env status=0
	env="\"alpha\":{$(environment_json "$ALPHA_PORT" QA_BETA ',"viewports":["desktop"],"timeoutMs":2000')}"
	write_journey wrong-password.json "$env" '[{"type":"visible","selector":"#title"}]'
	run_journey wrong-password.json alpha
	[[ "$RUN_EXIT" -ne 0 && "$RUN_OUTPUT" == *'"signIn":{"status":"failed"'* ]] || status=1
	check "rejected credentials fail sign-in without retrying" "$status" "exit=${RUN_EXIT} ${RUN_OUTPUT}"
	return 0
}

test_no_secret_in_output() {
	local log="${JOURNEY_TEST_TEMP_DIR}/all-output.log"
	local secret status=0
	for secret in "$ALPHA_PASSWORD_VALUE" "$BETA_PASSWORD_VALUE" "sid="; do
		if grep -qF -- "$secret" "$log"; then
			status=1
		fi
	done
	check "no credential or cookie value appears in any report or error output" "$status" "secret found in output log"
	return 0
}

browser_runtime_available() {
	node "$PLAYWRIGHT_RUNTIME" check >/dev/null 2>&1 || return 1
	node "$PLAYWRIGHT_RUNTIME" browser-executable >/dev/null 2>&1 || return 1
	command -v curl >/dev/null 2>&1 || return 1
	return 0
}

run_browser_tests() {
	if ! browser_runtime_available; then
		printf 'SKIP browser journey tests (Playwright runtime, browser or curl unavailable)\n'
		TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
		return 0
	fi
	write_fixture_server
	start_fixture alpha "$ALPHA_USER_VALUE" "$ALPHA_PASSWORD_VALUE"
	ALPHA_PORT="$STARTED_PORT"
	start_fixture beta "$BETA_USER_VALUE" "$BETA_PASSWORD_VALUE"
	BETA_PORT="$STARTED_PORT"
	: >"${JOURNEY_TEST_TEMP_DIR}/all-output.log"

	local test_fn
	for test_fn in test_alpha_journey_passes test_beta_journey_isolated test_non_api_write_blocked \
		test_wrong_origin_navigation_blocked test_off_origin_auth_redirect_blocked \
		test_timeout_still_signs_out test_wrong_password_fails_without_leak; do
		reset_fixtures
		"$test_fn"
	done
	test_no_secret_in_output
	return 0
}

main() {
	JOURNEY_TEST_TEMP_DIR=$(mktemp -d)
	trap cleanup EXIT
	run_validation_tests
	run_browser_tests
	printf 'Results: %s passed, %s failed, %s skipped\n' "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
