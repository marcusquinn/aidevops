#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
#
# GH#34892: env-only credential consumers fall back to gopass aidevops/NAME.
# Isolated HOME plus throwaway gopass/curl doubles (the test-secret-helper.sh
# approach); every value below is a fake fixture.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SCRIPTS="${SCRIPT_DIR}/.."
ORIG_PATH="$PATH"

TESTS_RUN=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$message" ]] && printf '       %s\n' "$message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	mkdir -p "$TEST_DIR/bin" "$TEST_DIR/store" "$TEST_DIR/home/.config/aidevops"
	# gopass double: entries are files under $AIDEVOPS_TEST_DIR/store; logs
	# subcommand and path only, and always writes stderr noise.
	cat >"$TEST_DIR/bin/gopass" <<'EOF'
#!/usr/bin/env bash
printf 'gopass-stderr-noise\n' >&2
cmd="${1:-}"
shift || true
case "$cmd" in
ls)
	printf 'ls\n' >>"${AIDEVOPS_TEST_DIR}/gopass_calls"
	for entry in "${AIDEVOPS_TEST_DIR}"/store/*; do
		[[ -f "$entry" ]] && printf 'aidevops/%s\n' "${entry##*/}"
	done
	exit 0
	;;
show)
	[[ "${1:-}" == "-o" ]] && shift
	printf 'show %s\n' "${1:-}" >>"${AIDEVOPS_TEST_DIR}/gopass_calls"
	entry="${AIDEVOPS_TEST_DIR}/store/${1#aidevops/}"
	[[ -f "$entry" ]] || exit 11
	cat "$entry"
	exit 0
	;;
esac
exit 1
EOF
	# curl double: records argv and explicitly requested stdin separately.
	cat >"$TEST_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${AIDEVOPS_TEST_DIR}/curl_args"
case " $* " in
*' -H @- '*|*' -K - '*) cat >>"${AIDEVOPS_TEST_DIR}/curl_stdin" ;;
esac
case "$*" in
*updown.io*) printf '[]\n200' ;;
*api.ahrefs.com*) printf '{"keywords":[{"keyword":"k","url":"https://example.com/","traffic":1,"volume":10,"position":1,"difficulty":2}],"domain_rating":{"domain_rating":50}}' ;;
esac
exit 0
EOF
	chmod +x "$TEST_DIR/bin/gopass" "$TEST_DIR/bin/curl"
	export AIDEVOPS_TEST_DIR="$TEST_DIR"
	export PATH="$TEST_DIR/bin:$ORIG_PATH"
	return 0
}

