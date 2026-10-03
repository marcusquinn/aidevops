#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by test-full-loop-release-reconcile.sh; shares its fixtures and state.

cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
args=" $* "
case "${FAKE_RUN_SCHEMA_MODE:-valid}" in
api-failure) exit 1 ;;
empty) exit 0 ;;
object)
	printf '%s\n' '{}'
	exit 0
	;;
malformed)
	printf '%s\n' '{'
	exit 0
	;;
malformed-run)
	printf '%s\n' '{"workflow_runs":[{"id":11,"event":"workflow_dispatch","head_branch":"main","head_sha":"4444444444444444444444444444444444444444","conclusion":null,"created_at":"2026-07-27T00:01:00Z","display_title":"Publish v1.2.3 [3333333333333333333333333333333333333333.4444444444444444444444444444444444444444]"}]}'
	exit 0
	;;
no-runs)
	printf '%s\n' '{"workflow_runs":[]}'
	exit 0
	;;
oversized)
	[[ "$args" == *" --paginate "* && "$args" == *" -F per_page=100 "* ]] || exit 1
	if [[ "$args" == *" -f event=push "* ]]; then
		jq -cn '{workflow_runs:[range(0;1500) | {id:.,event:"push",head_branch:"v0.0.0",
			head_sha:"0000000000000000000000000000000000000000",status:"completed",
			conclusion:"success",created_at:"2026-07-26T00:00:00Z",padding:("x" * 256)}]}'
		printf '%s\n' '{"workflow_runs":[]}'
	else
		jq -cn '{workflow_runs:[range(0;1500) | {id:.,event:"workflow_dispatch",head_branch:"main",
			head_sha:"0000000000000000000000000000000000000000",status:"completed",
			conclusion:"success",created_at:"2026-07-26T00:00:00Z",display_title:"unrelated",
			padding:("x" * 256)}]}'
		printf '%s\n' '{"workflow_runs":[{"id":200,"event":"workflow_dispatch","head_branch":"main","head_sha":"4444444444444444444444444444444444444444","status":"completed","conclusion":"success","created_at":"2026-07-27T00:02:00Z","display_title":"Publish v1.2.3 [3333333333333333333333333333333333333333.4444444444444444444444444444444444444444]"},{"id":201,"event":"workflow_dispatch","head_branch":"main","head_sha":"5555555555555555555555555555555555555555","status":"completed","conclusion":"failure","created_at":"2026-07-27T00:03:00Z","display_title":"Publish v1.2.3 [3333333333333333333333333333333333333333.5555555555555555555555555555555555555555]"}]}'
	fi
	exit 0
	;;
esac
if [[ "$args" == *" workflow run publish-packages.yml "* ]]; then
	printf '%s\n' "$args" >"${FAKE_DISPATCH_LOG:?}"
	exit 0
fi
if [[ "$args" == *" -f event=push "* ]]; then
	if [[ "$args" != *" -f head_sha=3333333333333333333333333333333333333333 "* ]]; then
		printf '%s\n' '{"workflow_runs":[]}'
		exit 0
	fi
	push_branch='v1.2.3'
	[[ "${FAKE_PUSH_BRANCH_MODE:-valid}" == "mismatch" ]] && push_branch='v9.9.9'
	printf '{"workflow_runs":[{"id":10,"event":"push","head_branch":"%s","head_sha":"3333333333333333333333333333333333333333","status":"completed","conclusion":"success","created_at":"2026-07-27T00:00:00Z","display_title":"push","html_url":"push-url"}]}\n' "$push_branch"
	exit 0
fi
if [[ "$args" == *" -f event=workflow_dispatch "* ]]; then
	correlated_title='Publish v1.2.3 [3333333333333333333333333333333333333333.4444444444444444444444444444444444444444]'
	recovery_status='queued'
	recovery_conclusion='null'
	if [[ "${FAKE_RECOVERY_CORRELATION_MODE:-valid}" == "mismatch" ]]; then
		correlated_title='Publish v1.2.3 [3333333333333333333333333333333333333333.5555555555555555555555555555555555555555]'
	fi
	if [[ "${FAKE_RECOVERY_RUN_MODE:-pending}" == "failed" ]]; then
		recovery_status='completed'
		recovery_conclusion='"failure"'
	fi
	printf '{"workflow_runs":[{"id":11,"event":"workflow_dispatch","head_branch":"main","head_sha":"4444444444444444444444444444444444444444","status":"%s","conclusion":%s,"created_at":"2026-07-27T00:01:00Z","display_title":"%s","html_url":"recovery-url"}]}\n' \
		"$recovery_status" "$recovery_conclusion" "$correlated_title"
	exit 0
