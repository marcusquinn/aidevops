#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by the existing hermetic gh shim harness after legacy-path coverage.

printf '\nTest 27: shared raw transport controls and response-owned quota\n'
for library in gh-transport-controls.sh gh-transport-governor.py gh_transport_budget.py gh_transport_observation.py gh_transport_schema.py gh_transport_identity.py gh_transport_reconcile.py gh_transport_recovery.py gh_transport_status.py gh_transport_capacity.py shared-gh-secondary-cooldown.sh shared-gh-primary-cooldown.sh; do
	cp "${REPO_DIR}/.agents/scripts/${library}" "${TMP}/scripts/${library}"
done
mkdir -p "${TMP}/governor/tmp"
export AIDEVOPS_GH_TRANSPORT_STATE_DIR="${TMP}/governor/state"
export AIDEVOPS_TEMP_DIR="${TMP}/governor/tmp"
# Quota-owner discovery is separate coverage; keep this response-cost fixture
# deterministic without an extra authenticated-login probe.
export AIDEVOPS_GH_QUOTA_OWNER=fixture-owner
export AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${TMP}/governor/cooldown.json"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE="${TMP}/governor/events.jsonl"
export AIDEVOPS_GH_API_LOG="${TMP}/governor/api.tsv"
export AIDEVOPS_GH_READ_RAMP_ENABLED=0
export AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1
unset AIDEVOPS_GH_TRANSPORT_GOVERNOR_DISABLE AIDEVOPS_GH_EXACT_QUOTA_CAPTURE GH_DEBUG
_governor_reset=$(($(date +%s) + 3600))
printf '{"expires_at":%s}\n' "$_governor_reset" >"$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE"
_reset_log
_governor_rc=0
"$SHIM_RUN" pr view 42 --repo owner/repo --json number >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 75 && ! -s "$STUB_GH_CALL_LOG" ]]; then
	_pass "raw native reads stop during the shared cooldown without a request"
else
	_fail "raw native reads stop during the shared cooldown without a request"
fi
if "$SHIM_RUN" --version >/dev/null 2>/dev/null; then
	_pass "local-only commands remain usable during cooldown"
else
	_fail "local-only commands remain usable during cooldown"
fi
rm -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE"

export STUB_TRANSPORT_RESPONSE_FILE="${TMP}/governor/response"
printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4999\r\nX-Ratelimit-Used: 1\r\nX-Ratelimit-Reset: %s\r\n\r\n{"fixture":true}\n' "$_governor_reset" >"$STUB_TRANSPORT_RESPONSE_FILE"
_reset_log
_governor_output=$("$SHIM_RUN" api user)
if [[ "$_governor_output" == '{"fixture":true}' && "$(_read_attempt_quota "$AIDEVOPS_GH_API_LOG")" == 1 && "$(_read_last_attempt_field "$AIDEVOPS_GH_API_LOG" 15)" == 200 ]]; then
	_pass "REST transport strips only injected headers and records actual response cost/status"
else
	_fail "REST transport strips only injected headers and records actual response cost/status"
fi
# t18804: the default governor row must carry the quota-series keys that the
# aggregate replay requires (credential digest, reset epoch, cumulative used).
_governor_fingerprint=$(_read_last_attempt_field "$AIDEVOPS_GH_API_LOG" 20)
if [[ "$_governor_fingerprint" =~ ^[a-f0-9]{64}$ &&
	"$(_read_last_attempt_field "$AIDEVOPS_GH_API_LOG" 21)" == "$_governor_reset" &&
	"$(_read_last_attempt_field "$AIDEVOPS_GH_API_LOG" 22)" == 1 &&
	"$(_read_last_attempt_field "$AIDEVOPS_GH_API_LOG" 7)" == 4999 ]]; then
	_pass "REST transport records credential digest, reset epoch and used counter"
else
	_fail "REST transport records credential digest, reset epoch and used counter" \
		"fields 20-22: ${_governor_fingerprint:-<empty>} $(_read_last_attempt_field "$AIDEVOPS_GH_API_LOG" 21) $(_read_last_attempt_field "$AIDEVOPS_GH_API_LOG" 22)"
