#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Exercise the production metrics publisher against real disposable Git remotes.
# Only the PR API is stubbed; Git publication uses real local remotes.

set -euo pipefail
TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISHER="${TEST_SCRIPT_DIR}/../repo-metrics-git-push-helper.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
# shellcheck source=../repo-metrics-git-push-helper.sh
source "$PUBLISHER"

TEST_COUNT=0
WORK=""
REMOTE=""
PR_STATE=""
API_MODE=enabled
export GITHUB_REPOSITORY=example/metrics-fixture
export GH_TOKEN=fixture-job-token
export AIDEVOPS_METRICS_PR_TOKEN=""

assert() {
	local description="$1"
	shift
	if ! "$@"; then
		printf 'FAIL %s\n' "$description" >&2
		return 1
	fi
	TEST_COUNT=$((TEST_COUNT + 1))
	printf 'PASS %s\n' "$description"
	return 0
}

fixture() {
	local name="$1"
	REMOTE="${TEST_TMP}/${name}.git"
	WORK="${TEST_TMP}/${name}"
	PR_STATE="${TEST_TMP}/${name}-pr"
	API_MODE=enabled
	AIDEVOPS_METRICS_PR_TOKEN=""
	git init -q --bare "$REMOTE"
	git init -q "$WORK"
	git -C "$WORK" config user.name 'GitHub Actions'
	git -C "$WORK" config user.email 'fixture@example.invalid'
	git -C "$WORK" config commit.gpgsign false
	printf 'fixture\n' >"${WORK}/README.md"
	git -C "$WORK" add README.md
	git -C "$WORK" commit -qm seed
	git -C "$WORK" branch -M main
	git -C "$WORK" remote add origin "$REMOTE"
	git -C "$WORK" push -q origin main
	git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
	return 0
}

protect() {
	cat >"${REMOTE}/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
while read -r old new ref; do
  if [[ "$ref" == refs/heads/main ]]; then
    printf 'remote: error: GH006: Protected branch update failed for refs/heads/main.\nChanges must be made through a pull request; required checks expected.\n' >&2
    exit 1
  fi
done
exit 0
EOF
	chmod +x "${REMOTE}/hooks/pre-receive"
	return 0
}

artifacts() {
	local value="$1"
	mkdir -p "${WORK}/custom data/badges" "${WORK}/legacy"
	printf '{"value":%s}\n' "$value" >"${WORK}/custom data/repo-metrics.json"
	printf 'metrics %s\n' "$value" >"${WORK}/custom data/repo-metrics.md"
	printf '<svg>%s</svg>\n' "$value" >"${WORK}/custom data/badges/loc.svg"
	printf '<svg>%s</svg>\n' "$value" >"${WORK}/legacy/loc-total.svg"
	return 0
}

# PR API adapters: state persists across command-substitution subshells.
gh_pr_list() {
	if [[ -f "$PR_STATE" ]]; then
		printf 'https://example.invalid/metrics-pr\n'
	fi
	return 0
}

gh_create_pr() {
	printf 'attempt\n' >>"${PR_STATE}-attempts"
	if [[ "$API_MODE" == disabled && "${GH_TOKEN:-}" != fixture-pat-token ]]; then
		printf 'GitHub Actions is not permitted to create pull requests\n' >&2
		return 1
	fi
	printf 'created\n' >"$PR_STATE"
	if [[ "$API_MODE" == partial ]]; then
		return 1
	fi
	printf 'https://example.invalid/metrics-pr\n'
	return 0
}

publish() {
	(cd "$WORK" && main main 'custom data' 'custom data/badges' legacy \
		'chore(metrics): fixture [skip ci]')
	return $?
}

fixture direct
artifacts 1
printf 'unrelated staged change\n' >"${WORK}/README.md"
git -C "$WORK" add README.md
INDEX_BEFORE=$(git -C "$WORK" write-tree)
HEAD_BEFORE=$(git -C "$WORK" rev-parse HEAD)
publish
assert 'unprotected branch receives metrics' git --git-dir="$REMOTE" cat-file -e 'main:custom data/repo-metrics.json'
assert 'legacy artifact is published' git --git-dir="$REMOTE" cat-file -e 'main:legacy/loc-total.svg'
assert 'publisher preserves checkout HEAD' test "$(git -C "$WORK" rev-parse HEAD)" = "$HEAD_BEFORE"
assert 'publisher preserves existing staging' test "$(git -C "$WORK" write-tree)" = "$INDEX_BEFORE"
assert 'unrelated staged content is excluded' test "$(git --git-dir="$REMOTE" show main:README.md)" = fixture
assert 'direct publication does not open a PR' test ! -f "$PR_STATE"

