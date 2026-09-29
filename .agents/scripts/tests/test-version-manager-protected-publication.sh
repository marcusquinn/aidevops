#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify aidevops publication queues exact protected workflow runs durably.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "$HOME" "${TEST_ROOT}/bin" "${TEST_ROOT}/repo"

TESTS_RUN=0
TESTS_FAILED=0
INTERCEPT_PROTECTED_GIT=false
PUSH_ATTEMPTED=false

git() {
	if [[ "$INTERCEPT_PROTECTED_GIT" == "true" && " $* " == *" fetch origin main "* ]]; then
		return 0
	fi
	if [[ "$INTERCEPT_PROTECTED_GIT" == "true" && " $* " == *" push origin "* ]]; then
		PUSH_ATTEMPTED=true
		return 0
	fi
	command git "$@"
	return $?
}

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" == "true" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s: %s\n' "$name" "$detail"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
args=" $* "
if [[ "$args" == *"actions/workflows/publish-packages.yml/runs"* ]]; then
	if [[ "${FAKE_RELEASE_RUNS_API_FAILURE:-0}" == "1" ]]; then
		exit 1
	fi
	case "${FAKE_RELEASE_RUNS_SCHEMA_MODE:-valid}" in
	empty) exit 0 ;;
	object)
		printf '%s\n' '{}'
		exit 0
		;;
	malformed)
		printf '%s\n' '{'
		exit 0
		;;
	esac
	printf '%s\n' "${FAKE_RELEASE_RUNS_JSON:?}"
	exit 0
fi
if [[ "$args" == *"releases/tags/v1.2.4"* ]]; then
	printf '%s\n' "${FAKE_RELEASE_JSON:?}"
	exit 0
fi
exit 1
STUB
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export FAKE_GH_LOG="${TEST_ROOT}/gh.log"

cd "${TEST_ROOT}/repo"
git init -q -b main
git config user.email 'test@example.com'
git config user.name 'Test Runner'
git config commit.gpgsign false
git remote add origin 'git@github.com:marcusquinn/aidevops.git'
printf 'fixture\n' >fixture.txt
git add fixture.txt
git commit -q -m 'fixture'
git tag v1.2.4
TAG_COMMIT=$(git rev-parse HEAD)

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/version-manager.sh"
set +e

export AIDEVOPS_RELEASE_WORKFLOW_DISCOVERY_TIMEOUT_SECONDS=3
export AIDEVOPS_RELEASE_WORKFLOW_POLL_SECONDS=1
export FAKE_RELEASE_RUNS_API_FAILURE=0
export FAKE_RELEASE_RUNS_SCHEMA_MODE=valid
export FAKE_RELEASE_RUNS_JSON="{\"workflow_runs\":[{\"id\":501,\"event\":\"push\",\"head_sha\":\"${TAG_COMMIT}\",\"status\":\"waiting\",\"conclusion\":null,\"created_at\":\"2026-07-27T00:00:00Z\",\"html_url\":\"\"}]}"
export FAKE_RELEASE_JSON='{"tag_name":"v1.2.4","draft":false,"published_at":"2026-07-27T00:00:00Z"}'

rc=0
deadline=$(($(date +%s) + 3))
run_json=$(_release_find_exact_workflow_run 'marcusquinn/aidevops' 'publish-packages.yml' \
	'push' "$TAG_COMMIT" "$deadline" 1) || rc=$?
if [[ "$rc" -eq 0 && "$(jq -r '.id' <<<"$run_json")" == "501" ]]; then
	print_result 'exact unified publication workflow is discovered by tag commit' true
else
	print_result 'exact unified publication workflow is discovered by tag commit' false "rc=${rc}"
fi

for schema_mode in empty object malformed; do
	export FAKE_RELEASE_RUNS_SCHEMA_MODE="$schema_mode"
	rc=0
	_release_lookup_exact_workflow_run 'marcusquinn/aidevops' 'publish-packages.yml' \
		'push' "$TAG_COMMIT" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		print_result "${schema_mode} workflow-run response fails closed" true
	else
		print_result "${schema_mode} workflow-run response fails closed" false
	fi
done
export FAKE_RELEASE_RUNS_SCHEMA_MODE=valid

