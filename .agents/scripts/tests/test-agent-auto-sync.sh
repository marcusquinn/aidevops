#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit
GITHUB_HELPER="$REPO_ROOT/.agents/scripts/github-cli-helper.sh"
VERSION_HELPER="$REPO_ROOT/.agents/scripts/version-manager.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""
TEST_HOME=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	TEST_HOME="$TEST_DIR/home"
	trap teardown EXIT
	mkdir -p "$TEST_DIR/repo/.agents/scripts" "$TEST_HOME/.aidevops"
cat >"$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'AIDEVOPS_AGENTS_DIR=%s\n' "${AIDEVOPS_AGENTS_DIR-unset}" >>"${SYNC_ENV_LOG_PATH:?SYNC_ENV_LOG_PATH must be set}"
printf 'AGENTS_DIR=%s\n' "${AGENTS_DIR-unset}" >>"$SYNC_ENV_LOG_PATH"
printf '%s\n' "$*" >>"${SYNC_LOG_PATH:?SYNC_LOG_PATH must be set}"
if [[ "${MOCK_DEPLOY_EXIT_CODE:-0}" -ne 0 ]]; then
	exit "$MOCK_DEPLOY_EXIT_CODE"
fi
if [[ "${MOCK_DEPLOY_SKIP_ACTIVATION:-0}" == "1" ]]; then
	exit 0
fi

repo_root=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo)
		repo_root="$2"
		shift 2
		;;
	*) shift ;;
	esac
done
[[ -n "$repo_root" ]]
source_sha=$(git -C "$repo_root" rev-parse HEAD)
bundle_sha="$source_sha"
if [[ "${MOCK_DEPLOY_MODE:-current}" == "stale" ]]; then
	bundle_sha="1111111111111111111111111111111111111111"
fi
IFS= read -r framework_version <"$repo_root/VERSION"
bundle_id="${framework_version}-${bundle_sha:0:12}-fixture"
bundle_root="$HOME/.aidevops/runtime-bundles/$bundle_id/agents"
rm -rf "${bundle_root%/agents}"
mkdir -p "$bundle_root/scripts/setup/modules"

for sentinel_pair in \
	"aidevops.sh|aidevops.sh" \
	".agents/scripts/version-manager-release.sh|scripts/version-manager-release.sh" \
	".agents/scripts/deploy-agents-on-merge.sh|scripts/deploy-agents-on-merge.sh" \
	".agents/scripts/runtime-bundle-verifier.sh|scripts/runtime-bundle-verifier.sh" \
	".agents/scripts/setup/modules/agent-deploy.sh|scripts/setup/modules/agent-deploy.sh"; do
	source_rel="${sentinel_pair%%|*}"
	active_rel="${sentinel_pair#*|}"
	mkdir -p "$(dirname "$bundle_root/$active_rel")"
	cp "$repo_root/$source_rel" "$bundle_root/$active_rel"
done
cp "$repo_root/VERSION" "$bundle_root/VERSION"
if command -v sha256sum >/dev/null 2>&1; then
	cli_sha=$(sha256sum "$bundle_root/aidevops.sh" | cut -d' ' -f1)
else
	cli_sha=$(shasum -a 256 "$bundle_root/aidevops.sh" | cut -d' ' -f1)
fi
cat >"$bundle_root/.bundle-manifest" <<EOF_MANIFEST
schema=1
status=validated
bundle_id=$bundle_id
framework_version=$framework_version
git_sha=$bundle_sha
cli_sha256=$cli_sha
EOF_MANIFEST

active_link="$HOME/.aidevops/agents"
link_tmp="${active_link}.tmp.$$"
rm -f "$link_tmp"
ln -s "$bundle_root" "$link_tmp"
if [[ "$(uname -s)" == "Darwin" ]]; then
	mv -f -h "$link_tmp" "$active_link"
else
	mv -Tf "$link_tmp" "$active_link"