teardown() {
	export PATH="$ORIG_PATH"
	[[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
	TEST_DIR=""
	return 0
}

store_gopass() {
	local name="$1"
	local value="$2"
	printf '%s\n' "$value" >"$TEST_DIR/store/$name"
	return 0
}

store_plaintext() {
	local line="$1"
	printf '%s\n' "$line" >>"$TEST_DIR/home/.config/aidevops/credentials.sh"
	return 0
}

# Run a resolver function in a clean env with the isolated HOME.
resolve_with() {
	local fn="$1"
	shift
	# shellcheck disable=SC2016  # positional args expand in the child bash
	env -i PATH="$PATH" HOME="$TEST_DIR/home" AIDEVOPS_TEST_DIR="$TEST_DIR" "$@" \
		bash -c 'source "$1/secret-resolver.sh"; "$2" "$3"' _ "$SCRIPTS" "$fn" "${RESOLVE_NAME}"
	return $?
}

test_resolver_precedence() {
	setup
	store_gopass DEMO_KEY "gopass-value-1"
	local from_gopass="" from_plain="" from_env=""
	from_gopass=$(RESOLVE_NAME=DEMO_KEY resolve_with aidevops_resolve_secret 2>&1) || true
	store_plaintext 'export DEMO_KEY="plain-value-1"'
	from_plain=$(RESOLVE_NAME=DEMO_KEY resolve_with aidevops_resolve_secret 2>&1) || true
	from_env=$(RESOLVE_NAME=DEMO_KEY resolve_with aidevops_resolve_secret DEMO_KEY=env-value-1 2>&1) || true
	if [[ "$from_gopass" == "gopass-value-1" && "$from_plain" == "plain-value-1" && "$from_env" == "env-value-1" ]]; then
		print_result "resolver order is env, then credentials.sh, then gopass" 0
	else
		print_result "resolver order is env, then credentials.sh, then gopass" 1 "got gopass/plain/env lengths ${#from_gopass}/${#from_plain}/${#from_env}"
	fi
	teardown
	return 0
}

test_resolver_missing_is_silent() {
	setup
	local output="" rc=0
	output=$(RESOLVE_NAME=ABSENT_KEY resolve_with aidevops_resolve_secret 2>&1) || rc=$?
	local bad_rc=0
	RESOLVE_NAME='BAD;NAME' resolve_with aidevops_resolve_secret >/dev/null 2>&1 || bad_rc=$?
	if [[ "$rc" -eq 1 && -z "$output" && "$bad_rc" -eq 1 ]] && ! grep -q 'BAD' "$TEST_DIR/gopass_calls" 2>/dev/null; then
		print_result "unresolved names fail silently; gopass stderr suppressed; invalid names rejected" 0
	else
		print_result "unresolved names fail silently; gopass stderr suppressed; invalid names rejected" 1 "rc=$rc bad_rc=$bad_rc output_len=${#output}"
	fi
	teardown
	return 0
}

test_presence_lists_without_decrypting() {
	setup
	store_gopass LISTED_KEY "listed-value-1"
	local listed_rc=0 missing_rc=0
	RESOLVE_NAME=LISTED_KEY resolve_with aidevops_secret_available >/dev/null 2>&1 || listed_rc=$?
	RESOLVE_NAME=MISSING_KEY resolve_with aidevops_secret_available >/dev/null 2>&1 || missing_rc=$?
	if [[ "$listed_rc" -eq 0 && "$missing_rc" -eq 1 ]] && ! grep -q '^show' "$TEST_DIR/gopass_calls"; then
		print_result "presence check reports gopass-listed names without decrypting" 0
	else
		print_result "presence check reports gopass-listed names without decrypting" 1 "listed=$listed_rc missing=$missing_rc"
	fi
	teardown
	return 0
}

test_updown_uses_gopass() {
	setup
	store_gopass UPDOWN_API_KEY "updown-gopass-value"
	local rc=0
	env -u UPDOWN_API_KEY HOME="$TEST_DIR/home" bash "$SCRIPTS/updown-helper.sh" json >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -Fxq 'X-API-KEY: updown-gopass-value' "$TEST_DIR/curl_args"; then
		print_result "updown-helper.sh resolves UPDOWN_API_KEY from gopass" 0
	else
		print_result "updown-helper.sh resolves UPDOWN_API_KEY from gopass" 1 "rc=$rc"
	fi
	teardown
	return 0
}

test_seo_export_ahrefs_uses_gopass() {
	setup
	store_gopass AHREFS_API_KEY "ahrefs-gopass-value"
	local rc=0 output=""
	output=$(env -u AHREFS_API_KEY HOME="$TEST_DIR/home" bash "$SCRIPTS/seo-export-ahrefs.sh" example.com 2>&1) || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -Fxq 'Authorization: Bearer ahrefs-gopass-value' "$TEST_DIR/curl_args" &&
		[[ "$output" != *ahrefs-gopass-value* ]]; then
		print_result "seo-export-ahrefs.sh resolves AHREFS_API_KEY from gopass" 0
	else
		print_result "seo-export-ahrefs.sh resolves AHREFS_API_KEY from gopass" 1 "rc=$rc"
	fi
	teardown
	return 0
}

test_keyword_research_ahrefs_uses_gopass() {
	setup
	store_gopass AHREFS_API_KEY "kr-ahrefs-gopass-value"
	local rc=0
	# shellcheck disable=SC2016  # positional args expand in the child bash
	env -u AHREFS_API_KEY HOME="$TEST_DIR/home" bash -c \
		'source "$1/shared-constants.sh"; source "$1/keyword-research-helper-providers.sh"; ahrefs_domain_rating example.com' \
		_ "$SCRIPTS" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -Fxq 'Authorization: Bearer kr-ahrefs-gopass-value' "$TEST_DIR/curl_args"; then
		print_result "keyword-research Ahrefs provider resolves AHREFS_API_KEY from gopass" 0
	else
		print_result "keyword-research Ahrefs provider resolves AHREFS_API_KEY from gopass" 1 "rc=$rc"
	fi
	teardown
	return 0
}

# Exercise every public credential consumer in a genuinely empty environment.
run_webmaster_requests() {
	# shellcheck disable=SC2016  # positional args expand in the child bash
	env -i PATH="$PATH" HOME="$TEST_DIR/home" AIDEVOPS_TEST_DIR="$TEST_DIR" "$@" bash -euc '
		source "$1/shared-constants.sh"
		source "$1/keyword-research-helper-webmaster.sh"
		gsc_request sites/example/searchAnalytics/query "{}"
		gsc_list_sites
		bing_request GetQueryStats "https://example.com/?a=1&b=2"
		bing_keyword "https://example.com/" "a & b" 2026-10-01 2026-10-17
		bing_related_keywords "https://example.com/" "a & b" 2026-10-01 2026-10-17
		bing_page_query_stats "https://example.com/" "https://example.com/a?b=c&d=e"
		bing_list_sites
	' _ "$SCRIPTS"
	return $?
}

test_webmaster_credentials() {
	setup
	store_gopass GSC_ACCESS_TOKEN "gsc-gopass-value"
	store_gopass BING_WEBMASTER_API_KEY "bing-gopass-value"
	local rc=0
	run_webmaster_requests >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 0 ]] &&
		[[ $(grep -c '^Authorization: Bearer gsc-gopass-value$' "$TEST_DIR/curl_stdin") -eq 2 ]] &&
		[[ $(grep -c '^data-urlencode = "apikey=bing-gopass-value"$' "$TEST_DIR/curl_stdin") -eq 5 ]] &&
		! grep -Eq 'gsc-gopass-value|bing-gopass-value|apikey=' "$TEST_DIR/curl_args" &&
		grep -Fxq 'query=a & b' "$TEST_DIR/curl_args" &&
		grep -Fxq 'siteUrl=https://example.com/?a=1&b=2' "$TEST_DIR/curl_args" &&
		grep -Fxq 'page=https://example.com/a?b=c&d=e' "$TEST_DIR/curl_args"; then
		print_result "all webmaster consumers resolve gopass credentials through stdin, never argv" 0
	else
		print_result "all webmaster consumers resolve gopass credentials through stdin, never argv" 1 "rc=$rc"
	fi
	store_plaintext 'export GSC_ACCESS_TOKEN="gsc-plain-value"'
	store_plaintext 'export BING_WEBMASTER_API_KEY="bing-plain-value"'
	: >"$TEST_DIR/curl_stdin"
	rc=0
	run_webmaster_requests >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -q 'gsc-plain-value' "$TEST_DIR/curl_stdin" &&
		grep -q 'bing-plain-value' "$TEST_DIR/curl_stdin" && ! grep -q 'gopass-value' "$TEST_DIR/curl_stdin"; then
		print_result "webmaster credentials.sh values precede gopass" 0
	else
		print_result "webmaster credentials.sh values precede gopass" 1 "rc=$rc"
	fi
	: >"$TEST_DIR/curl_stdin"
	rc=0
	run_webmaster_requests GSC_ACCESS_TOKEN=gsc-env-value BING_WEBMASTER_API_KEY=bing-env-value >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -q 'gsc-env-value' "$TEST_DIR/curl_stdin" &&
		grep -q 'bing-env-value' "$TEST_DIR/curl_stdin" && ! grep -Eq 'plain-value|gopass-value' "$TEST_DIR/curl_stdin"; then
		print_result "webmaster environment values precede credentials.sh and gopass" 0
	else
		print_result "webmaster environment values precede credentials.sh and gopass" 1 "rc=$rc"
	fi
	teardown
	return 0
}