export FAKE_RELEASE_RUNS_API_FAILURE=1
rc=0
_release_lookup_exact_workflow_run 'marcusquinn/aidevops' 'publish-packages.yml' \
	'push' "$TAG_COMMIT" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result 'workflow-run API failure fails closed' true
else
	print_result 'workflow-run API failure fails closed' false
fi
export FAKE_RELEASE_RUNS_API_FAILURE=0

rc=0
_release_lookup_exact_workflow_run 'marcusquinn/aidevops' 'publish-packages.yml' \
	'push' '0000000000000000000000000000000000000000' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 3 ]]; then
	print_result 'wrong workflow commit cannot satisfy exact correlation' true
else
	print_result 'wrong workflow commit cannot satisfy exact correlation' false "rc=${rc}"
fi

protected_wait_body=$(declare -f _wait_for_protected_github_release)
if [[ "$protected_wait_body" == *'"publish-packages.yml" "push"'* ]] &&
	[[ "$protected_wait_body" != *'actions/runs/'* ]]; then
	print_result 'canonical release observes the unified tag workflow without terminal waiting' true
else
	print_result 'canonical release observes the unified tag workflow without terminal waiting' false "$protected_wait_body"
fi

: >"$FAKE_GH_LOG"
rc=0
_wait_for_protected_github_release '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 8 ]] && ! grep -q 'actions/runs/501' "$FAKE_GH_LOG"; then
	print_result 'queued publication returns pending without a foreground terminal waiter' true
else
	print_result 'queued publication returns pending without a foreground terminal waiter' false "rc=${rc}"
fi

export FAKE_RELEASE_RUNS_JSON="{\"workflow_runs\":[{\"id\":501,\"event\":\"push\",\"head_sha\":\"${TAG_COMMIT}\",\"status\":\"completed\",\"conclusion\":\"success\",\"created_at\":\"2026-07-27T00:00:00Z\",\"html_url\":\"\"}]}"
_verify_github_release_provenance() { return 0; }
rc=0
_wait_for_protected_github_release '1.2.4' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result 'already-completed publication reconciles immediately' true
else
	print_result 'already-completed publication reconciles immediately' false "rc=${rc}"
fi

export FAKE_RELEASE_JSON='{"tag_name":"v1.2.4","draft":true,"published_at":null}'
if ! _github_release_rest_published 'marcusquinn/aidevops' 'v1.2.4'; then
	print_result 'draft release cannot satisfy completed publication' true
else
	print_result 'draft release cannot satisfy completed publication' false
fi
export FAKE_RELEASE_JSON='{"tag_name":"v1.2.4","draft":false,"published_at":"2026-07-27T00:00:00Z"}'

route_log="${TEST_ROOT}/route.log"
release_source_pr_required() { return 0; }
create_github_release() {
	local version="$1"
	printf 'direct:%s\n' "$version" >>"$route_log"
	return 0
}
get_current_version() {
	printf '1.2.4\n'
	return 0
}
main github-release
if [[ ! -s "$route_log" ]]; then
	print_result 'aidevops github-release recovery cannot create a release directly' true
else
	print_result 'aidevops github-release recovery cannot create a release directly' false "$(tr '\n' ' ' <"$route_log")"
fi

: >"$route_log"
release_source_pr_required() { return 1; }
_publish_github_release '1.2.4'
if grep -qx 'direct:1.2.4' "$route_log"; then
	print_result 'non-aidevops release retains direct publication compatibility' true
else
	print_result 'non-aidevops release retains direct publication compatibility' false "$(tr '\n' ' ' <"$route_log")"
fi