fi
if [[ "$args" == *"releases/tags/v1.2.3"* ]]; then
	if [[ "${FAKE_RELEASE_DRAFT:-0}" == "1" ]]; then
		printf '%s\n' '{"tag_name":"v1.2.3","draft":true,"published_at":null}'
	else
		printf '%s\n' '{"tag_name":"v1.2.3","draft":false,"published_at":"2026-07-27T00:00:00Z"}'
	fi
	exit 0
fi
if [[ "$args" == *"homebrew-tap/contents/Formula/aidevops.rb"* ]]; then
	printf 'class Aidevops\n  url "https://github.com/test/repo/archive/refs/tags/v1.2.3.tar.gz"\n  sha256 "%s"\nend\n' \
		"${FAKE_FORMULA_SHA:?}"
	if [[ "${FAKE_FORMULA_DRIFT:-0}" == "1" ]]; then
		printf '# unexpected drift\n'
	fi
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" rev-parse refs/tags/v1.2.3^{commit} "* ]]; then
	printf '%s\n' '3333333333333333333333333333333333333333'
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/npm" <<'STUB'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" view aidevops@1.2.3 version dist --json "* ]]; then
	jq -cn --arg version "${FAKE_NPM_VERSION:-1.2.3}" \
		--arg integrity "${FAKE_NPM_INTEGRITY:?}" \
		--arg predicate "${FAKE_NPM_PREDICATE:-https://slsa.dev/provenance/v1}" '
		{version:$version,dist:{integrity:$integrity,shasum:"1111111111111111111111111111111111111111",
		attestations:{url:"registry-attestation",provenance:{predicateType:$predicate}}}}
	'
	exit 0
fi
if [[ "$args" == *" install "* ]]; then
	exit 0
fi
if [[ "$args" == *" audit signatures "* ]]; then
	invalid='[]'
	[[ "${FAKE_NPM_AUDIT_INVALID:-0}" == "1" ]] && invalid='[{"code":"invalid"}]'
	jq -cn --arg version "${FAKE_NPM_VERSION:-1.2.3}" \
		--arg payload "${FAKE_PROVENANCE_PAYLOAD_B64:?}" --argjson invalid "$invalid" '
		{invalid:$invalid,missing:[],verified:[{name:"aidevops",version:$version,
		attestations:{provenance:{predicateType:"https://slsa.dev/provenance/v1"}},
		attestationBundles:[{predicateType:"https://slsa.dev/provenance/v1",
		bundle:{dsseEnvelope:{payload:$payload}}}]}]}
	'
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'tarball-fixture'
STUB
chmod +x "${TEST_ROOT}/bin/gh"
chmod +x "${TEST_ROOT}/bin/git" "${TEST_ROOT}/bin/npm" "${TEST_ROOT}/bin/curl"
PATH="${TEST_ROOT}/bin:${PATH}"
export FAKE_RUN_SCHEMA_MODE=valid
export FAKE_RECOVERY_CORRELATION_MODE=valid
export FAKE_RECOVERY_RUN_MODE=pending
export FAKE_PUSH_BRANCH_MODE=valid
export FAKE_RELEASE_DRAFT=0
export FAKE_NPM_VERSION=1.2.3
FAKE_NPM_DIGEST=$(printf '%0128d' 0)
FAKE_NPM_INTEGRITY=$(node -e \
	'process.stdout.write("sha512-" + Buffer.from(process.argv[1], "hex").toString("base64"))' \
	"$FAKE_NPM_DIGEST")
export FAKE_NPM_DIGEST FAKE_NPM_INTEGRITY
FAKE_FORMULA_SHA=$(printf 'tarball-fixture' | _full_loop_release_sha256_stream)
export FAKE_FORMULA_SHA