test_webmaster_gcloud_and_missing() {
	setup
	cat >"$TEST_DIR/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == 'auth application-default print-access-token' ]] || exit 1
printf '%s\n' 'gsc-gcloud-value'
EOF
	chmod +x "$TEST_DIR/bin/gcloud"
	: >"$TEST_DIR/service-account.json"
	store_gopass BING_WEBMASTER_API_KEY "bing-gopass-value"
	local rc=0
	run_webmaster_requests GOOGLE_APPLICATION_CREDENTIALS="$TEST_DIR/service-account.json" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 0 ]] && [[ $(grep -c '^Authorization: Bearer gsc-gcloud-value$' "$TEST_DIR/curl_stdin") -eq 2 ]] &&
		! grep -q 'gsc-gcloud-value' "$TEST_DIR/curl_args"; then
		print_result "GSC service-account gcloud fallback keeps token out of argv" 0
	else
		print_result "GSC service-account gcloud fallback keeps token out of argv" 1 "rc=$rc"
	fi
	teardown
	setup
	# shellcheck disable=SC2016  # positional args expand in the child bash
	env -i PATH="$PATH" HOME="$TEST_DIR/home" AIDEVOPS_TEST_DIR="$TEST_DIR" bash -euc '
		source "$1/shared-constants.sh"
		source "$1/keyword-research-helper-webmaster.sh"
		if gsc_request sites "{}"; then exit 1; fi
		if gsc_list_sites; then exit 1; fi
		if bing_request GetQueryStats example; then exit 1; fi
		if bing_keyword example query start end; then exit 1; fi
		if bing_related_keywords example query start end; then exit 1; fi
		if bing_page_query_stats example page; then exit 1; fi
		if bing_list_sites; then exit 1; fi
	' _ "$SCRIPTS" >"$TEST_DIR/errors" 2>&1 || rc=$?
	if [[ "$rc" -eq 0 && ! -f "$TEST_DIR/curl_args" ]] &&
		grep -q 'aidevops secret set GSC_ACCESS_TOKEN' "$TEST_DIR/errors" &&
		grep -q 'aidevops secret set BING_WEBMASTER_API_KEY' "$TEST_DIR/errors"; then
		print_result "missing webmaster credentials fail with secret-set hints and no curl request" 0
	else
		print_result "missing webmaster credentials fail with secret-set hints and no curl request" 1 "rc=$rc"
	fi
	teardown
	return 0
}