fi
if [[ "$(wc -l <"$STUB_GH_CALL_LOG" | tr -d ' ')" -eq 1 ]]; then
	_pass "quota observation does not probe rate_limit or repeat the REST request"
else
	_fail "quota observation does not probe rate_limit or repeat the REST request"
fi
"$SHIM_RUN" api user --include >"${TMP}/governor/included"
if cmp -s "$STUB_TRANSPORT_RESPONSE_FILE" "${TMP}/governor/included"; then
	_pass "explicit included-response output remains byte-for-byte native"
else
	_fail "explicit included-response output remains byte-for-byte native"
fi

_reset_log
_governor_rc=0
STUB_TRANSPORT_RC=125 "$SHIM_RUN" api user >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 125 && "$(wc -l <"$STUB_GH_CALL_LOG" | tr -d ' ')" -eq 1 ]]; then
	_pass "native exit 125 is preserved without invoking fallback after execution"
else
	_fail "native exit 125 is preserved without invoking fallback after execution"
fi

printf 'HTTP/2.0 304 Not Modified\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4999\r\nX-Ratelimit-Reset: %s\r\n\r\n' "$_governor_reset" >"$STUB_TRANSPORT_RESPONSE_FILE"
_governor_rc=0
STUB_TRANSPORT_RC=1 "$SHIM_RUN" api user -H 'If-None-Match: "fixture"' >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 1 && "$(_read_attempt_quota "$AIDEVOPS_GH_API_LOG")" == 0 ]]; then
	_pass "response-owned conditional zero cost preserves native exit status"
else
	_fail "response-owned conditional zero cost preserves native exit status"
fi

printf 'not an included HTTP response\n' >"$STUB_TRANSPORT_RESPONSE_FILE"
_governor_rc=0
_governor_output=$("$SHIM_RUN" api user 2>/dev/null) || _governor_rc=$?
if [[ "$_governor_rc" -ne 0 && -z "$_governor_output" ]]; then
	_pass "unknown header framing cannot become successful application data"
else
	_fail "unknown header framing cannot become successful application data"
fi

printf 'HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: %s\r\n\r\n{}\n' "$_governor_reset" >"$STUB_TRANSPORT_RESPONSE_FILE"
STUB_TRANSPORT_RC=1 "$SHIM_RUN" api user >/dev/null 2>/dev/null || true
_reset_log
_governor_rc=0
"$SHIM_RUN" api repos/owner/repo >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 75 && ! -s "$STUB_GH_CALL_LOG" ]]; then
	_pass "authoritative exhaustion suppresses the next raw request locally"
else
	_fail "authoritative exhaustion suppresses the next raw request locally"
fi

_reset_log
printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Resource: search\r\nX-Ratelimit-Limit: 30\r\nX-Ratelimit-Remaining: 29\r\nX-Ratelimit-Reset: %s\r\n\r\n{"items":[]}\n' "$_governor_reset" >"$STUB_TRANSPORT_RESPONSE_FILE"
if "$SHIM_RUN" api 'search/issues?q=fixture' >/dev/null && [[ -s "$STUB_GH_CALL_LOG" && ! -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]]; then
	_pass "core exhaustion leaves available search quota usable through the real shim"
else
	_fail "core exhaustion incorrectly blocks unrelated search capacity"
fi
if "$SHIM_RUN" api rate_limit >/dev/null; then
	_pass "primary exhaustion does not suppress quota-status recovery"
else
	_fail "primary exhaustion suppresses quota-status recovery"
fi

# Exact capture owns multi-frame native attempts. The normal final-response
# adapter must never take that route away from an explicitly metered window.
# Load the same accounting/transport dependencies as the real shim before
# exercising the transport function directly in this shell.
# shellcheck source=/dev/null
source "${TMP}/scripts/gh-api-instrument.sh"
# shellcheck source=/dev/null
source "${TMP}/scripts/gh-quota-attribution-lib.sh"
# shellcheck source=/dev/null
source "${TMP}/scripts/gh-native-transport-lib.sh"
export AIDEVOPS_GH_LOGICAL_ID=fixture-local-admission
# shellcheck source=/dev/null
source "${TMP}/scripts/gh-transport-controls.sh"