set_fake_provenance_payload() {
	local repository="$1"
	local workflow_ref="$2"
	local subject_digest="${3:-$FAKE_NPM_DIGEST}"
	local payload=""

	payload=$(jq -cn --arg repository "$repository" --arg ref "$workflow_ref" \
		--arg digest "$subject_digest" '
		{"_type":"https://in-toto.io/Statement/v1","predicateType":"https://slsa.dev/provenance/v1",
		"subject":[{"name":"pkg:npm/aidevops@1.2.3","digest":{"sha512":$digest}}],
		"predicate":{"buildDefinition":{
		"buildType":"https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1",
		"externalParameters":{"workflow":{"repository":$repository,
		"path":".github/workflows/publish-packages.yml","ref":$ref}}},
		"runDetails":{"builder":{"id":"https://github.com/actions/runner/github-hosted"}}}}
	') || return 1
	FAKE_PROVENANCE_PAYLOAD_B64=$(node -e \
		'process.stdout.write(Buffer.from(process.argv[1]).toString("base64"))' "$payload") || return 1
	export FAKE_PROVENANCE_PAYLOAD_B64
	return 0
}

_full_loop_release_expected_homebrew_formula() {
	local repo="$1"
	local tag_name="$2"
	local expected_sha="$3"
	printf 'class Aidevops\n  url "https://github.com/%s/archive/refs/tags/%s.tar.gz"\n  sha256 "%s"\nend\n' \
		"$repo" "$tag_name" "$expected_sha"
	return 0
}

set_fake_provenance_payload "https://github.com/test/repo" "refs/heads/main"

_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "11" ]]; then
	printf 'FAIL recovery workflow was not correlated by exact release display title\n'
	exit 1
fi
printf 'PASS exact push and recovery workflow runs are correlated durably\n'

export FAKE_RECOVERY_RUN_MODE=failed
recovered_run_output="${TEST_ROOT}/recovered-run-output.txt"
_full_loop_release_inspect_remote test/repo v1.2.3 >"$recovered_run_output" || {
	printf 'FAIL successful exact-tag publication was downgraded by a later transient recovery failure\n'
	exit 1
}
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "10" ]] ||
	! grep -qx 'RECOVERED_WORKFLOW_URL=push-url' "$recovered_run_output" ||
	! grep -qx 'RELEASE_REMOTE_STATE=published' "$recovered_run_output"; then
	printf 'FAIL exact-tag reconciliation did not preserve the prior successful workflow evidence\n'
	exit 1
fi
export FAKE_RECOVERY_RUN_MODE=pending
printf 'PASS later transient recovery failures cannot downgrade verified publication\n'

export FAKE_RECOVERY_CORRELATION_MODE=mismatch
_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "10" ]]; then
	printf 'FAIL recovery workflow with mismatched commit correlation was accepted\n'
	exit 1
fi
export FAKE_RECOVERY_CORRELATION_MODE=valid
printf 'PASS recovery workflow correlation binds tag and workflow commits\n'

export FAKE_RECOVERY_CORRELATION_MODE=mismatch
export FAKE_PUSH_BRANCH_MODE=mismatch
wrong_push_rc=0
_full_loop_release_find_workflow_run test/repo v1.2.3 \
	3333333333333333333333333333333333333333 >/dev/null 2>&1 || wrong_push_rc=$?
if [[ "$wrong_push_rc" -ne 3 ]]; then
	printf 'FAIL push workflow with a mismatched tag ref was accepted\n'
	exit 1
fi
export FAKE_RECOVERY_CORRELATION_MODE=valid
export FAKE_PUSH_BRANCH_MODE=valid
printf 'PASS push workflow correlation binds the exact release tag ref\n'

export FAKE_RUN_SCHEMA_MODE=oversized
_full_loop_release_find_workflow_run test/repo v1.2.3 \
	3333333333333333333333333333333333333333
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "201" ]]; then
	printf 'FAIL newest matching workflow run beyond the first oversized page was not selected\n'
	exit 1
fi
_full_loop_release_find_workflow_run test/repo v1.2.3 \
	3333333333333333333333333333333333333333 successful
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "200" ]]; then
	printf 'FAIL newest successful workflow run beyond the first oversized page was not selected\n'
	exit 1
fi
export FAKE_RUN_SCHEMA_MODE=valid
printf 'PASS oversized paginated workflow histories avoid ARG_MAX and preserve selection\n'

saved_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="${TEST_ROOT}/no-audit-helper"
FAKE_DISPATCH_LOG="${TEST_ROOT}/dispatch-command.log"
export FAKE_DISPATCH_LOG
dispatch_rc=0
_full_loop_release_dispatch_recovery test/repo v1.2.3 >/dev/null || dispatch_rc=$?
SCRIPT_DIR="$saved_script_dir"
if [[ "$dispatch_rc" -ne 8 ]] ||
	! grep -qF ' -f tag=v1.2.3 -f correlation=3333333333333333333333333333333333333333 ' \
		"$FAKE_DISPATCH_LOG"; then
	printf 'FAIL recovery dispatch did not carry the exact verified tag commit\n'
	exit 1