fi
printf '%s\n' "$bundle_sha" >"$HOME/.aidevops/.deployed-sha"
exit 0
EOF
	chmod +x "$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh"
	: >"$TEST_DIR/sync.log"
	: >"$TEST_DIR/sync-env.log"
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

invoke_github_sync() {
	local repo_slug="$1"
	AIDEVOPS_SYNC_REPO_PATH="$TEST_DIR/repo" \
		AIDEVOPS_SYNC_DEPLOY_SCRIPT="$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh" \
		MOCK_DEPLOY_SKIP_ACTIVATION=1 \
		SYNC_LOG_PATH="$TEST_DIR/sync.log" \
		SYNC_ENV_LOG_PATH="$TEST_DIR/sync-env.log" \
		MOCK_DEPLOY_EXIT_CODE="${MOCK_DEPLOY_EXIT_CODE:-0}" \
		bash -c 'source "$1" && trigger_aidevops_post_merge_sync "$2"' _ "$GITHUB_HELPER" "$repo_slug"
	return 0
}

invoke_release_sync() {
	local repo_root="$1"
	local deployment_scope="${2:-incremental}"
	AIDEVOPS_SYNC_REPO_ROOT="$repo_root" \
		AIDEVOPS_RELEASE_DEPLOY_SCOPE="$deployment_scope" \
		AIDEVOPS_SYNC_DEPLOY_SCRIPT="$TEST_DIR/repo/.agents/scripts/deploy-agents-on-merge.sh" \
		HOME="$TEST_HOME" \
		SYNC_LOG_PATH="$TEST_DIR/sync.log" \
		SYNC_ENV_LOG_PATH="$TEST_DIR/sync-env.log" \
		MOCK_DEPLOY_EXIT_CODE="${MOCK_DEPLOY_EXIT_CODE:-0}" \
		MOCK_DEPLOY_MODE="${MOCK_DEPLOY_MODE:-current}" \
		bash -c 'source "$1" && run_post_release_agent_sync' _ "$VERSION_HELPER"
	return $?
}

create_fake_repo() {
	local repo_name="$1"
	local remote_url="$2"
	local repo_path="$TEST_DIR/$repo_name"

	mkdir -p "$repo_path/.agents/scripts/setup/modules"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git init -q "$repo_path"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" config user.email test@example.invalid
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" config user.name Test
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" config commit.gpgsign false
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" remote add origin "$remote_url"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$repo_path/setup.sh"
	printf '#!/usr/bin/env bash\nprintf "fixture cli\\n"\n' >"$repo_path/aidevops.sh"
	printf '9.9.9\n' >"$repo_path/VERSION"
	printf 'release fixture\n' >"$repo_path/.agents/scripts/version-manager-release.sh"
	printf 'deploy fixture\n' >"$repo_path/.agents/scripts/deploy-agents-on-merge.sh"
	printf 'verifier fixture\n' >"$repo_path/.agents/scripts/runtime-bundle-verifier.sh"
	printf 'agent deploy fixture\n' >"$repo_path/.agents/scripts/setup/modules/agent-deploy.sh"
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" add .
	PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin git -C "$repo_path" commit -qm fixture
	printf '%s\n' "$repo_path"
	return 0
}

test_merge_sync_triggers_for_aidevops() {
	: >"$TEST_DIR/sync.log"
	invoke_github_sync "marcusquinn/aidevops"

	if grep -q -- "--repo $TEST_DIR/repo --quiet" "$TEST_DIR/sync.log"; then
		print_result "merge sync triggers for aidevops slug" 0
	else
		print_result "merge sync triggers for aidevops slug" 1 "Sync command was not recorded"
	fi
	return 0
}