_governor_count_file="${TMP}/governor/calls"
printf '0\n' >"$_governor_count_file"
python3() {
	if [[ "${1:-}" == *gh-transport-governor.py ]]; then
		local governor_calls=""
		governor_calls=$(<"$_governor_count_file")
		governor_calls=$((governor_calls + 1))
		printf '%s\n' "$governor_calls" >"$_governor_count_file"
		local metadata="$2"
		if [[ "$governor_calls" -eq 1 ]]; then
			printf '{"attempted":false,"deferred_by":"local_admission","retry_at":%s,"reason":"fixture quota wait"}\n' "${_governor_retry_at:-1}" >"$metadata"
			printf '[gh-transport] deferred: fixture quota wait\n' >&2
			return 75
		fi
		printf '{"attempted":true,"status":200,"resource":"core","remaining":4999,"reset":%s,"retry_after":null,"cost":1}\n' "$_governor_reset" >"$metadata"
		printf '{"fixture":true}\n'
		return 0
	fi
	command python3 "$@"
}
_governor_rc=0
_governor_output=$(AIDEVOPS_GH_LOCAL_ADMISSION_RETRY_DELAY_SECONDS=0 \
	_gh_transport_run_rest "${TMP}/bin/gh" rest gh_api_rest 0 api user 2>"${TMP}/governor/retry-error") || _governor_rc=$?
_governor_calls=$(<"$_governor_count_file")
if [[ "$_governor_calls" -eq 2 && "$_governor_output" == '{"fixture":true}' && ! -s "${TMP}/governor/retry-error" ]]; then
	_pass "local admission deferral retries once only after attempted=false evidence"
else
	_fail "local admission deferral was not retried safely (rc=${_governor_rc} calls=${_governor_calls} output=${_governor_output:-<empty>})" "$(<"${TMP}/governor/retry-error")"
fi

printf '0\n' >"$_governor_count_file"
_governor_retry_at=$(($(date +%s) + 120))
_governor_rc=0
_gh_transport_run_rest "${TMP}/bin/gh" rest gh_api_rest 0 api user \
	>/dev/null 2>"${TMP}/governor/deferred-error" || _governor_rc=$?
if [[ "$_governor_rc" -eq 75 && "$(<"$_governor_count_file")" -eq 1 ]] &&
	grep -q "attempted=false deferred_by=local_admission retry_at=${_governor_retry_at}" "${TMP}/governor/deferred-error"; then
	_pass "future admission deadline preserves explicit evidence without an early retry"
else
	_fail "future admission deadline was retried early or lost its evidence"
fi
unset -f python3
unset _governor_retry_at

# A corrupt or incompatible local transport state must not prevent a GET from
# reaching native gh. The governor records attempted=false before state setup,
# so the shim can safely fail open without duplicating a remote request.
unset STUB_TRANSPORT_RESPONSE_FILE
printf '0\n' >"$_governor_count_file"
python3() {
	if [[ "${1:-}" == *gh-transport-governor.py ]]; then
		local governor_calls=""
		local metadata="$2"
		governor_calls=$(<"$_governor_count_file")
		governor_calls=$((governor_calls + 1))
		printf '%s\n' "$governor_calls" >"$_governor_count_file"
		printf '{"attempted":false,"deferred_by":"local_state","reason":"ValueError"}\n' >"$metadata"
		return 75
	fi
	command python3 "$@"
}
_governor_rc=0
_governor_output=$(_gh_transport_run_rest "${TMP}/bin/gh" rest gh_api_rest 0 api user \
	2>"${TMP}/governor/local-state-error") || _governor_rc=$?
if [[ "$_governor_rc" -eq 0 && "$_governor_output" == "managed" &&
	"$(<"$_governor_count_file")" -eq 1 &&
	! -s "${TMP}/governor/local-state-error" ]]; then
	_pass "local transport state failure falls back to one native read"
else
	_fail "local transport state failure did not preserve native read behaviour" \
		"rc=${_governor_rc} output=${_governor_output:-<empty>} governor_calls=$(<"$_governor_count_file")"
fi
unset -f python3

_governor_rc=0
AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 _gh_transport_run_rest \
	"${TMP}/bin/gh" rest gh_api_rest 0 api user >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 125 && "$_GHGT_HANDLED" -eq 0 ]]; then
	_pass "exact multi-response capture retains transport ownership"
