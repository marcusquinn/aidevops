#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
INSTALL_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AGENTS_DIR="${INSTALL_DIR}/.agents"
CLOUDRON_CALLER_FRAMEWORK_REF="22a6b4b29087ce2fcf3857596a40ff7b2c436482"
CLOUDRON_CATALOG_FRAMEWORK_REF="6606b999d0ed310aeb78efc802e216d6751bda9c"
TEST_ROOT=""
PASSED=0
FAILED=0

print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }

# shellcheck source=../aidevops-cli/aidevops-repos-lib.sh
source "${INSTALL_DIR}/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh"
# shellcheck source=../aidevops-cli/aidevops-init-lib.sh
source "${INSTALL_DIR}/.agents/scripts/aidevops-cli/aidevops-init-lib.sh"

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local description="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$description"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual" >&2
	FAILED=$((FAILED + 1))
	return 0
}

test_cloudron_workflow_scaffolding() {
	local repo_dir="${TEST_ROOT}/cloudron"
	mkdir -p "$repo_dir"
	printf '{}\n' >"${repo_dir}/CloudronManifest.json"
	_init_scaffold_cloudron_release_workflow "$repo_dir"
	local workflow="${repo_dir}/.github/workflows/cloudron-package-release.yml"
	assert_equal true "$([[ -f "$workflow" ]] && printf true || printf false)" "Cloudron caller scaffolded"
	assert_equal "$(cksum "${AGENTS_DIR}/templates/workflows/cloudron-package-release-caller.yml" | awk '{ print $1, $2 }')" "$(cksum "$workflow" | awk '{ print $1, $2 }')" "caller matches managed template"
	assert_equal true "$(grep -Fq "cloudron-package-release-reusable.yml@${CLOUDRON_CALLER_FRAMEWORK_REF}" "$workflow" && printf true || printf false)" "caller pins reusable workflow commit"
	assert_equal true "$(grep -Fq "aidevops_ref: ${CLOUDRON_CALLER_FRAMEWORK_REF}" "$workflow" && printf true || printf false)" "caller pins validator commit"
	assert_equal false "$(grep -Eq '@main|aidevops_ref:[[:space:]]+main' "$workflow" && printf true || printf false)" "caller contains no mutable main ref"
	assert_equal true "$(git -C "$INSTALL_DIR" cat-file -e "${CLOUDRON_CALLER_FRAMEWORK_REF}:.github/workflows/cloudron-package-release-reusable.yml" 2>/dev/null && printf true || printf false)" "pinned commit contains reusable workflow"
	assert_equal true "$(git -C "$INSTALL_DIR" cat-file -e "${CLOUDRON_CALLER_FRAMEWORK_REF}:.agents/scripts/cloudron-package-helper.sh" 2>/dev/null && printf true || printf false)" "pinned commit contains release validator"
	local catalog="${repo_dir}/.github/workflows/cloudron-catalog-publish.yml"
	assert_equal true "$([[ -f "$catalog" ]] && printf true || printf false)" "catalog caller scaffolded"
	assert_equal "$(cksum "${AGENTS_DIR}/templates/workflows/cloudron-catalog-publish-caller.yml" | awk '{ print $1, $2 }')" "$(cksum "$catalog" | awk '{ print $1, $2 }')" "catalog caller matches template"
	assert_equal true "$(grep -Fq "cloudron-catalog-publish-reusable.yml@${CLOUDRON_CATALOG_FRAMEWORK_REF}" "$catalog" && printf true || printf false)" "catalog caller pins workflow"
	assert_equal true "$(grep -Fq "aidevops_ref: ${CLOUDRON_CATALOG_FRAMEWORK_REF}" "$catalog" && printf true || printf false)" "catalog signer policy matches workflow pin"
	assert_equal true "$(git -C "$INSTALL_DIR" cat-file -e "${CLOUDRON_CATALOG_FRAMEWORK_REF}:.github/workflows/cloudron-catalog-publish-reusable.yml" 2>/dev/null && printf true || printf false)" "catalog pin contains workflow"
	assert_equal false "$(grep -Eq '@main|aidevops_ref:[[:space:]]+main|secrets:[[:space:]]+inherit' "$catalog" && printf true || printf false)" "catalog has no mutable pin or inherited secrets"
	local before=""
	before=$(cksum "$workflow")
	_init_scaffold_cloudron_release_workflow "$repo_dir"
	assert_equal "$before" "$(cksum "$workflow")" "Cloudron caller scaffolding is idempotent"
	printf 'custom catalog\n' >"$catalog"
	_init_scaffold_cloudron_release_workflow "$repo_dir"
	assert_equal 'custom catalog' "$(tr -d '\n' <"$catalog")" "existing catalog caller is never overwritten"

	local generic_dir="${TEST_ROOT}/generic"
	mkdir -p "$generic_dir"
	_init_scaffold_cloudron_release_workflow "$generic_dir"
	assert_equal false "$([[ -e "${generic_dir}/.github/workflows/cloudron-package-release.yml" ]] && printf true || printf false)" "non-Cloudron repo receives no caller"
	assert_equal false "$([[ -e "${generic_dir}/.github/workflows/cloudron-catalog-publish.yml" ]] && printf true || printf false)" "non-Cloudron repo receives no catalog caller"

	local existing_dir="${TEST_ROOT}/existing"
	mkdir -p "${existing_dir}/.github/workflows"
	printf '{}\n' >"${existing_dir}/CloudronManifest.json"
	printf 'custom\n' >"${existing_dir}/.github/workflows/cloudron-package-release.yml"
	_init_scaffold_cloudron_release_workflow "$existing_dir"
	assert_equal custom "$(tr -d '\n' <"${existing_dir}/.github/workflows/cloudron-package-release.yml")" "existing caller is never overwritten"
	assert_equal true "$([[ -f "${existing_dir}/.github/workflows/cloudron-catalog-publish.yml" ]] && printf true || printf false)" "catalog installed alongside existing legacy caller"
	return 0
}