fixture protected
protect
artifacts 1
HEAD_BEFORE=$(git -C "$WORK" rev-parse HEAD)
publish
BRANCH_FIRST=$(git --git-dir="$REMOTE" rev-parse aidevops/repository-metrics)
assert 'GH006 leaves default branch unchanged' test "$(git --git-dir="$REMOTE" rev-parse main)" = "$HEAD_BEFORE"
assert 'GH006 creates the deterministic PR' test -f "$PR_STATE"
assert 'fallback commit permits PR checks' test "$(git --git-dir="$REMOTE" log -1 --format=%s aidevops/repository-metrics)" = 'chore(metrics): fixture'
artifacts 2
publish
assert 'second refresh replaces the same branch' test "$(git --git-dir="$REMOTE" rev-parse aidevops/repository-metrics)" != "$BRANCH_FIRST"
assert 'second refresh does not create another PR' test "$(wc -l <"${PR_STATE}-attempts" | tr -d ' ')" = 1
assert 'replacement contains latest generated snapshot' test "$(git --git-dir="$REMOTE" show 'aidevops/repository-metrics:custom data/repo-metrics.json')" = '{"value":2}'

# Simulate a reviewed source PR merge, then refresh an older legitimate candidate.
printf 'reviewed source update\n' >>"${WORK}/README.md"
git -C "$WORK" commit -qam 'reviewed source change'
git -C "$WORK" push -q origin HEAD:refs/heads/reviewed-source
git --git-dir="$REMOTE" update-ref refs/heads/main "$(git -C "$WORK" rev-parse HEAD)"
artifacts 3
publish
assert 'older legitimate snapshot refreshes on current default base' test "$(git --git-dir="$REMOTE" show 'aidevops/repository-metrics:custom data/repo-metrics.json')" = '{"value":3}'

fixture foreign-branch
git -C "$WORK" push -q origin HEAD:refs/heads/aidevops/repository-metrics
protect
artifacts 1
FOREIGN_SHA=$(git --git-dir="$REMOTE" rev-parse aidevops/repository-metrics)
if publish >"${TEST_TMP}/foreign.log" 2>&1; then
	printf 'FAIL unrecognized branch must not be replaced\n' >&2
	exit 1
fi
assert 'unrecognized deterministic branch is preserved' test "$(git --git-dir="$REMOTE" rev-parse aidevops/repository-metrics)" = "$FOREIGN_SHA"
assert 'branch ownership failure is explicit' grep -q 'unrecognized metrics branch' "${TEST_TMP}/foreign.log"

fixture extra-history
SOURCE_SHA=$(git -C "$WORK" rev-parse HEAD)
printf 'unrelated branch change\n' >>"${WORK}/README.md"
git -C "$WORK" commit -qam 'unrelated branch work'
artifacts 1
git -C "$WORK" add 'custom data' legacy
git -C "$WORK" commit -qm "metrics-only tip

Aidevops-Metrics-Source: ${SOURCE_SHA}"
git -C "$WORK" push -q origin HEAD:refs/heads/aidevops/repository-metrics
FOREIGN_SHA=$(git --git-dir="$REMOTE" rev-parse aidevops/repository-metrics)
git -C "$WORK" checkout -q "$SOURCE_SHA"
protect
artifacts 2
if publish >"${TEST_TMP}/history.log" 2>&1; then
	printf 'FAIL unrelated earlier history must not be discarded\n' >&2
	exit 1
fi
assert 'unrelated work below a metrics-only tip is preserved' test "$(git --git-dir="$REMOTE" rev-parse aidevops/repository-metrics)" = "$FOREIGN_SHA"
assert 'additional history fails at the owning boundary' grep -q 'additional history' "${TEST_TMP}/history.log"

fixture disabled
protect
artifacts 1
API_MODE=disabled
if publish >"${TEST_TMP}/disabled.log" 2>&1; then
	printf 'FAIL disabled Actions PR creation must fail without fallback\n' >&2
	exit 1