else
	_fail "normal REST adapter intercepted exact transport capture"
fi

# shellcheck source=/dev/null
source "${TMP}/scripts/gh-native-transport-lib.sh"
if [[ "$(_shim_classify_endpoint search issues)" == search-rest && "$(_shim_classify_endpoint api graphql)" == graphql ]]; then
	_pass "native search uses the REST search resource, not the GraphQL pool"
else
	_fail "native search quota family is misclassified"
fi

# Isolated native responses let the real shim/governor exercise both pools.
cp "${TMP}/bin/gh" "${TMP}/bin/gh.identity-saved"
cat >"${TMP}/bin/gh" <<'IDENTITY_GH'
#!/usr/bin/env bash
if [[ "${1:-}" == auth && "${2:-}" == token ]]; then
	printf '%s\n' 'fixture-token'
	exit 0
fi
printf '%s\n' "$*" >>"$STUB_GH_CALL_LOG"
if [[ "${2:-}" == graphql ]]; then
	printf '%s\n' "$STUB_IDENTITY_VIEWER"
	exit "${STUB_IDENTITY_GRAPHQL_RC:-0}"
fi
printf 'HTTP/2.0 %s Fixture\r\nX-Ratelimit-Resource: core\r\nX-Ratelimit-Remaining: 4999\r\n\r\n{"login":"rest-user","id":1,"name":null}\n' "${STUB_IDENTITY_STATUS:-200}"
exit "${STUB_IDENTITY_REST_RC:-0}"
IDENTITY_GH
cp "${TMP}/scripts/gh-transport-governor.py" "${TMP}/scripts/gh-transport-governor.py.saved"
cat >"${TMP}/scripts/gh-transport-governor.py" <<'IDENTITY_GOVERNOR'
import json, os, runpy, sys, time
if os.environ.get("STUB_IDENTITY_DEFER") == "1" and sys.argv[4] != "graphql":
    with open(sys.argv[1], "w") as stream:
        json.dump({"attempted": False, "deferred_by": "local_admission",
                   "retry_at": time.time() + 120}, stream)
    print("fixture identity deferral", file=sys.stderr)
    sys.exit(75)
