#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#28466 runtime-risk PR body classification.

set -uo pipefail

# Resolve native Git once from the system default PATH (portable to non-FHS
# hosts such as NixOS); fixtures must bypass the aidevops git wrapper.
TEST_NATIVE_GIT=$(command -p -v git) || {
	printf '%s\n' 'Native Git is unavailable on the system PATH' >&2
	exit 1
}
export TEST_NATIVE_GIT

SCRIPT_DIR_TEST="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

print_error() {
	local message="$1"
	printf 'ERROR %s\n' "$message" >&2
	return 0
}

assert_contains() {
	local name="$1"
	local actual="$2"
	local expected="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == *"$expected"* ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s: missing %s\n' "$name" "$expected"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_rejected() {
	local name="$1"
	shift
	TESTS_RUN=$((TESTS_RUN + 1))
	if "$@" >/dev/null 2>&1; then
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	else
		printf 'PASS %s\n' "$name"
	fi
	return 0
}

assert_accepted() {
	local name="$1"
	shift
	TESTS_RUN=$((TESTS_RUN + 1))
	if "$@" >/dev/null 2>&1; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# shellcheck source=../full-loop-helper-risk.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-risk.sh"
# shellcheck source=../full-loop-helper-commit.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-commit.sh"

high_body=$(_build_pr_body \
	"28466" \
	"Fix polling-loop state-machine behavior" \
	"runtime-verified with a polling fixture" \
	"src/poller.sh, tests/test-poller.sh" \
	"<!-- aidevops:sig -->" \
	"Resolves")
assert_contains "polling fixture derives High" "$high_body" "**Risk level:** High"
assert_contains "High fixture records runtime evidence" "$high_body" "**Verification:** runtime-verified"
assert_contains "closing keyword remains compatible" "$high_body" "Resolves #28466"
assert_contains "signature remains compatible" "$high_body" "<!-- aidevops:sig -->"

assert_rejected "High without runtime evidence is rejected" \
	_build_pr_body "1" "API endpoint" "unit tests pass" "src/api.sh" ""
assert_rejected "Critical without runtime evidence is rejected" \
	_build_pr_body "2" "Credential rotation" "self-assessed" "src/auth.sh" "" "Resolves" "Critical" "self-assessed"
assert_rejected "explicit Low cannot bypass Critical runtime evidence" \
	_build_pr_body "2" "Delete data" "self-assessed" "src/storage.sh" "" "Resolves" "Low" "self-assessed"
assert_rejected "bare runtime marker is not evidence" \
	_build_pr_body "2" "Credential rotation" "runtime-verified" "src/auth.sh" ""
assert_rejected "bare no evidence is not evidence" \
	_runtime_evidence_is_substantive "no evidence"
assert_accepted "descriptive no evidence columns remains substantive" \
	_runtime_evidence_is_substantive "runtime-verified with activity rows returned, with no evidence columns"
assert_rejected "explicit runtime level still requires evidence" \
	_build_pr_body "2" "Credential rotation" "" "src/auth.sh" "" "Resolves" "Critical" "runtime-verified"

low_body=$(_build_pr_body \
	"3" \
	"Document credential and polling-loop behavior" \
	"focused tests pass" \
	"docs/runtime.md, .agents/scripts/tests/test-docs.sh, .qlty/qlty.toml, stubs/client.pyi" \
	"" \
	"Resolves")
assert_contains "non-runtime files remain Low despite policy terms" "$low_body" "**Risk level:** Low"
assert_contains "Low fixture is self-assessed" "$low_body" "**Verification:** self-assessed"

GLOB_REPO="${TEST_ROOT}/glob-repo"
mkdir -p "${GLOB_REPO}/src"
printf 'fixture\n' >"${GLOB_REPO}/src/a.sh"
glob_context=$(cd "$GLOB_REPO" && _runtime_paths_keyword_context 'src/[ab].sh')
assert_contains "runtime path context preserves glob metacharacters" "$glob_context" "src/[ab].sh"
for low_path in test-infra/deploy.sh test_harness/auth.py src/a.test.d/auth.sh src/auth.spec.d/session.ts src/splinter.config.js; do
	assert_rejected "directory/substring path is not Low: ${low_path}" _runtime_path_is_low "$low_path"
done
for low_path in tests/test-docs.sh foo.test.ts test_foo.py foo_test.go src/foo.test.ts pkg/foo_test.go commitlint.config.js; do
	assert_accepted "test/lint file stays Low: ${low_path}" _runtime_path_is_low "$low_path"
done
for low_path in _reports/brand-guidelines/brand-guidelines.html _reports/brand-guidelines/brand-guidelines-a4.pdf site/_reports/seo/chart.svg; do
	assert_accepted "generated report artifact is Low: ${low_path}" _runtime_path_is_low "$low_path"
done
for low_path in _reports/render.sh _reports/auth.js reports/page.html; do
	assert_rejected "non-artifact or non-_reports path is not Low: ${low_path}" _runtime_path_is_low "$low_path"
done
assert_rejected "invalid diff base fails closed" \
	_derive_runtime_risk "" "src/app.sh" "Adjust helper behavior" "missing-runtime-base"

author_body=$(_build_pr_body \
	"4" \
	"Update author metadata" \
	"focused tests pass" \
	"src/metadata.sh" \
	"" \
	"Resolves")
assert_contains "author does not false-match auth" "$author_body" "**Risk level:** Medium"

critical_body=$(_build_pr_body \
	"5" \
	"Change credential rotation" \
	"runtime-verified with a credential rotation fixture" \
	"src/auth.sh" \
	"" \
	"Resolves" \
	"Low")
assert_contains "explicit Low cannot downgrade Critical" "$critical_body" "**Risk level:** Critical"

raised_body=$(_build_pr_body \
	"6" \
	"Change ambiguous runtime behavior" \
	"runtime-verified with an integration fixture" \
	"src/worker.sh" \
	"" \
	"Resolves" \
	"High")
assert_contains "explicit risk can raise an ambiguous change" "$raised_body" "**Risk level:** High"

COMMENT_REPO="${TEST_ROOT}/comment-repo"
mkdir -p "${COMMENT_REPO}/src"
"$TEST_NATIVE_GIT" -C "$COMMENT_REPO" init -q
"$TEST_NATIVE_GIT" -C "$COMMENT_REPO" config user.name "Runtime Risk Test"
"$TEST_NATIVE_GIT" -C "$COMMENT_REPO" config user.email "runtime-risk@example.invalid"
printf '#!/usr/bin/env bash\nprintf "ok\\n"\n# Old credential comment.\n' >"${COMMENT_REPO}/src/app.sh"
"$TEST_NATIVE_GIT" -C "$COMMENT_REPO" add src/app.sh
"$TEST_NATIVE_GIT" -C "$COMMENT_REPO" -c commit.gpgSign=false commit -qm "fixture: add runtime file"
comment_base=$("$TEST_NATIVE_GIT" -C "$COMMENT_REPO" rev-parse HEAD)
printf '#!/usr/bin/env bash\nprintf "ok\\n"\n# New credential comment.\n' >"${COMMENT_REPO}/src/app.sh"
"$TEST_NATIVE_GIT" -C "$COMMENT_REPO" add src/app.sh
"$TEST_NATIVE_GIT" -C "$COMMENT_REPO" -c commit.gpgSign=false commit -qm "docs: update source comment"
comment_body=$(cd "$COMMENT_REPO" && _build_pr_body \
	"7" \
	"Update a source comment" \
	"diff reviewed" \
	"src/app.sh" \
	"" \
	"Resolves" \
	"" \
	"" \
	"$comment_base")
assert_contains "comment-only source change remains Low" "$comment_body" "**Risk level:** Low"

LITERAL_REPO="${TEST_ROOT}/literal-repo"
mkdir -p "${LITERAL_REPO}/src"
"$TEST_NATIVE_GIT" -C "$LITERAL_REPO" init -q
"$TEST_NATIVE_GIT" -C "$LITERAL_REPO" config user.name "Runtime Risk Test"
"$TEST_NATIVE_GIT" -C "$LITERAL_REPO" config user.email "runtime-risk@example.invalid"
printf 'export const ignored = [];\n' >"${LITERAL_REPO}/src/browser-qa.js"
"$TEST_NATIVE_GIT" -C "$LITERAL_REPO" add src/browser-qa.js
"$TEST_NATIVE_GIT" -C "$LITERAL_REPO" -c commit.gpgSign=false commit -qm "fixture: add browser QA helper"
literal_base=$("$TEST_NATIVE_GIT" -C "$LITERAL_REPO" rev-parse HEAD)
cat >"${LITERAL_REPO}/src/browser-qa.js" <<'EOF'
export const ignored = [
  /Session failed to send/i,
  "Session transport closed",
];
EOF
"$TEST_NATIVE_GIT" -C "$LITERAL_REPO" add src/browser-qa.js
"$TEST_NATIVE_GIT" -C "$LITERAL_REPO" -c commit.gpgSign=false commit -qm "fixture: filter browser diagnostics"
literal_body=$(cd "$LITERAL_REPO" && _build_pr_body \
	"29604" \
	"Filter browser console noise" \
	"focused tests pass" \
	"src/browser-qa.js" \
	"" \
	"Resolves" \
	"" \
	"" \
	"$literal_base")
assert_contains "quoted session diagnostics remain Medium" "$literal_body" "**Risk level:** Medium"

literal_session_base=$("$TEST_NATIVE_GIT" -C "$LITERAL_REPO" rev-parse HEAD)
printf 'export const session = createSession();\n' >>"${LITERAL_REPO}/src/browser-qa.js"
"$TEST_NATIVE_GIT" -C "$LITERAL_REPO" add src/browser-qa.js
"$TEST_NATIVE_GIT" -C "$LITERAL_REPO" -c commit.gpgSign=false commit -qm "fixture: add session management"
literal_session_body=$(cd "$LITERAL_REPO" && _build_pr_body \
	"29604" \
	"Change runtime behavior" \
	"runtime-verified with session lifecycle fixtures" \
	"src/browser-qa.js" \
	"" \
	"Resolves" \
	"" \
	"" \
	"$literal_session_base")
assert_contains "executable session behavior remains Critical" "$literal_session_body" "**Risk level:** Critical"

MIXED_REPO="${TEST_ROOT}/mixed-repo"
mkdir -p "${MIXED_REPO}/src" "${MIXED_REPO}/docs"
"$TEST_NATIVE_GIT" -C "$MIXED_REPO" init -q
"$TEST_NATIVE_GIT" -C "$MIXED_REPO" config user.name "Runtime Risk Test"
"$TEST_NATIVE_GIT" -C "$MIXED_REPO" config user.email "runtime-risk@example.invalid"
printf '#!/usr/bin/env bash\nprintf "old\\n"\n' >"${MIXED_REPO}/src/helper.sh"
printf 'Initial guide.\n' >"${MIXED_REPO}/docs/policy.md"
"$TEST_NATIVE_GIT" -C "$MIXED_REPO" add src/helper.sh docs/policy.md
"$TEST_NATIVE_GIT" -C "$MIXED_REPO" -c commit.gpgSign=false commit -qm "fixture: add mixed files"
mixed_base=$("$TEST_NATIVE_GIT" -C "$MIXED_REPO" rev-parse HEAD)
printf '#!/usr/bin/env bash\nprintf "new\\n"\n' >"${MIXED_REPO}/src/helper.sh"
printf 'Document auth, credentials, sessions, and data deletion policy.\n' >"${MIXED_REPO}/docs/policy.md"
"$TEST_NATIVE_GIT" -C "$MIXED_REPO" add src/helper.sh docs/policy.md
"$TEST_NATIVE_GIT" -C "$MIXED_REPO" -c commit.gpgSign=false commit -qm "fixture: change runtime and policy docs"
mixed_body=$(cd "$MIXED_REPO" && _build_pr_body \
	"8" \
	"Adjust helper output and policy documentation" \
	"focused tests pass" \
	"src/helper.sh, docs/policy.md" \
	"" \
	"Resolves" \
	"" \
	"" \
	"$mixed_base")
assert_contains "documentation keywords do not contaminate mixed runtime risk" "$mixed_body" "**Risk level:** Medium"

cat >"${MIXED_REPO}/src/helper.sh" <<'EOF'
#!/usr/bin/env bash
credential="enabled"
printf '%s\n' "$credential"
EOF
"$TEST_NATIVE_GIT" -C "$MIXED_REPO" add src/helper.sh
"$TEST_NATIVE_GIT" -C "$MIXED_REPO" -c commit.gpgSign=false commit -qm "fixture: add critical runtime behavior"
mixed_critical_body=$(cd "$MIXED_REPO" && _build_pr_body \
	"9" \
	"Adjust helper behavior and policy documentation" \
	"runtime-verified with the credential rotation fixture" \
	"src/helper.sh, docs/policy.md" \
	"" \
	"Resolves" \
	"" \
	"" \
	"$mixed_base")
assert_contains "critical runtime hunk remains Critical in a mixed diff" "$mixed_critical_body" "**Risk level:** Critical"

todo_data_risk=$(_derive_runtime_risk "" "todo/x/specs/a.json,todo/x/log/r/2026-10-18/a.jsonl,todo/x/a.md" "Add planning data about payments")
assert_contains "todo data files mentioning payments derive Low" "$todo_data_risk" "Low"
todo_runtime_risk=$(_derive_runtime_risk "" "todo/x/specs/a.json,src/billing.ts" "Add planning data about payments")
assert_contains "runtime file beside todo data still derives Critical" "$todo_runtime_risk" "Critical"

# The prompt-hook candidate registry is display-only metadata (GH#37972 follow-up).
registry_risk=$(_derive_runtime_risk "" ".agents/configs/prompt-hook-candidates.conf,.agents/reference/release-scope-sweep.md" "Add candidate: sessions share one account")
assert_contains "prompt-hook candidate registry derives Low despite policy terms" "<$registry_risk>" "<Low>"
other_conf_risk=$(_derive_runtime_risk "" ".agents/configs/self-hosting-files.conf" "Update session manager list")
assert_contains "other agent configs still derive Critical" "$other_conf_risk" "Critical"
noun_session_risk=$(_derive_runtime_risk "" ".agents/configs/self-hosting-files.conf" "Bump version for this session's PRs")
assert_contains "GH#40564 session noun in prose is not Critical" "<$noun_session_risk>" "<Medium>"
noun_store_risk=$(_derive_runtime_risk "" ".agents/configs/self-hosting-files.conf" "Set store version to 1.2")
assert_contains "GH#40564 non-session operand prose is not Critical" "<$noun_store_risk>" "<Medium>"
registry_runtime_risk=$(_derive_runtime_risk "" ".agents/configs/prompt-hook-candidates.conf,src/auth.sh" "Registry and auth change")
assert_contains "registry beside runtime code still derives Critical" "$registry_runtime_risk" "Critical"

# GH#38640: catalog app-test definitions (blueprints/<app>/test.yml) are Low even
# when fixture hunks mention authorization; look-alike test.yml paths are not.
APP_TEST_REPO="${TEST_ROOT}/app-test-repo"
app_test_paths="blueprints/app/test.yml blueprints/app/test.yaml config/settings/test.yml deploy/test.yaml blueprints/app/nested/test.yml vendor/blueprints/app/test.yml src/auth.sh"
mkdir -p "$APP_TEST_REPO"
"$TEST_NATIVE_GIT" -C "$APP_TEST_REPO" init -q
"$TEST_NATIVE_GIT" -C "$APP_TEST_REPO" config user.name "Runtime Risk Test"
"$TEST_NATIVE_GIT" -C "$APP_TEST_REPO" config user.email "runtime-risk@example.invalid"
for app_test_path in $app_test_paths; do
	mkdir -p "${APP_TEST_REPO}/${app_test_path%/*}"
	printf 'name: fixture\n' >"${APP_TEST_REPO}/${app_test_path}"
done
"$TEST_NATIVE_GIT" -C "$APP_TEST_REPO" add -A
"$TEST_NATIVE_GIT" -C "$APP_TEST_REPO" -c commit.gpgSign=false commit -qm "fixture: app-test base"
app_test_base=$("$TEST_NATIVE_GIT" -C "$APP_TEST_REPO" rev-parse HEAD)
for app_test_path in $app_test_paths; do
	printf 'name: fixture\nheaders:\n  authorization: fixture-header\n' >"${APP_TEST_REPO}/${app_test_path}"
done
"$TEST_NATIVE_GIT" -C "$APP_TEST_REPO" add -A
"$TEST_NATIVE_GIT" -C "$APP_TEST_REPO" -c commit.gpgSign=false commit -qm "fixture: authorization hunks"
for app_test_path in blueprints/app/test.yml blueprints/app/test.yaml; do
	app_test_risk=$(cd "$APP_TEST_REPO" && _derive_runtime_risk "" "$app_test_path" "Fix app test fixture" "$app_test_base")
	assert_contains "app-test definition ${app_test_path} derives Low" "<$app_test_risk>" "<Low>"
done
app_test_body=$(cd "$APP_TEST_REPO" && _build_pr_body \
	"38640" "Fix app test fixture" "app-test CI on the PR" "blueprints/app/test.yml" "" \
	"Resolves" "" "self-assessed" "$app_test_base")
assert_contains "app-test definition accepts self-assessed" "$app_test_body" "**Verification:** self-assessed"
app_test_mixed_risk=$(cd "$APP_TEST_REPO" && _derive_runtime_risk "" "blueprints/app/test.yml, src/auth.sh" "Fix app test fixture" "$app_test_base")
assert_contains "runtime file beside app-test definition still derives Critical" "<$app_test_mixed_risk>" "<Critical>"
for app_test_path in config/settings/test.yml deploy/test.yaml blueprints/app/nested/test.yml vendor/blueprints/app/test.yml; do
	app_test_risk=$(cd "$APP_TEST_REPO" && _derive_runtime_risk "" "$app_test_path" "Fix app test fixture" "$app_test_base")
	assert_contains "look-alike ${app_test_path} keeps Critical" "<$app_test_risk>" "<Critical>"
done

# GH#35709: runtime-owned leftovers must match product staging exclusions.
RUNTIME_STATE_REPO="${TEST_ROOT}/runtime-state-repo"
mkdir -p "${RUNTIME_STATE_REPO}/todo/x" "${RUNTIME_STATE_REPO}/.agents/loop-state/nested"
"$TEST_NATIVE_GIT" -C "$RUNTIME_STATE_REPO" init -q -b main
"$TEST_NATIVE_GIT" -C "$RUNTIME_STATE_REPO" config user.name "Runtime Risk Test"
"$TEST_NATIVE_GIT" -C "$RUNTIME_STATE_REPO" config user.email "runtime-risk@example.invalid"
printf 'Initial guide.\n' >"${RUNTIME_STATE_REPO}/todo/x/guide.md"
"$TEST_NATIVE_GIT" -C "$RUNTIME_STATE_REPO" add todo/x/guide.md
"$TEST_NATIVE_GIT" -C "$RUNTIME_STATE_REPO" commit -qm "fixture: planning data base"
printf 'Updated guide.\n' >"${RUNTIME_STATE_REPO}/todo/x/guide.md"
printf '{}\n' >"${RUNTIME_STATE_REPO}/todo/x/data.json"
printf '{}\n' >"${RUNTIME_STATE_REPO}/todo/x/log.jsonl"
printf 'LIFECYCLE_STATE=CLEANUP_DEFERRED\n' >"${RUNTIME_STATE_REPO}/.agents/.full-loop-cleanup-deferred"
printf 'session=active\n' >"${RUNTIME_STATE_REPO}/.agents/loop-state/nested/state"
runtime_state_files=$(cd "$RUNTIME_STATE_REPO" && _pending_runtime_files_changed HEAD)
assert_contains "pending files exclude marker and nested loop state" "<$runtime_state_files>" \
	"<todo/x/data.json, todo/x/guide.md, todo/x/log.jsonl>"
runtime_state_risk=$(_derive_runtime_risk "" "$runtime_state_files" "Add planning data in this session")
assert_contains "runtime leftovers do not elevate Low-only diff" "<$runtime_state_risk>" "<Low>"
runtime_state_body=$(cd "$RUNTIME_STATE_REPO" && _build_pr_body \
	"35709" "Add planning data in this session" "diff reviewed" "$runtime_state_files" "")
assert_contains "runtime leftovers do not block PR body generation" "$runtime_state_body" "**Risk level:** Low"
runtime_state_validation=$(cd "$RUNTIME_STATE_REPO" &&
	_validate_pending_runtime_metadata "" self-assessed "diff reviewed" "Add planning data in this session" HEAD &&
	printf 'accepted')
assert_contains "pending metadata accepts Low-only diff with runtime leftovers" "$runtime_state_validation" "accepted"
pending_in_runtime_state_repo() {
	(cd "$RUNTIME_STATE_REPO" && _validate_pending_runtime_metadata "$@")
	return $?
}
assert_rejected "GH#39831 pre-staging validation refuses Low runtime-pending" \
	pending_in_runtime_state_repo "" runtime-pending \
	"the publication step needs the pushed input; local validation passes" \
	"Add planning data in this session" HEAD
runtime_state_staging=$(cd "$RUNTIME_STATE_REPO" && _stage_product_changes &&
	git diff --cached --name-only | LC_ALL=C sort | tr '\n' ',')
assert_contains "product staging matches pending risk paths" "<$runtime_state_staging>" \
	"<todo/x/data.json,todo/x/guide.md,todo/x/log.jsonl,>"
printf 'export const session = createSession();\n' >"${RUNTIME_STATE_REPO}/.agents/loop-state-product.js"
runtime_neighbor_files=$(cd "$RUNTIME_STATE_REPO" && _pending_runtime_files_changed HEAD)
assert_contains "similarly named product path remains in pending files" "$runtime_neighbor_files" ".agents/loop-state-product.js"
runtime_neighbor_risk=$(_derive_runtime_risk "" "$runtime_neighbor_files" "Update session handler")
assert_contains "runtime exclusions do not downgrade adjacent product code" "$runtime_neighbor_risk" "Critical"
"$TEST_NATIVE_GIT" -C "$RUNTIME_STATE_REPO" add .agents/.full-loop-cleanup-deferred
stage_in_runtime_state_repo() {
	(cd "$RUNTIME_STATE_REPO" && _stage_product_changes) || return 1
	return 0
}
assert_rejected "pre-staged runtime marker remains rejected" \
	stage_in_runtime_state_repo

runtime_risk=""
testing_level=""
issue_number=""
commit_message=""
pr_title=""
summary_what=""
summary_testing=""
summary_decisions=""
allow_parent_close=0
skip_hooks=0
skip_rebase=0
extra_labels=()
_parse_commit_and_pr_args --issue 4 --message "test" --risk-level High --testing-level runtime-verified
assert_contains "risk level flag is accepted" "$runtime_risk" "High"
assert_contains "testing level flag is accepted" "$testing_level" "runtime-verified"

ORDERING_BIN="${TEST_ROOT}/ordering-bin"
ORDERING_TRACE="${TEST_ROOT}/ordering-trace"
mkdir -p "$ORDERING_BIN"
cat >"${ORDERING_BIN}/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$ORDERING_TRACE"
if [[ "$1" == "branch" && "$2" == "--show-current" ]]; then
	printf 'feature/metadata-ordering\n'
fi
exit 0
EOF
cat >"${ORDERING_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$ORDERING_TRACE"
if [[ "$1" == "repo" && "$2" == "view" ]]; then
	printf 'example/ordering\n'
fi
exit 0
EOF
chmod +x "${ORDERING_BIN}/git" "${ORDERING_BIN}/gh"

for invalid_flag in "--testing-level invalid" "--risk-level invalid"; do
	invalid_option="${invalid_flag%% *}"
	invalid_value="${invalid_flag#* }"
	: >"$ORDERING_TRACE"
	if PATH="${ORDERING_BIN}:$PATH" ORDERING_TRACE="$ORDERING_TRACE" \
		"${SCRIPT_DIR_TEST}/full-loop-helper.sh" commit-and-pr --issue 4 --message "fix: validate metadata" "$invalid_option" "$invalid_value" >/dev/null 2>&1; then
		printf 'FAIL invalid metadata is rejected before mutation: %s\n' "$invalid_flag"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	else
		if grep -Eq '^git (add|commit|rebase|push)|^gh (pr|api .*POST)' "$ORDERING_TRACE"; then
			printf 'FAIL invalid metadata avoids Git and GitHub mutations: %s\n' "$invalid_flag"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		else
			printf 'PASS invalid metadata avoids Git and GitHub mutations: %s\n' "$invalid_flag"
		fi
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
done

MUTATION_REMOTE="${TEST_ROOT}/mutation-remote.git"
MUTATION_REPO="${TEST_ROOT}/mutation-repo"
MUTATION_BIN="${TEST_ROOT}/mutation-bin"
MUTATION_TRACE="${TEST_ROOT}/mutation-trace"
mkdir -p "$MUTATION_BIN"
"$TEST_NATIVE_GIT" init -q --bare "$MUTATION_REMOTE"
"$TEST_NATIVE_GIT" init -q -b main "$MUTATION_REPO"
"$TEST_NATIVE_GIT" -C "$MUTATION_REPO" config user.name "Runtime Risk Test"
"$TEST_NATIVE_GIT" -C "$MUTATION_REPO" config user.email "runtime-risk@example.invalid"
printf 'base\n' >"${MUTATION_REPO}/README.md"
"$TEST_NATIVE_GIT" -C "$MUTATION_REPO" add README.md
"$TEST_NATIVE_GIT" -C "$MUTATION_REPO" -c commit.gpgSign=false commit -qm "fixture: base"
"$TEST_NATIVE_GIT" -C "$MUTATION_REPO" remote add origin "$MUTATION_REMOTE"
"$TEST_NATIVE_GIT" -C "$MUTATION_REPO" push -q -u origin main
"$TEST_NATIVE_GIT" -C "$MUTATION_REPO" remote set-head origin main
"$TEST_NATIVE_GIT" -C "$MUTATION_REPO" switch -q -c feature/risk-order
mkdir -p "${MUTATION_REPO}/src"
printf '#!/usr/bin/env bash\ncredential_rotation="enabled"\n' >"${MUTATION_REPO}/src/auth.sh"

cat >"${MUTATION_BIN}/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$MUTATION_TRACE"
exec "$TEST_NATIVE_GIT" "$@"
EOF
cat >"${MUTATION_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$MUTATION_TRACE"
if [[ "$1" == "repo" && "$2" == "view" ]]; then
	printf 'example/ordering\n'
fi
# No open PRs, so the read-only linkage check passes and the helper reaches
# runtime-evidence validation, the path this case exercises (t18796).
if [[ "$1" == "pr" && "$2" == "list" ]]; then
	printf '[]\n'
fi
exit 0
EOF
chmod +x "${MUTATION_BIN}/git" "${MUTATION_BIN}/gh"
: >"$MUTATION_TRACE"
mutation_head_before=$("$TEST_NATIVE_GIT" -C "$MUTATION_REPO" rev-parse HEAD)
if (cd "$MUTATION_REPO" && PATH="${MUTATION_BIN}:$PATH" MUTATION_TRACE="$MUTATION_TRACE" \
	"${SCRIPT_DIR_TEST}/full-loop-helper.sh" commit-and-pr --issue 9 --message "fix: update runtime behavior" \
	--summary "Adjust helper behavior" --testing "unit tests pass" >"${MUTATION_TRACE}.err" 2>&1); then
	printf 'FAIL commit-and-pr accepted invalid derived runtime evidence\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
elif grep -Eq '^git (add|commit|rebase|reset|push)|^gh (pr (create|edit|merge|ready|comment|close|review)|api .*POST)' "$MUTATION_TRACE" ||
	! grep -q 'requires runtime-verified evidence' "${MUTATION_TRACE}.err" ||
	[[ "$("$TEST_NATIVE_GIT" -C "$MUTATION_REPO" rev-parse HEAD)" != "$mutation_head_before" ]] ||
	"$TEST_NATIVE_GIT" --git-dir="$MUTATION_REMOTE" show-ref --verify --quiet refs/heads/feature/risk-order; then
	printf 'FAIL invalid derived evidence allowed local or remote mutations\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
else
	printf 'PASS invalid derived evidence avoids local and remote mutations\n'
fi
TESTS_RUN=$((TESTS_RUN + 1))

prevalidation_line=$(grep -n '^[[:space:]]*_validate_pending_runtime_metadata ' \
	"${SCRIPT_DIR_TEST}/full-loop-helper.sh" | cut -d: -f1)
stage_line=$(grep -n '^[[:space:]]*_stage_and_commit ' \
	"${SCRIPT_DIR_TEST}/full-loop-helper.sh" | cut -d: -f1)
if [[ "$prevalidation_line" =~ ^[0-9]+$ && "$stage_line" =~ ^[0-9]+$ &&
	"$prevalidation_line" -lt "$stage_line" ]]; then
	printf 'PASS pending runtime evidence validation precedes staging\n'
else
	printf 'FAIL pending runtime evidence validation must precede staging\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
fi
TESTS_RUN=$((TESTS_RUN + 1))

# GH#31300: incoming sensitive code must not become a local deletion or hunk.
BEHIND_REPO="${TEST_ROOT}/behind-repo"
mkdir -p "${BEHIND_REPO}/src"
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" init -q -b main
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" config user.name "Runtime Risk Test"
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" config user.email "runtime-risk@example.invalid"
printf 'export const value = 1;\n' >"${BEHIND_REPO}/src/helper.js"
printf 'Initial guide.\n' >"${BEHIND_REPO}/README.md"
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" add .
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" -c commit.gpgSign=false commit -qm "fixture: shared base"
behind_base=$("$TEST_NATIVE_GIT" -C "$BEHIND_REPO" rev-parse HEAD)
printf 'export const credential = rotateCredential();\n' >"${BEHIND_REPO}/src/helper.js"
printf 'export const session = createSession();\n' >"${BEHIND_REPO}/src/auth.js"
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" add .
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" -c commit.gpgSign=false commit -qm "fixture: upstream sensitive code"
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" switch -q -c feature/behind "$behind_base"
printf 'Updated guide.\n' >"${BEHIND_REPO}/README.md"
behind_result=$(cd "$BEHIND_REPO" &&
	_validate_pending_runtime_metadata Low self-assessed "diff reviewed" "Update guide" main &&
	printf 'accepted')
assert_contains "behind-base docs remain Low/self-assessed" "$behind_result" "accepted"
behind_files=$(cd "$BEHIND_REPO" &&
	_pending_runtime_files_changed "$(_pending_runtime_comparison_base main)")
assert_contains "pending file list excludes upstream-only paths" "<$behind_files>" "<README.md>"

# Same path changed on both sides: keyword context must use the ownership base,
# not include removal of upstream credentials in a harmless local code change.
printf 'export const value = 2;\n' >"${BEHIND_REPO}/src/helper.js"
behind_result=$(cd "$BEHIND_REPO" &&
	_validate_pending_runtime_metadata Medium self-assessed "diff reviewed" "Adjust helper" main &&
	printf 'accepted')
assert_contains "file list and keyword context share branch ownership" "$behind_result" "accepted"

# Both index and working-tree changes are part of the prospective final tree.
printf 'export const credential = rotateCredential();\n' >"${BEHIND_REPO}/src/helper.js"
pending_in_behind_repo() {
	(cd "$BEHIND_REPO" && _validate_pending_runtime_metadata "$@")
	return $?
}
assert_rejected "unstaged sensitive code requires runtime evidence" \
	pending_in_behind_repo Low self-assessed "diff reviewed" "Adjust helper" main
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" add src/helper.js
assert_rejected "staged sensitive code requires runtime evidence" \
	pending_in_behind_repo Low self-assessed "diff reviewed" "Adjust helper" main
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" -c commit.gpgSign=false commit -qm "fixture: local sensitive commit"
assert_rejected "local sensitive commit cannot hide behind upstream identical content" \
	pending_in_behind_repo Low self-assessed "diff reviewed" "Adjust helper" main
behind_result=$(pending_in_behind_repo Low runtime-verified \
	"runtime-verified with credential rotation fixture" "Adjust helper" main && printf 'accepted')
assert_contains "substantive runtime evidence accepts local sensitive code" "$behind_result" "accepted"

# Restore harmless tracked code with a local commit, then exercise untracked risk.
printf 'export const value = 1;\n' >"${BEHIND_REPO}/src/helper.js"
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" add src/helper.js
"$TEST_NATIVE_GIT" -C "$BEHIND_REPO" -c commit.gpgSign=false commit -qm "fixture: restore harmless code"
printf 'export const session = createSession();\n' >"${BEHIND_REPO}/src/session.js"
behind_status_before=$("$TEST_NATIVE_GIT" -C "$BEHIND_REPO" status --porcelain=v1)
behind_head_before=$("$TEST_NATIVE_GIT" -C "$BEHIND_REPO" rev-parse HEAD)
assert_rejected "untracked sensitive code requires runtime evidence behind base" \
	pending_in_behind_repo Low self-assessed "diff reviewed" "Adjust helper" main
assert_contains "rejected prevalidation preserves index and working tree" \
	"<$("$TEST_NATIVE_GIT" -C "$BEHIND_REPO" status --porcelain=v1)>" "<$behind_status_before>"
assert_contains "rejected prevalidation preserves HEAD" \
	"<$("$TEST_NATIVE_GIT" -C "$BEHIND_REPO" rev-parse HEAD)>" "<$behind_head_before>"
assert_rejected "missing comparison ref fails closed for pending work" \
	pending_in_behind_repo Low self-assessed "diff reviewed" "Update guide" missing-base
unrelated_tree=$("$TEST_NATIVE_GIT" -C "$BEHIND_REPO" rev-parse 'main^{tree}')
unrelated_base=$(printf 'unrelated root\n' | "$TEST_NATIVE_GIT" -C "$BEHIND_REPO" -c commit.gpgSign=false commit-tree "$unrelated_tree")
assert_rejected "unrelated comparison history fails closed" \
	pending_in_behind_repo Low self-assessed "diff reviewed" "Update guide" "$unrelated_base"

# Final metadata uses the same ownership base as pending validation (GH#34465).
final_result=$(cd "$BEHIND_REPO" && _derive_runtime_risk Low src/helper.js "Adjust helper" \
	"$(_pending_runtime_comparison_base main)" HEAD)
assert_contains "final committed diff excludes upstream-sensitive hunks" "$final_result" "Medium"

# Exercise the real metadata orchestration without GitHub writes or signatures.
eval "$(sed -n '/^_diff_is_planning_only() {/,/^}/p' "${SCRIPT_DIR_TEST}/full-loop-helper.sh")"
eval "$(sed -n '/^_commit_and_pr_platform_evidence_preflight() {/,/^}/p' "${SCRIPT_DIR_TEST}/full-loop-helper.sh")"
eval "$(sed -n '/^_commit_and_pr_prepare_metadata() {/,/^}/p' "${SCRIPT_DIR_TEST}/full-loop-helper.sh")"
_resolve_remote_default_branch() {
	printf 'main\n'
	return 0
}
_resolve_pr_base_branch() {
	_resolve_remote_default_branch "$@"
	return $?
}
session_origin_label() {
	printf 'origin:worker\n'
	return 0
}
_issue_has_parent_task_label() {
	return 1
}
# GH#38518: the metadata path also calls these; keep the fixture offline.
macos_checks_evidence() {
	return 0
}
_gh_with_timeout() {
	return 0
}
print_info() {
	local message="$1"
	printf '%s\n' "$message" >&2
	return 0
}
prepare_fixture_metadata() {
	local summary_what="$1" summary_testing="$2"
	local SCRIPT_DIR="${TEST_ROOT}/no-helper-binaries"
	local completion_bookkeeping=0 closing_keyword=Resolves base_branch="" base_ref=""
	local issue_number=34465 files_changed="" pr_body="" runtime_risk="" testing_level=""
	local pr_title="Fixture" commit_message="fix: fixture" origin_label="" repo="example/fixture"
	local allow_parent_close=0 planning_only=0 replacement_pr="" replacement_reason=""
	local keep_issue_open=0 replacement_pr_head_sha="" summary_decisions=""
	_commit_and_pr_prepare_metadata || return 1
	printf '%s\n' "$pr_body"
	return 0
}

FINAL_REPO="${TEST_ROOT}/final-repo"
mkdir -p "${FINAL_REPO}/src"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" init -q -b main
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" config user.name "Runtime Risk Test"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" config user.email "runtime-risk@example.invalid"
printf 'export const value = 1;\n' >"${FINAL_REPO}/src/helper.js"
printf '%s\n' '- [ ] t1 Finish task ref:GH#34465' >"${FINAL_REPO}/TODO.md"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" add .
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" commit -qm "fixture: shared base"
final_base=$("$TEST_NATIVE_GIT" -C "$FINAL_REPO" rev-parse HEAD)
printf 'export const credential = rotateCredential();\n' >"${FINAL_REPO}/src/helper.js"
printf 'export const payment = charge();\n' >"${FINAL_REPO}/src/billing.js"
printf '%s\n' '- [ ] t2 Upstream task' >>"${FINAL_REPO}/TODO.md"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" add .
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" commit -qm "fixture: upstream sensitive changes"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" update-ref refs/remotes/origin/main HEAD
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" switch -q -c feature/final "$final_base"
printf 'export const value = 2;\n' >"${FINAL_REPO}/src/helper.js"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" add .
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" commit -qm "fixture: harmless branch change"
final_body=$(cd "$FINAL_REPO" && prepare_fixture_metadata "Adjust helper" "diff reviewed")
assert_contains "metadata lists only branch files" "$final_body" $'## Files Changed\n\nsrc/helper.js\n'
assert_contains "metadata risk ignores upstream sensitive changes" "$final_body" '**Risk level:** Medium'
prepare_partial_closing_metadata() {
	(cd "$FINAL_REPO" && prepare_fixture_metadata "For #34465: remaining items" "diff reviewed") || return 1
	return 0
}
assert_rejected "GH#38823 final closing metadata rejects partial self-reference" \
	prepare_partial_closing_metadata
final_pending=$(cd "$FINAL_REPO" && _validate_pending_runtime_metadata Medium self-assessed \
	"diff reviewed" "Adjust helper" origin/main && printf accepted)
assert_contains "pending and final risk agree behind upstream" "$final_pending" accepted

"$TEST_NATIVE_GIT" -C "$FINAL_REPO" switch -q -c feature/bookkeeping "$final_base"
printf '%s\n' '- [x] t1 Finish task ref:GH#34465 pr:#123 completed:2026-10-12' >"${FINAL_REPO}/TODO.md"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" add TODO.md
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" commit -qm "fixture: completion proof"
bookkeeping_result=$(cd "$FINAL_REPO" &&
	_validate_completion_bookkeeping_paths t1 origin/main &&
	_validate_completion_bookkeeping_todo 34465 123 t1 origin/main && printf accepted)
assert_contains "TODO-only bookkeeping excludes upstream files and TODO edits" "$bookkeeping_result" accepted
planning_body=$(cd "$FINAL_REPO" && prepare_fixture_metadata "Record completion" "diff reviewed")
assert_contains "planning classification excludes upstream files" "$planning_body" 'For #34465'
partial_planning_body=$(cd "$FINAL_REPO" && prepare_fixture_metadata "For #34465: planning checkpoint" "diff reviewed")
assert_contains "GH#38823 planning checkpoint allows partial self-reference" "$partial_planning_body" $'self-assessed — diff reviewed\n\nFor #34465'

# GH#36002: nested markdown under todo/ stays planning; data files under todo/
# are deliverables, alone or mixed with planning files.
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" switch -q -c feature/todo-markdown "$final_base"
mkdir -p "${FINAL_REPO}/todo/tasks"
printf '%s\n' '# t1 brief' >"${FINAL_REPO}/todo/tasks/t1-brief.md"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" add todo
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" commit -qm "fixture: nested planning brief"
markdown_body=$(cd "$FINAL_REPO" && prepare_fixture_metadata "Add brief" "diff reviewed")
assert_contains "nested todo markdown is planning-only" "$markdown_body" 'For #34465'

"$TEST_NATIVE_GIT" -C "$FINAL_REPO" switch -q -c feature/todo-data "$final_base"
mkdir -p "${FINAL_REPO}/todo/award-enrichment/log/runner"
printf '%s\n' '{"status":"found"}' >"${FINAL_REPO}/todo/award-enrichment/log/runner/example.jsonl"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" add todo
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" commit -qm "fixture: data deliverable under todo"
data_body=$(cd "$FINAL_REPO" && prepare_fixture_metadata "Record outcomes" "diff reviewed")
assert_contains "todo data file is a deliverable" "$data_body" 'Resolves #34465'

"$TEST_NATIVE_GIT" -C "$FINAL_REPO" switch -q -c feature/todo-mixed "$final_base"
mkdir -p "${FINAL_REPO}/todo/award-enrichment/specs"
printf '%s\n' '{"spec":1}' >"${FINAL_REPO}/todo/award-enrichment/specs/example.json"
printf '%s\n' '- [ ] t3 Record outcomes' >>"${FINAL_REPO}/TODO.md"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" add .
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" commit -qm "fixture: data deliverable with TODO entry"
mixed_body=$(cd "$FINAL_REPO" && prepare_fixture_metadata "Record outcomes" "diff reviewed")
assert_contains "todo data with TODO.md is a deliverable" "$mixed_body" 'Resolves #34465'

# A data-to-markdown rename still removes a deliverable, even though the
# destination alone would qualify as planning. Seed the data in the base so
# the branch diff contains only the rename, not the initial data addition.
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" switch -q -c feature/todo-rename-base "$final_base"
mkdir -p "${FINAL_REPO}/todo/specs"
printf '%s\n' '{"spec":1}' >"${FINAL_REPO}/todo/specs/example.json"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" add todo
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" commit -qm "fixture: base data deliverable"
rename_base=$("$TEST_NATIVE_GIT" -C "$FINAL_REPO" rev-parse HEAD)
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" switch -q -c feature/todo-rename
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" mv todo/specs/example.json todo/specs/example.md
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" commit -qm "fixture: rename data to markdown"
renamed_data_is_planning_only() {
	(cd "$FINAL_REPO" && _diff_is_planning_only "$rename_base") || return 1
	return 0
}
assert_rejected "data-to-markdown rename is not planning-only" \
	renamed_data_is_planning_only

"$TEST_NATIVE_GIT" -C "$FINAL_REPO" switch -q feature/final
printf 'export const payment = charge();\n' >"${FINAL_REPO}/src/billing.js"
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" add .
"$TEST_NATIVE_GIT" -C "$FINAL_REPO" commit -qm "fixture: branch sensitive change"
prepare_local_critical_metadata() {
	(cd "$FINAL_REPO" && prepare_fixture_metadata "Adjust helper" "diff reviewed")
	return $?
}
assert_rejected "final metadata rejects local Critical change without runtime evidence" \
	prepare_local_critical_metadata
critical_final_body=$(cd "$FINAL_REPO" && prepare_fixture_metadata "Adjust helper" \
	"runtime-verified with sensitive branch fixture")
assert_contains "local Critical change still derives Critical" "$critical_final_body" '**Risk level:** Critical'

assert_rejected "GH#38823 worker summary For #<dispatched issue> is refused" \
	_summary_declares_partial_self 42 "Partial work. For #42: remaining items" "ok"
assert_rejected "GH#38823 Ref #<dispatched issue> in testing is refused" \
	_summary_declares_partial_self 42 "done" "see ref #42"
assert_accepted "GH#38823 reference to another issue is allowed" \
	_summary_declares_partial_self 42 "Follow-up for #43" "ok"

# GH#39558: runtime-pending is the legitimate route when a runner cannot
# exercise a Critical/High change; the PR opens held and cannot merge.
pending_reason="runner has no review copy with Stripe test mode; unit tests pass"
pending_body=$(_build_pr_body "2" "Credential rotation" "$pending_reason" "src/auth.sh" "" \
	"Resolves" "" "RUNTIME-PENDING")
assert_contains "runtime-pending accepted for Critical with a reason" "$pending_body" "**Risk level:** Critical"
assert_contains "body records runtime-pending and its reason" "$pending_body" \
	"**Verification:** runtime-pending — ${pending_reason}"
assert_rejected "runtime-pending without a reason is rejected" \
	_build_pr_body "2" "Credential rotation" "" "src/auth.sh" "" "Resolves" "Critical" "runtime-pending"
assert_rejected "runtime-pending with a placeholder reason is rejected" \
	_build_pr_body "2" "Credential rotation" "none" "src/auth.sh" "" "Resolves" "Critical" "runtime-pending"
assert_rejected "runtime-pending with only its own marker is rejected" \
	_build_pr_body "2" "Credential rotation" "Runtime pending." "src/auth.sh" "" "Resolves" "Critical" "runtime-pending"
assert_rejected "a summary carrying a Runtime Testing heading is rejected" \
	_build_pr_body "2" $'Example:\n## Runtime Testing\n- **Risk level:** Low' "$pending_reason" \
	"src/auth.sh" "" "Resolves" "Critical" "runtime-pending"
assert_accepted "explicit runtime-pending passes pre-mutation validation" \
	_validate_explicit_pr_metadata "" "runtime-pending"
refusal_guidance=$(_build_pr_body "2" "Credential rotation" "self-assessed" "src/auth.sh" "" \
	"Resolves" "Critical" "self-assessed" 2>&1 >/dev/null)
assert_contains "Critical refusal names the runtime-pending route" "$refusal_guidance" \
	"--testing-level runtime-pending"

# GH#39831: below Critical/High the hold protects nothing, so runtime-pending
# is refused with the push-and-continue route instead of parking the work.
deferred_reason="the publication step needs the pushed input; local validation passes"
assert_rejected "runtime-pending is refused at Low risk" \
	_build_pr_body "2" "Docs wording" "$deferred_reason" "README.md" "" "Resolves" "Low" "runtime-pending"
assert_rejected "runtime-pending is refused at Medium risk" \
	_build_pr_body "2" "Widget label" "$deferred_reason" "src/widget.ts" "" "Resolves" "Medium" "runtime-pending"
low_pending_guidance=$(_build_pr_body "2" "Docs wording" "$deferred_reason" "README.md" "" \
	"Resolves" "Low" "runtime-pending" 2>&1 >/dev/null)
assert_contains "Low refusal names the push-and-continue route" "$low_pending_guidance" "git push -u origin HEAD"
assert_contains "Low refusal names the blocker route" "$low_pending_guidance" "terminal blocker"
assert_accepted "runtime-pending stays accepted at High risk" \
	_build_pr_body "2" "Polling loop" "$deferred_reason" "src/poller.sh" "" "Resolves" "High" "runtime-pending"

assert_accepted "commit-and-pr detects a runtime-pending body for the hold" \
	_pr_body_declares_runtime_pending "$pending_body"
assert_rejected "runtime-verified body takes no runtime hold" \
	_pr_body_declares_runtime_pending "$high_body"

merge_refusal_for_body() {
	local body="$1"
	local metadata=""
	metadata=$(printf '%s' "$body" | _runtime_testing_metadata_from_body) || return 1
	_runtime_testing_merge_refusal "$metadata"
	return $?
}
pending_refusal=$(merge_refusal_for_body "$pending_body")
assert_contains "merge refusal explains pending verification" "$pending_refusal" \
	"runtime verification is pending"
assert_rejected "merge refuses a runtime-pending body" merge_refusal_for_body "$pending_body"
assert_accepted "merge accepts High with runtime-verified evidence" merge_refusal_for_body "$high_body"
downgraded_body="${high_body/\*\*Verification:\*\* runtime-verified/**Verification:** self-assessed}"
assert_rejected "merge refuses a hand-edited High downgrade" merge_refusal_for_body "$downgraded_body"
bare_marker_body="${high_body/runtime-verified with a polling fixture/runtime-verified}"
assert_rejected "merge refuses High with a bare runtime marker" merge_refusal_for_body "$bare_marker_body"
assert_accepted "merge accepts Low self-assessed" merge_refusal_for_body "$low_body"
assert_accepted "merge accepts a body without a Runtime Testing section" \
	merge_refusal_for_body $'## Summary\n\nHand-written body.\n\nResolves #12'
assert_rejected "merge refuses unreadable runtime metadata" _runtime_testing_merge_refusal '{}'
example_section_body=$'## Runtime Testing\n\n- **Risk level:** Low\n- **Verification:** self-assessed — example\n\n'"$pending_body"
assert_rejected "merge refuses ambiguous multi-section metadata" merge_refusal_for_body "$example_section_body"
assert_accepted "ambiguous metadata takes the runtime hold" \
	_pr_body_declares_runtime_pending "$example_section_body"

# Review findings on PR #39569: negated pending reasons, multiline evidence
# with bold bullets, and malformed metadata lines.
negated_pending_body=$(_build_pr_body "2" "Credential rotation" \
	"not runtime-verified: this runner has no Stripe sandbox; unit tests pass" \
	"src/auth.sh" "" "Resolves" "Critical" "runtime-pending")
assert_contains "runtime-pending accepts a negated-claim reason" "$negated_pending_body" \
	"**Verification:** runtime-pending — not runtime-verified"
assert_rejected "runtime-pending with only a negated claim is rejected" \
	_build_pr_body "2" "Credential rotation" "Not runtime-verified." "src/auth.sh" "" \
	"Resolves" "Critical" "runtime-pending"
assert_rejected "runtime-verified still rejects a negated claim" \
	_build_pr_body "2" "Credential rotation" "not runtime-verified: unit tests pass" "src/auth.sh" "" \
	"Resolves" "Critical" "runtime-verified"
multiline_body=$(_build_pr_body "2" "Credential rotation" \
	$'\n- **Check:** polling fixture passed' "src/auth.sh" "" "Resolves" "Critical" "runtime-verified")
multiline_evidence=$(printf '%s' "$multiline_body" | _runtime_testing_metadata_from_body | jq -r '.evidence')
assert_contains "multiline evidence with bold bullets is parsed whole" "$multiline_evidence" \
	"- Check: polling fixture passed"
assert_accepted "merge accepts Critical with multiline runtime-verified evidence" \
	merge_refusal_for_body "$multiline_body"
tabbed_risk_body="${high_body/\*\*Risk level:\*\* High/**Risk level:**	High}"
assert_rejected "merge refuses a tab-separated High risk without verified evidence" \
	merge_refusal_for_body "${tabbed_risk_body/\*\*Verification:\*\* runtime-verified/**Verification:** self-assessed}"
unknown_risk_body="${low_body/\*\*Risk level:\*\* Low/**Risk level:**}"
assert_rejected "merge refuses a present section with no recognized risk" \
	merge_refusal_for_body "$unknown_risk_body"
undelimited_body=$'## Runtime Testing\n\n- **Risk level:** Low\n- **Verification:** runtime-pending\n'
assert_rejected "merge refuses a Verification line without its evidence delimiter" \
	merge_refusal_for_body "$undelimited_body"

# shellcheck disable=SC2312
eval "$(sed -n '/^_merge_check_runtime_evidence() {/,/^}/p' "${SCRIPT_DIR_TEST}/full-loop-helper-merge.sh")"
_flm_gh_read() { return 1; }
assert_rejected "merge helper refuses a runtime-pending PR body" \
	_merge_check_runtime_evidence 7 owner/repo "$(jq -cn --arg body "$pending_body" '{body:$body}')"
assert_accepted "merge helper accepts runtime-verified PR body" \
	_merge_check_runtime_evidence 7 owner/repo "$(jq -cn --arg body "$high_body" '{body:$body}')"
assert_rejected "merge helper fails closed when the body read fails" \
	_merge_check_runtime_evidence 7 owner/repo ""

# GH#40444: exercise the production waiver entry points with local approval
# and audit transports. No live merge or maintainer credentials are used.
for waiver_function in _merge_parse_command_args _merge_prepare_rbg_override \
	_merge_prepare_runtime_waiver _merge_verify_runtime_waiver_approval \
	_merge_lift_runtime_waiver_hold _merge_record_runtime_waiver _merge_execute; do
	# shellcheck disable=SC2312
	eval "$(sed -n "/^${waiver_function}() {/,/^}/p" "${SCRIPT_DIR_TEST}/full-loop-helper-merge.sh")"
done
# shellcheck source=../full-loop-helper-verify-runtime.sh
source "${SCRIPT_DIR_TEST}/full-loop-helper-verify-runtime.sh"
SCRIPT_DIR="${TEST_ROOT}/waiver"
mkdir -p "$SCRIPT_DIR"
cat >"${SCRIPT_DIR}/approval-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${WAIVER_LOG}.approval"
printf '%s\n' "${WAIVER_VERDICT:-VERIFIED}"
exit "${WAIVER_APPROVAL_RC:-0}"
STUB
cat >"${SCRIPT_DIR}/audit-log-helper.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${WAIVER_LOG}.audit"
STUB
chmod +x "${SCRIPT_DIR}/approval-helper.sh" "${SCRIPT_DIR}/audit-log-helper.sh"
export WAIVER_LOG="${SCRIPT_DIR}/record"
waiver_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
waiver_reason="No paid sandbox is available; documented API and local checks reviewed"
_FULL_LOOP_RBG_OVERRIDE_MIN_REASON_CHARS=20
FULL_LOOP_MERGE_BODY_FILE_FLAG=--body-file
_merge_is_headless_session() { [[ "${waiver_headless:-false}" == true ]] && return 0; return 1; }
approval_cli_prefix() { printf 'aidevops'; return 0; }
waiver_headless=true
assert_rejected "headless waiver refuses before remote reads" \
	_merge_parse_command_args "--waive-runtime-verification=${waiver_reason}"
waiver_headless=false
assert_rejected "short waiver reason refuses" _merge_parse_command_args '--waive-runtime-verification=too short'
assert_rejected "blank waiver reason refuses" _merge_parse_command_args '--waive-runtime-verification=                      '
assert_rejected "empty waiver reason refuses" _merge_parse_command_args '--waive-runtime-verification='
assert_rejected "bare waiver flag refuses" _merge_parse_command_args --waive-runtime-verification
assert_rejected "duplicate waiver flag refuses" _merge_parse_command_args \
	"--waive-runtime-verification=${waiver_reason}" "--waive-runtime-verification=${waiver_reason}"
assert_rejected "waiver cannot queue auto-merge" _merge_parse_command_args \
	--auto "--waive-runtime-verification=${waiver_reason}"
assert_accepted "interactive waiver parses without forcing admin" _merge_parse_command_args \
	owner/repo "--waive-runtime-verification=${waiver_reason}"
assert_contains "waiver does not force admin bypass" "$FULL_LOOP_MERGE_PARSED_ADMIN" '0'
_flm_gh_read() { printf '%s\n' "$waiver_head"; return 0; }
pending_json=$(jq -cn --arg body "$pending_body" '{body:$body}')
assert_accepted "signed waiver accepts Critical runtime-pending unchanged" \
	_merge_check_runtime_evidence 7 owner/repo "$pending_json"
assert_accepted "signed waiver accepts High self-assessed unchanged" \
	_merge_check_runtime_evidence 7 owner/repo "$(jq -cn --arg body "$downgraded_body" '{body:$body}')"
assert_contains "waiver pins approved head" "$FULL_LOOP_EXPECTED_PR_HEAD_SHA" "$waiver_head"
assert_contains "approval verification expects exact head" "$(<"${WAIVER_LOG}.approval")" "--expect-head ${waiver_head}"
assert_rejected "waiver keeps malformed risk refusal" _merge_check_runtime_evidence \
	7 owner/repo "$(jq -cn --arg body "$unknown_risk_body" '{body:$body}')"
assert_rejected "waiver keeps malformed verification refusal" _merge_check_runtime_evidence \
	7 owner/repo "$(jq -cn --arg body "$undelimited_body" '{body:$body}')"
assert_rejected "waiver keeps ambiguous section refusal" _merge_check_runtime_evidence \
	7 owner/repo "$(jq -cn --arg body "$example_section_body" '{body:$body}')"
for verdict in NO_APPROVAL STALE_APPROVAL INVALID_SIGNATURE LEGACY_APPROVAL; do
	export WAIVER_VERDICT="$verdict"
	assert_rejected "waiver rejects approval ${verdict}" _merge_check_runtime_evidence 7 owner/repo "$pending_json"
done
export WAIVER_VERDICT=VERIFIED WAIVER_APPROVAL_RC=1
assert_rejected "failed approval command cannot authorize waiver" _merge_check_runtime_evidence 7 owner/repo "$pending_json"
export WAIVER_APPROVAL_RC=0
waiver_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
assert_rejected "head drift refuses waiver" _merge_check_runtime_evidence 7 owner/repo "$pending_json"
waiver_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# The actual merge executor must reverify approval, even after earlier checks.
_merge_check_admin_capability() { return 0; }
_merge_verify_rbg_override_approval() { return 0; }
_merge_resolve_subject_for_method() { printf 'feat: runtime waiver\n'; return 0; }
_merge_describe_flags() { printf 'fixture squash\n'; return 0; }
_merge_resolve_match_head() { printf '%s\n' "$FULL_LOOP_EXPECTED_PR_HEAD_SHA"; return 0; }
_merge_revalidate_transport_authority() { return 0; }
_merge_run_bounded_write() { printf '%s\n' "$*" >>"${WAIVER_LOG}.transport"; return 0; }
print_info() { return 0; }
print_success() { return 0; }
FULL_LOOP_MERGE_SUBJECT_FLAG=--subject
export WAIVER_VERDICT=STALE_APPROVAL
assert_rejected "merge transport refuses approval invalidated after precheck" _merge_execute 7 owner/repo --squash 0 0
assert_accepted "invalid approval reaches no transport" test ! -e "${WAIVER_LOG}.transport"
export WAIVER_VERDICT=VERIFIED
assert_accepted "approved waiver reaches normal merge transport" _merge_execute 7 owner/repo --squash 0 0
assert_contains "waived merge transport binds exact head" "$(<"${WAIVER_LOG}.transport")" "--match-head-commit ${waiver_head}"

# Production hold decision and lifting preserve unknown, mixed and PR-only
# holds; no special waiver path bypasses their trust checks.
waiver_scope=runtime-pending
waiver_pr_only=false
waiver_hold=true
_latest_trusted_hold_scope() { printf '%s\n' "$waiver_scope"; return 0; }
_verify_runtime_linked_issue_refs() { printf 'owner/repo#7\n'; return 0; }
_issue_pr_only_contract_state() { [[ "$waiver_pr_only" == true ]] && return 0; return 1; }
_flm_gh_read() {
	if [[ "$*" == *'--json headRefOid --jq'* ]]; then
		printf '%s\n' "$waiver_head"
	elif [[ "$*" == *'--json labels --jq'* ]]; then
		printf '\n'
	else
		jq -cn --arg head "$waiver_head" --arg body "$pending_body" --arg held "$waiver_hold" \
			'{headRefOid:$head, body:$body, labels:(if $held == "true" then [{name:"hold-for-review"}] else [] end)}'
	fi
	return 0
}
gh_pr_edit_safe() { printf '%s\n' "$*" >>"${WAIVER_LOG}.labels"; waiver_hold=false; return 0; }
print_info() { return 0; }
assert_accepted "waiver lifts recorded runtime-only hold" _merge_lift_runtime_waiver_hold 7 owner/repo
assert_contains "only hold label is removed" "$(<"${WAIVER_LOG}.labels")" '--remove-label hold-for-review'
waiver_hold=true
waiver_scope=runtime-pending,pr-only
assert_rejected "waiver keeps mixed hold scope" _merge_lift_runtime_waiver_hold 7 owner/repo
waiver_scope=unknown
assert_rejected "waiver keeps unknown hold scope" _merge_lift_runtime_waiver_hold 7 owner/repo
waiver_scope=runtime-pending
waiver_pr_only=true
assert_rejected "waiver keeps linked PR-only contract hold" _merge_lift_runtime_waiver_hold 7 owner/repo
waiver_pr_only=false
gh_pr_comment() { printf '%s\n' "$*" >"${WAIVER_LOG}.comment"; return 0; }
gh-signature-helper.sh() { return 0; }
FULL_LOOP_VERIFIED_PR_HEAD_SHA="$waiver_head"
assert_accepted "post-merge waiver records audit transports" _merge_record_runtime_waiver 7 owner/repo cccccccccccccccccccccccccccccccccccccccc
for record in comment audit; do
	recorded=$(<"${WAIVER_LOG}.${record}")
	assert_contains "${record} records waiver reason" "$recorded" "$waiver_reason"
	assert_contains "${record} records approved head" "$recorded" "$waiver_head"
	assert_contains "${record} records merge SHA" "$recorded" cccccccccccccccccccccccccccccccccccccccc
done
assert_accepted "a later invocation without flag resets waiver" _merge_parse_command_args owner/repo
assert_rejected "no-flag merge still refuses pending after waiver" _merge_check_runtime_evidence 7 owner/repo "$pending_json"

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
