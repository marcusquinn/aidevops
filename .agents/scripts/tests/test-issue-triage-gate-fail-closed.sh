#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# GH#36905: triage logic lives in the reusable workflow; this repo and managed
# downstream repos call it through thin callers.
WORKFLOW="${TEST_DIR}/../../../.github/workflows/issue-triage-gate-reusable.yml"
SELF_CALLER="${TEST_DIR}/../../../.github/workflows/issue-triage-gate.yml"
CALLER_TEMPLATE="${TEST_DIR}/../../templates/workflows/issue-triage-gate-caller.yml"
TESTS_RUN=0
TESTS_FAILED=0

check_pattern() {
	local pattern="$1"
	local name="$2"
	local file="${3:-$WORKFLOW}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE -- "$pattern" "$file"; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

check_permission_behavior() {
	local workflow="$1"
	if node - "$workflow" <<'NODE'
const fs = require('fs');
const source = fs.readFileSync(process.argv[2], 'utf8').split('          script: |\n')[1];
if (!source) throw new Error('workflow script not found');
const script = source.split('\n').map(line => line.startsWith('            ') ? line.slice(12) : line).join('\n');
const run = new (Object.getPrototypeOf(async function () {}).constructor)('context', 'github', 'core', script);

async function scenario(association, permission, expectedTrusted, options = {}) {
  const labels = [];
  let lookups = 0;
  const context = {repo: {owner: 'owner', repo: 'repo'}, payload: {
    action: 'opened', issue: {number: 1, user: {login: 'author', type: 'User'},
      author_association: association, labels: [], body: ''}
  }};
  const github = {request: async () => {
    lookups++;
    if (options.error) throw new Error('unavailable');
    return {data: {permission}};
  }, rest: {issues: {addLabels: async request => labels.push(...request.labels),
    createComment: async () => {}, removeLabel: async () => {}}}};
  await run(context, github, {warning: () => {}, error: () => {}});
  if (lookups !== 1 || labels.includes('needs-maintainer-review') === expectedTrusted ||
      labels.includes('external-contributor') === expectedTrusted) {
    throw new Error(`unexpected result for ${association}/${permission}: ${lookups} lookups, ${labels}`);
  }
}
(async () => {
  await scenario('CONTRIBUTOR', 'admin', true);
  await scenario('NONE', 'read', false);
  await scenario('FIRST_TIME_CONTRIBUTOR', 'none', false);
  await scenario('COLLABORATOR', null, false, {error: true});
  console.log('PASS live permission lookup and fail-closed triage behavior');
})().catch(error => { console.error(error); process.exitCode = 1; });
NODE
	then
		return 0
	fi
	return 1
}

main() {
	local first_add="" first_create="" persistent_guard="" trusted_cleanup=""
	first_add=$(grep -n 'await github\.rest\.issues\.addLabels' "$WORKFLOW" | head -1 | cut -d: -f1)
	first_create=$(grep -n 'await github\.rest\.issues\.createLabel' "$WORKFLOW" | head -1 | cut -d: -f1)
	persistent_guard=$(grep -n "issueLabels\.has('persistent')" "$WORKFLOW" | head -1 | cut -d: -f1)
	trusted_cleanup=$(grep -n 'if (authorIsTrusted)' "$WORKFLOW" | head -1 | cut -d: -f1)
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$first_add" =~ ^[0-9]+$ && "$first_create" =~ ^[0-9]+$ && "$first_add" -lt "$first_create" ]]; then
		printf 'PASS critical label application precedes label creation\n'
	else
		printf 'FAIL critical label application does not precede label creation\n' >&2
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$trusted_cleanup" =~ ^[0-9]+$ && "$persistent_guard" =~ ^[0-9]+$ && "$trusted_cleanup" -lt "$persistent_guard" ]]; then
		printf 'PASS trusted-author NMR cleanup precedes persistent non-task guard\n'
	else
		printf 'FAIL persistent non-task guard still bypasses trusted-author cleanup\n' >&2
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$persistent_guard" =~ ^[0-9]+$ && "$first_add" =~ ^[0-9]+$ && "$persistent_guard" -lt "$first_add" ]]; then
		printf 'PASS persistent non-task guard precedes triage label application\n'
	else
		printf 'FAIL persistent non-task guard does not precede triage label application\n' >&2
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	check_pattern "if \(!\[404, 422\]\.includes\(addError\.status\)\)" \
		"transient and quota failures are rethrown"
	check_pattern "lookupError\.status === 404" \
		"label creation requires an independent missing-label confirmation"
	check_pattern "const trustedRoles = \['OWNER', 'MEMBER'\]" \
		"bare collaborator association is excluded from trusted roles"
	check_pattern "issue\.user\.type === 'Bot' \|\|" \
		"trusted bots run through stale-NMR cleanup instead of returning early"
	check_pattern "hasExternalAuthoritySource = issueLabels\.has\('external-contributor'\)" \
		"trusted automation preserves explicit external-source authority gates"
	check_pattern "aidevops:origin:\(interactive\|worker\)" \
		"signed aidevops origin provenance is parsed from contributor issue bodies"
	check_pattern "const triageLabels = \['needs-maintainer-review', 'external-contributor'\]" \
		"external contributor authority and NMR labels are applied together"
	check_pattern "triageLabels\.push\(reportedOrigin\)" \
		"reported interactive or worker origin is restored by repository automation"
	check_pattern "reportedOrigin !== 'origin:worker'" \
		"unproven external worker labels are still stripped"
	check_pattern "collaborators/\{username\}/permission" \
		"collaborator authority uses the repository permission endpoint"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! check_permission_behavior "$WORKFLOW"; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	check_pattern "Run trusted-author cleanup first" \
		"persistent bypass documents trusted cleanup ordering"
	check_pattern "if \(!issueLabels\.has\(label\)\)" \
		"absent cleanup labels do not spend removal requests"
	check_pattern "Review label is applied but welcome comment failed" \
		"non-critical comment failure cannot undo the trust label"
	check_pattern "approve issue ' \+ issue\.number \+ ' ' \+ repoSlug" \
		"welcome approve command is repository-qualified"
	check_pattern "^  workflow_call:" "triage gate is a reusable workflow"
	check_pattern "repository: \\$\{\{ inputs\.aidevops_repository \|\| 'marcusquinn/aidevops' \}\}" \
		"scanner is fetched from the framework repository, not the caller"
	check_pattern "ref: \\$\{\{ inputs\.aidevops_ref \|\| 'main' \}\}" \
		"scanner checkout follows the pinned aidevops_ref"
	check_pattern "action === 'opened' && issueLabels\.has\('needs-maintainer-review'\)" \
		"trusted NMR cleanup is limited to creation"
	check_pattern "action === 'reopened' && hasExternalAuthoritySource" \
		"reopened issues already triaged are not re-gated"
	check_pattern "uses: \./\.github/workflows/issue-triage-gate-reusable\.yml" \
		"aidevops self-caller uses the reusable workflow" "$SELF_CALLER"
	check_pattern "uses: marcusquinn/aidevops/\.github/workflows/issue-triage-gate-reusable\.yml@main" \
		"downstream caller template uses the reusable workflow" "$CALLER_TEMPLATE"
	check_pattern "types: \[opened, reopened\]" \
		"downstream caller template triggers on opened and reopened" "$CALLER_TEMPLATE"
	check_pattern "^      aidevops_ref: main$" \
		"downstream caller couples aidevops_ref to the uses ref" "$CALLER_TEMPLATE"
	check_pattern "^  issues: write$" \
		"downstream caller grants the issues write ceiling" "$CALLER_TEMPLATE"

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