test_merge_sync_skips_other_repos() {
	: >"$TEST_DIR/sync.log"
	invoke_github_sync "marcusquinn/another-repo"

	if [[ ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "merge sync skips non-aidevops repos" 0
	else
		print_result "merge sync skips non-aidevops repos" 1 "Unexpected sync invocation recorded"
	fi
	return 0
}

test_release_sync_triggers_for_aidevops_remote() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	repo_path=$(create_fake_repo "release-aidevops" "https://github.com/marcusquinn/aidevops.git")
	invoke_release_sync "$repo_path"

	if grep -q -- "--repo $repo_path --quiet" "$TEST_DIR/sync.log" && ! grep -q -- "--full" "$TEST_DIR/sync.log"; then
		print_result "release sync defaults to incremental for aidevops remote" 0
	else
		print_result "release sync triggers for aidevops remote" 1 "Release sync command was not recorded"
	fi
	return 0
}

test_release_sync_explicit_full() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	repo_path=$(create_fake_repo "release-full" "https://github.com/marcusquinn/aidevops.git")
	invoke_release_sync "$repo_path" full
	if grep -q -- "--repo $repo_path --quiet --full" "$TEST_DIR/sync.log"; then
		print_result "release sync supports explicit full deployment" 0
	else
		print_result "release sync supports explicit full deployment" 1 "Full sync command was not recorded"
	fi
	return 0
}

test_release_sync_skips_other_remotes() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	repo_path=$(create_fake_repo "release-other" "https://github.com/marcusquinn/other.git")
	invoke_release_sync "$repo_path"

	if [[ ! -s "$TEST_DIR/sync.log" ]]; then
		print_result "release sync skips non-aidevops remotes" 0
	else
		print_result "release sync skips non-aidevops remotes" 1 "Unexpected release sync invocation recorded"
	fi
	return 0
}

test_release_sync_propagates_deploy_failure() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	repo_path=$(create_fake_repo "release-failure" "https://github.com/marcusquinn/aidevops.git")
	if MOCK_DEPLOY_EXIT_CODE=1 invoke_release_sync "$repo_path" >/dev/null 2>&1; then
		print_result "release sync propagates full deployment failure" 1 "Failure was reported as success"
	else
		print_result "release sync propagates full deployment failure" 0
	fi
	return 0
}

test_release_sync_rejects_stale_provenance() {
	: >"$TEST_DIR/sync.log"
	local repo_path
	local output=""
	repo_path=$(create_fake_repo "release-stale" "https://github.com/marcusquinn/aidevops.git")
	if output=$(MOCK_DEPLOY_MODE=stale invoke_release_sync "$repo_path" 2>&1); then
		print_result "release sync rejects stale activation provenance" 1 "Stale deployment was reported as converged"
	elif [[ "$output" == *"does not identify release commit"* && "$output" == *"provenance did not converge"* ]]; then
		print_result "release sync rejects stale activation provenance" 0
	else
		print_result "release sync rejects stale activation provenance" 1 "Missing actionable stale-provenance evidence: $output"
	fi
	return 0
}

test_release_sync_unsets_session_pins() {
	: >"$TEST_DIR/sync-env.log"
	local repo_path
	repo_path=$(create_fake_repo "release-pinned" "https://github.com/marcusquinn/aidevops.git")
	AIDEVOPS_AGENTS_DIR="$TEST_DIR/.aidevops/runtime-bundles/old/agents" \
		AGENTS_DIR="$TEST_DIR/.aidevops/runtime-bundles/old/agents" \
		invoke_release_sync "$repo_path"

	if grep -q '^AIDEVOPS_AGENTS_DIR=unset$' "$TEST_DIR/sync-env.log" && \
		grep -q '^AGENTS_DIR=unset$' "$TEST_DIR/sync-env.log"; then
		print_result "release sync isolates inherited runtime pins" 0
	else
		print_result "release sync isolates inherited runtime pins" 1 "Deployment child inherited a session pin"
	fi
	return 0
}

main() {
	echo "Running agent auto-sync regression tests"
	setup

	test_merge_sync_triggers_for_aidevops
	test_merge_sync_skips_other_repos
	test_release_sync_triggers_for_aidevops_remote
	test_release_sync_explicit_full
	test_release_sync_skips_other_remotes
	test_release_sync_propagates_deploy_failure
	test_release_sync_rejects_stale_provenance
	test_release_sync_unsets_session_pins

	teardown
	trap - EXIT
	echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