test_node_resolver_and_higgsfield_client() {
	setup
	command -v node >/dev/null 2>&1 || {
		print_result "Node resolver (skipped: node unavailable)" 0
		teardown
		return 0
	}
	store_gopass HF_API_KEY "hf-gopass-key"
	store_gopass HF_API_SECRET "hf-gopass-secret"
	store_gopass HIGGSFIELD_USER "hf-gopass-user"
	store_gopass HIGGSFIELD_PASS "hf-gopass-pass"
	store_plaintext 'export HIGGSFIELD_USER="hf-plain-user"'
	local output="" rc=0
	output=$(env -u HF_API_KEY -u HF_API_SECRET -u HIGGSFIELD_USER -u HIGGSFIELD_PASS \
		HOME="$TEST_DIR/home" HIGGSFIELD_PASS="hf-env-pass" node --input-type=module -e '
const { loadApiCredentials } = await import(process.argv[1] + "/higgsfield/higgsfield-api-client.mjs");
const { resolveSecret } = await import(process.argv[1] + "/secret-resolver.mjs");
const api = loadApiCredentials();
console.log([api?.apiKey, api?.apiSecret, resolveSecret("HIGGSFIELD_USER"), resolveSecret("HIGGSFIELD_PASS"), resolveSecret("ABSENT_KEY") || "none"].join(","));
' "$SCRIPTS" 2>&1) || rc=$?
	if [[ "$rc" -eq 0 && "$output" == "hf-gopass-key,hf-gopass-secret,hf-plain-user,hf-env-pass,none" ]]; then
		print_result "Node resolver: Higgsfield API client uses gopass; env and plaintext take precedence" 0
	else
		print_result "Node resolver: Higgsfield API client uses gopass; env and plaintext take precedence" 1 "rc=$rc output=$output"
	fi
	teardown
	return 0
}

test_node_parser_matches_bash_assignments() {
	setup
	command -v node >/dev/null 2>&1 || {
		print_result "Node parser (skipped: node unavailable)" 0
		teardown
		return 0
	}
	store_gopass EMPTY_KEY "empty-gopass-value"
	store_plaintext 'export EMPTY_KEY='
	store_plaintext 'export NEXT_KEY="next-value"'
	store_plaintext 'export HASH_KEY=abc#def # trailing comment'
	# shellcheck disable=SC2016  # literal shell assignments for the fixture
	store_plaintext 'export ESC_KEY=a\$b\ c'
	local -a names=(EMPTY_KEY HASH_KEY ESC_KEY NEXT_KEY)
	local name="" sh_values="" node_values=""
	for name in "${names[@]}"; do
		sh_values+="$(RESOLVE_NAME="$name" resolve_with aidevops_resolve_secret 2>/dev/null || true)|"
	done
	node_values=$(env -i PATH="$PATH" HOME="$TEST_DIR/home" AIDEVOPS_TEST_DIR="$TEST_DIR" node --input-type=module -e '
const { resolveSecret } = await import(process.argv[1] + "/secret-resolver.mjs");
process.stdout.write(process.argv.slice(2).map((n) => resolveSecret(n) + "|").join(""));
' "$SCRIPTS" "${names[@]}" 2>&1) || true
	# shellcheck disable=SC2016  # expected literal values, not expansions
	if [[ "$node_values" == "$sh_values" && "$sh_values" == 'empty-gopass-value|abc#def|a$b c|next-value|' ]]; then
		print_result "Node parser matches bash for empty, mid-word #, and escaped bare values" 0
	else
		print_result "Node parser matches bash for empty, mid-word #, and escaped bare values" 1 "lengths sh=${#sh_values} node=${#node_values}"
	fi
	teardown
	return 0
}

test_onboarding_reports_gopass_names() {
	setup
	store_gopass SERPER_API_KEY "serper-gopass-value"
	local output="" configured=""
	output=$(env -u SERPER_API_KEY HOME="$TEST_DIR/home" bash "$SCRIPTS/onboarding-helper.sh" json 2>/dev/null) || true
	configured=$(jq -r '.seo.serper.configured // empty' <<<"$output" 2>/dev/null) || configured=""
	if [[ "$configured" == "true" && "$output" != *serper-gopass-value* ]] && ! grep -q '^show aidevops/SERPER' "$TEST_DIR/gopass_calls"; then
		print_result "onboarding-helper.sh reports gopass-held names as configured" 0
	else
		print_result "onboarding-helper.sh reports gopass-held names as configured" 1 "configured=$configured"
	fi
	teardown
	return 0
}

main() {
	test_resolver_precedence
	test_resolver_missing_is_silent
	test_presence_lists_without_decrypting
	test_updown_uses_gopass
	test_seo_export_ahrefs_uses_gopass
	test_keyword_research_ahrefs_uses_gopass
	test_webmaster_credentials
	test_webmaster_gcloud_and_missing
	test_node_resolver_and_higgsfield_client
	test_node_parser_matches_bash_assignments
	test_onboarding_reports_gopass_names
	printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