: >"$route_log"
release_source_pr_required() { return 0; }
# A concurrent auto-update may replace the exact-tag bundle after deployment.
# Exercise the real preservation gate against a validated descendant and its
# materialized source, not merely the reported SHA.
descendant_commit=$(git commit-tree "${TAG_COMMIT}^{tree}" -p "$TAG_COMMIT" -m 'later protected main')
git worktree add --quiet --detach "${TEST_ROOT}/release" "$TAG_COMMIT"
mkdir -p "${HOME}/.aidevops" "${TEST_ROOT}/tag-bundle" "${TEST_ROOT}/descendant-bundle"
printf 'status=validated\ngit_sha=%s\n' "$TAG_COMMIT" >"${TEST_ROOT}/tag-bundle/.bundle-manifest"
printf 'status=validated\ngit_sha=%s\n' "$descendant_commit" >"${TEST_ROOT}/descendant-bundle/.bundle-manifest"
ln -s "${TEST_ROOT}/tag-bundle" "${HOME}/.aidevops/agents"
printf '#!/usr/bin/env bash\nexit 0\n' >"${TEST_ROOT}/deploy.sh"
validate_release_deployment_readiness() { return 0; }
_runtime_bundle_verify_active_link() {
	_AIDEVOPS_RUNTIME_VERIFY_ACTIVE_ROOT=$(realpath "$1") || return 1
	return 0
}
_runtime_bundle_verify_manifest_value() {
	local key="$2"
	local item=""
	local value=""
	while IFS='=' read -r item value; do
		if [[ "$item" == "$key" ]]; then
			printf '%s\n' "$value"
			return 0
		fi
	done <"$1"
	return 1
}
verify_calls=0
verify_aidevops_runtime_bundle_convergence() {
	verify_calls=$((verify_calls + 1))
	if [[ "$2" == "$TAG_COMMIT" ]]; then
		# The exact-tag deployment finished, then auto-update took the link.
		ln -sfn "${TEST_ROOT}/descendant-bundle" "${HOME}/.aidevops/agents"
		return 1
	fi
	[[ "$2" == "$descendant_commit" && "$3" == "${HOME}/.aidevops/agents" &&
		"$(realpath "$3")" == "${TEST_ROOT}/descendant-bundle" ]] || return 1
	return 0
}
rc=0
sync_output=$(AIDEVOPS_SYNC_REPO_ROOT="${TEST_ROOT}/release" \
	AIDEVOPS_SYNC_DEPLOY_SCRIPT="${TEST_ROOT}/deploy.sh" run_post_release_agent_sync 2>&1) || rc=$?
if [[ "$rc" -eq 0 && "$sync_output" == *"through validated preservation merge ${descendant_commit:0:12} (verified no-op)"* ]]; then
	print_result 'post-deploy descendant activation converges on first reconcile' true
else
	print_result 'post-deploy descendant activation converges on first reconcile' false "rc=${rc} output=${sync_output}"
fi

rm -f "${HOME}/.aidevops/agents"
ln -s "${TEST_ROOT}/tag-bundle" "${HOME}/.aidevops/agents"
printf 'status=unvalidated\ngit_sha=%s\n' "$descendant_commit" >"${TEST_ROOT}/descendant-bundle/.bundle-manifest"
rc=0
AIDEVOPS_SYNC_REPO_ROOT="${TEST_ROOT}/release" \
	AIDEVOPS_SYNC_DEPLOY_SCRIPT="${TEST_ROOT}/deploy.sh" run_post_release_agent_sync >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result 'unvalidated concurrent bundle cannot satisfy release convergence' true
else
	print_result 'unvalidated concurrent bundle cannot satisfy release convergence' false
fi

run_post_release_agent_sync() {
	printf 'deploy\n' >>"$route_log"
	return 0
}
rc=0
run_post_publication_gates '1.2.4' 0 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 && "$(tr '\n' ',' <"$route_log")" == 'deploy,' ]]; then
	print_result 'remote publication is not redundantly awaited before local deployment' true
else
	print_result 'remote publication is not redundantly awaited before local deployment' false "rc=${rc} events=$(tr '\n' ' ' <"$route_log")"
fi

printf 'descendant\n' >>fixture.txt
git add fixture.txt
git commit -q -m 'intervening main change'
git update-ref refs/remotes/origin/main HEAD
PUSH_ATTEMPTED=false
INTERCEPT_PROTECTED_GIT=true
_version_manager_classify_remote_tag() {
	_VERSION_MANAGER_REMOTE_TAG_STATE="absent"
	return 0
}
_VERSION_MANAGER_LOCAL_TAG_COMMIT="$TAG_COMMIT"
rc=0
_version_manager_publish_reachable_tag v1.2.4 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 && "$PUSH_ATTEMPTED" == "false" && "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "aggregation-required" ]]; then
	print_result 'changed protected-main tree stops before immutable tag publication' true
else
	print_result 'changed protected-main tree stops before immutable tag publication' false "rc=${rc} pushed=${PUSH_ATTEMPTED} result=${_VERSION_MANAGER_PROTECTED_RELEASE_RESULT}"
fi

printf '\nTests run: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