fi
printf 'PASS recovery dispatch carries the exact tag while run identity records the workflow commit\n'

for schema_mode in empty object malformed malformed-run api-failure; do
	export FAKE_RUN_SCHEMA_MODE="$schema_mode"
	schema_rc=0
	_full_loop_release_find_workflow_run test/repo v1.2.3 \
		3333333333333333333333333333333333333333 >/dev/null 2>&1 || schema_rc=$?
	if [[ "$schema_rc" -ne 1 ]]; then
		printf 'FAIL %s workflow-run response did not fail closed\n' "$schema_mode"
		exit 1
	fi
done
export FAKE_RUN_SCHEMA_MODE=no-runs
absent_rc=0
_full_loop_release_find_workflow_run test/repo v1.2.3 \
	3333333333333333333333333333333333333333 >/dev/null 2>&1 || absent_rc=$?
if [[ "$absent_rc" -ne 3 ]]; then
	printf 'FAIL valid empty workflow-run arrays were not classified as absent\n'
	exit 1
fi
export FAKE_RUN_SCHEMA_MODE=valid
printf 'PASS workflow-run API and schema uncertainty fail closed\n'

_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333

_full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3 || {
	printf 'FAIL valid npm provenance did not verify\n'
	exit 1
}
if [[ "$_FULL_LOOP_RELEASE_NPM_INTEGRITY" != "$FAKE_NPM_INTEGRITY" ]]; then
	printf 'FAIL npm provenance verification omitted exact package integrity\n'
	exit 1
fi
set_fake_provenance_payload "https://github.com/attacker/repo" "refs/heads/main"
if _full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3; then
	printf 'FAIL foreign npm provenance repository was accepted\n'
	exit 1
fi
set_fake_provenance_payload "https://github.com/test/repo" "refs/heads/main"
FAKE_NPM_AUDIT_INVALID=1
export FAKE_NPM_AUDIT_INVALID
if _full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3; then
	printf 'FAIL invalid npm provenance signature was accepted\n'
	exit 1
fi
FAKE_NPM_AUDIT_INVALID=0
export FAKE_NPM_AUDIT_INVALID
set_fake_provenance_payload "https://github.com/test/repo" "refs/tags/v1.2.3"
if ! _full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3; then
	printf 'FAIL recovery rejected an exact package published by the original tag run\n'
	exit 1
fi
set_fake_provenance_payload "https://github.com/test/repo" "refs/heads/main"
printf 'PASS npm package integrity and signed workflow provenance are bound exactly\n'
printf 'PASS recovery accepts immutable npm provenance from tag or main publication\n'

channel_error_file="${TEST_ROOT}/channel-errors.txt"
channel_output=$(_full_loop_release_verify_channels test/repo v1.2.3 2>"$channel_error_file") || {
	printf 'FAIL exact published channels did not converge\n'
	exit 1
}
if [[ -s "$channel_error_file" ]]; then
	printf 'FAIL published channel verification emitted cleanup errors\n'
	exit 1
fi
if [[ "$channel_output" != *"HOMEBREW_SHA256=${FAKE_FORMULA_SHA}"* ]]; then
	printf 'FAIL channel verification omitted the exact Homebrew digest\n'
	exit 1
fi
FAKE_RELEASE_DRAFT=1
export FAKE_RELEASE_DRAFT
if _full_loop_release_verify_channels test/repo v1.2.3 >/dev/null 2>&1; then
	printf 'FAIL draft GitHub release satisfied channel convergence\n'
	exit 1
fi
FAKE_RELEASE_DRAFT=0
FAKE_FORMULA_SHA=0000000000000000000000000000000000000000000000000000000000000000
export FAKE_RELEASE_DRAFT FAKE_FORMULA_SHA
if _full_loop_release_verify_channels test/repo v1.2.3 >/dev/null 2>&1; then
	printf 'FAIL mismatched Homebrew digest satisfied channel convergence\n'
	exit 1
fi
FAKE_FORMULA_SHA=$(printf 'tarball-fixture' | _full_loop_release_sha256_stream)
export FAKE_FORMULA_SHA
FAKE_FORMULA_DRIFT=1
export FAKE_FORMULA_DRIFT
if _full_loop_release_verify_channels test/repo v1.2.3 >/dev/null 2>&1; then
	printf 'FAIL drifted Homebrew formula satisfied exact channel convergence\n'
	exit 1
fi
FAKE_FORMULA_DRIFT=0
export FAKE_FORMULA_DRIFT
printf 'PASS published channel verification binds release, package, formula, and digest\n'