test_catalog_migration() {
	local repo_dir="${TEST_ROOT}/migration"
	local helper="${AGENTS_DIR}/scripts/cloudron-package-helper.sh"
	local workflow="${repo_dir}/.github/workflows/cloudron-catalog-publish.yml"
	mkdir -p "${repo_dir}/.github/workflows"
	printf '{}\n' >"${repo_dir}/CloudronManifest.json"
	cat >"$workflow" <<'YAML'
name: Inline catalog
on: [pull_request]
env:
  IMAGE_REPOSITORY: ghcr.io/example/package
  CLOUDRON_CLI_VERSION: 8.2.6
  CLOUDRON_CLI_INTEGRITY: sha512-example
jobs:
  preflight:
    runs-on: ubuntu-24.04
    steps:
      - name: Validate package
        run: bash ./test/package-test.sh
      - name: Validate patch
        run: bash scripts/check-patch.sh
YAML
	local before=""
	before=$(cksum "$workflow")
	bash "$helper" scaffold catalog "$repo_dir"
	assert_equal "$before" "$(cksum "$workflow")" "default scaffold preserves inline workflow"
	bash "$helper" scaffold catalog --migrate "$repo_dir"
	assert_equal true "$(grep -Fq "cloudron-catalog-publish-reusable.yml@${CLOUDRON_CATALOG_FRAMEWORK_REF}" "$workflow" && printf true || printf false)" "migration pins fixed reusable workflow"
	assert_equal true "$(grep -Fq 'bash ./test/package-test.sh' "$workflow" && grep -Fq 'bash scripts/check-patch.sh' "$workflow" && printf true || printf false)" "migration preserves both package checks"
	assert_equal true "$(grep -Fq 'image_repository: ghcr.io/example/package' "$workflow" && grep -Fq 'cli_version: 8.2.6' "$workflow" && printf true || printf false)" "migration preserves image and CLI inputs"
	before=$(cksum "$workflow")
	assert_equal false "$(bash "$helper" scaffold catalog "$repo_dir" --migrate >/dev/null 2>&1 && printf true || printf false)" "existing caller requires manual pin review"
	assert_equal "$before" "$(cksum "$workflow")" "existing caller inputs remain unchanged"
	cat >"$workflow" <<'YAML'
jobs:
  preflight:
    steps:
      - name: Custom authorization
        run: check-policy
  runtime-smoke:
    steps: []
YAML
	before=$(cksum "$workflow")
	local output=""
	if output=$(bash "$helper" scaffold catalog --migrate "$repo_dir" 2>&1); then
		assert_equal blocked migrated "unmapped configuration blocks migration"
	fi
	assert_equal true "$(grep -Fq 'runtime-smoke' <<<"$output" && grep -Fq 'Custom authorization' <<<"$output" && printf true || printf false)" "migration lists unmapped jobs and steps"
	assert_equal "$before" "$(cksum "$workflow")" "blocked migration leaves original bytes intact"
	return 0
}