runpy.run_path(sys.argv[0] + ".saved", run_name="__main__")
IDENTITY_GOVERNOR
export STUB_IDENTITY_VIEWER='{"data":{"viewer":{"login":"live-user[bot]","databaseId":42,"name":"Live User"}}}'
# Do not inherit the deliberately exhausted REST budget from the earlier cases.
export AIDEVOPS_GH_TRANSPORT_STATE_DIR="${TMP}/governor/identity-state"
unset STUB_TRANSPORT_RESPONSE_FILE
rm -f "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-core"
for _identity_mode in admission cooldown; do
	export STUB_IDENTITY_DEFER=0
	if [[ "$_identity_mode" == admission ]]; then
		export STUB_IDENTITY_DEFER=1
	else
		printf '{"expires_at":%s}\n' "$_governor_reset" >"${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-core"
	fi
	for _identity_endpoint in user /user; do
		for _identity_selector in '.login // empty' .login .id .name; do
			for _identity_flag in --jq -q; do
				_reset_log
				_governor_rc=0
				_governor_output=$("$SHIM_RUN" api "$_identity_endpoint" "$_identity_flag" "$_identity_selector" 2>/dev/null) || _governor_rc=$?
				_identity_expected='live-user[bot]'
				case "$_identity_selector" in .id) _identity_expected=42 ;; .name) _identity_expected='Live User' ;; esac
				if [[ "$_governor_rc" -eq 0 && "$_governor_output" == "$_identity_expected" && "$(wc -l <"$STUB_GH_CALL_LOG")" -eq 1 ]]; then
					_pass "identity $_identity_mode $_identity_endpoint $_identity_flag $_identity_selector uses one live GraphQL read"
				else
					_fail "identity fallback $_identity_mode $_identity_endpoint $_identity_selector (rc=$_governor_rc output=$_governor_output)"
				fi
			done
		done
	done
	_governor_output=$("$SHIM_RUN" api user 2>/dev/null)
	if [[ "$(jq -r '.login' <<<"$_governor_output")" == 'live-user[bot]' && "$(jq -r '.id' <<<"$_governor_output")" == 42 ]]; then
		_pass "identity $_identity_mode synthesizes the unfiltered REST identity shape"
	else
		_fail "identity $_identity_mode lost synthesized fields"
	fi
	for _identity_selector in .email '.login, .email' '.["email"]' ''; do
		_reset_log
		_governor_rc=0
		"$SHIM_RUN" api user --jq "$_identity_selector" >"${TMP}/governor/identity-out" 2>"${TMP}/governor/identity-error" || _governor_rc=$?
		if [[ "$_governor_rc" -eq 75 && ! -s "$STUB_GH_CALL_LOG" && ! -s "${TMP}/governor/identity-out" && -s "${TMP}/governor/identity-error" ]]; then
			_pass "identity $_identity_mode unsupported selector preserves failure and diagnostics"
		else
			_fail "identity $_identity_mode unsupported selector was masked"
		fi
	done
	for _identity_bad_viewer in '{"data":{"viewer":{"login":"bad login","databaseId":42}}}' '{"data":{"viewer":null}}' '{"errors":[{"message":"denied"}]}'; do
		_governor_rc=0
		STUB_IDENTITY_VIEWER="$_identity_bad_viewer" "$SHIM_RUN" api user --jq .login >/dev/null 2>/dev/null || _governor_rc=$?
		[[ "$_governor_rc" -eq 75 ]] && _pass "invalid viewer preserves $_identity_mode failure" || _fail "invalid viewer accepted"
	done
	_governor_rc=0
	STUB_IDENTITY_GRAPHQL_RC=1 "$SHIM_RUN" api user -q .login >/dev/null 2>/dev/null || _governor_rc=$?
	[[ "$_governor_rc" -eq 75 ]] && _pass "GraphQL failure preserves original $_identity_mode status" || _fail "GraphQL failure masked"
done
rm -f "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-core"
export STUB_IDENTITY_DEFER=0
for _identity_status in 200 401 403 404; do
	_reset_log
	_governor_rc=0
	_identity_rc=1
	[[ "$_identity_status" != 200 ]] || _identity_rc=0
	STUB_IDENTITY_STATUS="$_identity_status" STUB_IDENTITY_REST_RC="$_identity_rc" \
		"$SHIM_RUN" api user --jq .login >/dev/null 2>/dev/null || _governor_rc=$?
	if [[ "$_governor_rc" -eq "$_identity_rc" && "$(wc -l <"$STUB_GH_CALL_LOG")" -eq 1 ]] && ! grep -q graphql "$STUB_GH_CALL_LOG"; then
		_pass "REST HTTP $_identity_status remains authoritative with one REST attempt"
	else
		_fail "REST HTTP $_identity_status incorrectly triggered identity fallback"
	fi
done
_reset_log
_governor_rc=0
STUB_IDENTITY_STATUS=401 STUB_IDENTITY_REST_RC=75 "$SHIM_RUN" api user -q .login >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 75 && "$(wc -l <"$STUB_GH_CALL_LOG")" -eq 1 ]] && ! grep -q graphql "$STUB_GH_CALL_LOG"; then
	_pass "exit 75 after an HTTP attempt cannot trigger identity fallback"
else
	_fail "exit 75 was mistaken for no-attempt evidence"
fi
printf '{"expires_at":%s}\n' "$_governor_reset" >"$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE"
_reset_log
_governor_rc=0
"$SHIM_RUN" api user -q .login >/dev/null 2>/dev/null || _governor_rc=$?
if [[ "$_governor_rc" -eq 75 && ! -s "$STUB_GH_CALL_LOG" ]]; then
	_pass "global secondary cooldown still blocks identity reads across both pools"
else
	_fail "identity fallback bypassed the global secondary cooldown"
fi
rm -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE"
mv "${TMP}/bin/gh.identity-saved" "${TMP}/bin/gh"
mv "${TMP}/scripts/gh-transport-governor.py.saved" "${TMP}/scripts/gh-transport-governor.py"
unset STUB_IDENTITY_DEFER STUB_IDENTITY_VIEWER

return 0