fi
assert 'failure identifies missing PR permission' grep -q 'pull-requests: write.*Actions' "${TEST_TMP}/disabled.log"
assert 'failure never recommends a protection bypass' grep -q 'does not bypass branch protection' "${TEST_TMP}/disabled.log"
AIDEVOPS_METRICS_PR_TOKEN=fixture-pat-token
publish
assert 'disabled Actions PR creation uses bounded PAT fallback' test -f "$PR_STATE"
assert 'PAT fallback does not mutate protected main' test "$(git --git-dir="$REMOTE" rev-parse main)" = "$(git -C "$WORK" rev-parse HEAD)"

fixture partial
protect
artifacts 1
API_MODE=partial
AIDEVOPS_METRICS_PR_TOKEN=fixture-pat-token
publish
assert 'partial API success recovers before PAT retry' test "$(wc -l <"${PR_STATE}-attempts" | tr -d ' ')" = 1

fixture unrelated-failure
artifacts 1
printf '#!/usr/bin/env bash\nexit 1\n' >"${REMOTE}/hooks/pre-receive"
chmod +x "${REMOTE}/hooks/pre-receive"
if publish >"${TEST_TMP}/unrelated.log" 2>&1; then
	printf 'FAIL unrelated push failure must fail\n' >&2
	exit 1
fi
assert 'non-GH006 failure never opens a PR' test ! -f "$PR_STATE"
FAIL_ON_PUSH_ERROR=false publish >"${TEST_TMP}/warning.log" 2>&1
assert 'warning-only opt-out remains available' grep -q 'warning-only' "${TEST_TMP}/warning.log"

fixture stale
HEAD_BEFORE=$(git -C "$WORK" rev-parse HEAD)
printf 'new upstream source\n' >>"${WORK}/README.md"
git -C "$WORK" commit -qam 'source advanced'
git -C "$WORK" push -q origin main
git -C "$WORK" checkout -q "$HEAD_BEFORE"
artifacts 1
publish >"${TEST_TMP}/stale.log" 2>&1
assert 'outdated queued source is skipped' grep -q 'Skipping superseded metrics snapshot' "${TEST_TMP}/stale.log"
assert 'outdated source cannot create a metrics PR' test ! -f "$PR_STATE"

assert 'traversal output directory is rejected' test ! -d "${WORK}/../escape"
if (cd "$WORK" && metrics_validate_dir ../escape); then
	printf 'FAIL traversal directory accepted\n' >&2
	exit 1
fi

# Execute the actual YAML resolver, not a copy of its implementation. This also
# verifies explicit helper refs avoid an API dependency and omitted refs fail closed.
WORKFLOW="${TEST_SCRIPT_DIR}/../../../.github/workflows/loc-badge-reusable.yml"
python3 - "$WORKFLOW" "${TEST_TMP}/resolve-ref.sh" <<'PY'
import pathlib
import sys
import yaml

workflow = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
step = next(s for s in workflow["jobs"]["generate"]["steps"] if s.get("id") == "helper-ref")
pathlib.Path(sys.argv[2]).write_text(step["run"])
PY
gh() {
	printf '%s\n' "$RESOLVER_RESPONSE"
	return 0
}
export -f gh
export GITHUB_RUN_ID=1
export HELPER_REPOSITORY=example/framework
export GITHUB_OUTPUT="${TEST_TMP}/resolver-output"
export HELPER_REF=explicit-fixture-ref
export RESOLVER_RESPONSE='{}'
bash "${TEST_TMP}/resolve-ref.sh"
assert 'explicit helper ref is preserved without run lookup' grep -qx 'ref=explicit-fixture-ref' "$GITHUB_OUTPUT"
HELPER_REF=""
RESOLVER_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RESOLVER_RESPONSE="{\"referenced_workflows\":[{\"path\":\"example/framework/.github/workflows/loc-badge-reusable.yml@main\",\"sha\":\"${RESOLVER_SHA}\"}]}"
bash "${TEST_TMP}/resolve-ref.sh"
assert 'omitted ref resolves exact reusable workflow SHA' grep -qx "ref=${RESOLVER_SHA}" "$GITHUB_OUTPUT"
RESOLVER_RESPONSE='{}'
if bash "${TEST_TMP}/resolve-ref.sh" >"${TEST_TMP}/resolver-error" 2>&1; then
	printf 'FAIL unresolved helper identity must fail closed\n' >&2
	exit 1
fi
assert 'missing helper provenance never drifts to main' grep -q 'Cannot resolve one pinned metrics helper SHA' "${TEST_TMP}/resolver-error"
printf 'All %s metrics publication assertions passed\n' "$TEST_COUNT"