test_cloudron_registration_metadata() {
	local home_dir="${TEST_ROOT}/home"
	local repo_dir="${TEST_ROOT}/registered"
	CONFIG_DIR="${home_dir}/.config/aidevops"
	REPOS_FILE="${CONFIG_DIR}/repos.json"
	mkdir -p "$CONFIG_DIR" "$repo_dir"
	git -C "$repo_dir" init --quiet
	cat >>"${repo_dir}/.git/config" <<'GITCONFIG'
[remote "origin"]
    url = https://github.com/exampleorg/registered-package.git
    fetch = +refs/heads/*:refs/remotes/origin/*
GITCONFIG
	printf '{}\n' >"${repo_dir}/CloudronManifest.json"
	_repo_registration_maintainer() {
		printf '%s\n' examplemaintainer
		return 0
	}
	register_repo "$repo_dir" 9.9.9 planning
	assert_equal cloudron-package "$(jq -r '.initialized_repos[0].app_type' "$REPOS_FILE")" "registration records Cloudron app_type"
	assert_equal CloudronManifest.json "$(jq -r '.initialized_repos[0].cloudron_package.manifest' "$REPOS_FILE")" "registration records manifest path"
	assert_equal true "$(jq -r '.initialized_repos[0].cloudron_package.monitor_compatibility' "$REPOS_FILE")" "compatibility monitoring defaults on"
	assert_equal '["v",""]' "$(jq -c '.initialized_repos[0].cloudron_package.upstream_tag_prefixes' "$REPOS_FILE")" "registration defaults to v-prefixed and bare upstream tags"
	jq '.initialized_repos[0].cloudron_package += {"upstream_slug":"exampleorg/upstream","monitor_compatibility":false,"upstream_tag_prefixes":["desktop-v"]}' "$REPOS_FILE" >"${REPOS_FILE}.tmp"
	mv "${REPOS_FILE}.tmp" "$REPOS_FILE"
	register_repo "$repo_dir" 9.9.10 planning
	assert_equal exampleorg/upstream "$(jq -r '.initialized_repos[0].cloudron_package.upstream_slug' "$REPOS_FILE")" "explicit upstream metadata preserved"
	assert_equal false "$(jq -r '.initialized_repos[0].cloudron_package.monitor_compatibility' "$REPOS_FILE")" "explicit monitoring preference preserved"
	assert_equal '["desktop-v"]' "$(jq -c '.initialized_repos[0].cloudron_package.upstream_tag_prefixes' "$REPOS_FILE")" "explicit upstream tag stream preserved"
	return 0
}

test_catalog_secret_preflight() {
	local repo_dir="${TEST_ROOT}/secret-preflight" output=""
	mkdir -p "$repo_dir"
	git -C "$repo_dir" init --quiet
	git -C "$repo_dir" remote add origin https://github.com/example/package.git
	printf '{}\n' >"${repo_dir}/CloudronManifest.json"
	gh() {
		local command="$1" target="${2:-}"
		case "$command $target" in
		'repo view') printf 'example/package\n' ;;
		'secret list')
			[[ "$*" == 'secret list --repo example/package --json name' ]] || return 9
			[[ "$SECRET_CASE" != error ]] || return 1
			if [[ "$SECRET_CASE" == present ]]; then
				printf '[{"name":"CLOUDRON_RELEASE_PAT"}]\n'
			else
				printf '[]\n'
			fi
			;;
		'api /repos/example/package/actions/variables') printf '%s\n' "$PUBLICATION_ENABLED" ;;
		*) return 9 ;;
		esac
		return 0
	}
	export -f gh
	export SECRET_CASE=missing PUBLICATION_ENABLED=true
	output=$(bash "${AGENTS_DIR}/scripts/cloudron-package-helper.sh" scaffold catalog "$repo_dir" 2>&1)
	assert_equal true "$(grep -Fq 'missing CLOUDRON_RELEASE_PAT' <<<"$output" && printf true || printf false)" "plain scaffold warns about missing PAT"
	assert_equal true "$(grep -Fq 'Contents write' <<<"$output" && printf true || printf false)" "warning includes restricted PAT setup"
	rm "${repo_dir}/.github/workflows/cloudron-catalog-publish.yml"
	export SECRET_CASE=present
	output=$(bash "${AGENTS_DIR}/scripts/cloudron-package-helper.sh" scaffold catalog "$repo_dir" 2>&1)
	assert_equal false "$(grep -Fq 'Publication blocked' <<<"$output" && printf true || printf false)" "present PAT permits scaffold without warning"
	# A minimal supported inline workflow exercises the migration warning too.
	printf 'on: [pull_request]\njobs:\n  preflight:\n    steps: []\n' >"${repo_dir}/.github/workflows/cloudron-catalog-publish.yml"
	export SECRET_CASE=missing
	output=$(bash "${AGENTS_DIR}/scripts/cloudron-package-helper.sh" scaffold catalog --migrate "$repo_dir" 2>&1)
	assert_equal true "$(grep -Fq 'missing CLOUDRON_RELEASE_PAT' <<<"$output" && printf true || printf false)" "migration warns about missing PAT"
	# Source with help, never scan the host registry or mutate package issues.
	(
		set -- help
		source "${AGENTS_DIR}/scripts/cloudron-package-monitor-helper.sh" >/dev/null
		local entry='{"slug":"example/package"}' rc=0
		output=$(_cloudron_monitor_publication_secret "$entry") || rc=$?
		[[ "$rc" == 3 && "$output" == *'missing CLOUDRON_RELEASE_PAT'* ]] || exit 1
		SECRET_CASE=present
		_cloudron_monitor_publication_secret "$entry" || exit 1
		SECRET_CASE=error
		if _cloudron_monitor_publication_secret "$entry"; then exit 1; fi
		PUBLICATION_ENABLED=false
		_cloudron_monitor_publication_secret "$entry" || exit 1
		PUBLICATION_ENABLED=true
		SECRET_CASE=missing
		REPOS_FILE="${TEST_ROOT}/monitor-repos.json"
		printf '{"initialized_repos":[{"slug":"example/package","app_type":"cloudron-package"}]}' >"$REPOS_FILE"
		_cloudron_monitor_upstream_entry() { return 0; }
		_cloudron_monitor_compatibility_entry() { return 0; }
		_cloudron_monitor_reconcile_entry() { printf 'RECONCILE\n'; return 0; }
		output=$(_cloudron_monitor_run upstream true)
		[[ "$output" == 'FINDING example/package:'* && "$output" != *$'\n'* && "$output" != *RECONCILE* ]] || exit 1
		output=$(_cloudron_monitor_run compatibility false)
		[[ "$output" == 'FINDING example/package:'* && "$output" != *$'\n'* ]] || exit 1
		SECRET_CASE=present
		output=$(_cloudron_monitor_run upstream true)
		[[ "$output" == RECONCILE ]] || exit 1
	) || return 1
	printf 'PASS monitor secret present, absent, inaccessible and publication disabled\n'
	unset -f gh
	return 0
}

test_cloudron_publishing_command_syntax() {
	local publishing_skill="${AGENTS_DIR}/tools/deployment/cloudron-app-publishing-skill.md"
	assert_equal true "$(grep -Fq 'cloudron versions update --version=1.0.0 --state=published' "$publishing_skill" && printf true || printf false)" "publishing guidance uses equals-form options"
	assert_equal false "$(grep -Fq 'cloudron versions update --version ' "$publishing_skill" && printf true || printf false)" "publishing guidance avoids global version flag collision"
	return 0
}

test_documentation_layout_scaffolding() {
	local repo_dir="${TEST_ROOT}/documentation"
	mkdir -p "$repo_dir"
	printf '{}\n' >"${repo_dir}/CloudronManifest.json"
	scaffold_agents_md "$repo_dir"
	local guide="${repo_dir}/.agents/AGENTS.md"
	assert_equal true "$(grep -Fq 'Keep human/operator guides in' "$guide" && printf true || printf false)" "new agent guide separates operator documentation"
	assert_equal true "$(grep -Fq 'Generated artifacts require changing their writer' "$guide" && printf true || printf false)" "new agent guide preserves generator ownership"
	printf '\n## Custom project context\n\nCustom project guidance must survive.\n' >>"$guide"
	scaffold_agents_md "$repo_dir"
	assert_equal true "$(grep -Fq 'Custom project guidance must survive.' "$guide" && printf true || printf false)" "repeated init preserves custom guide content"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_cloudron_workflow_scaffolding
	test_catalog_migration
	test_catalog_secret_preflight
	test_cloudron_registration_metadata
	test_cloudron_publishing_command_syntax
	test_documentation_layout_scaffolding
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
