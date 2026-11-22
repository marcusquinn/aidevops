#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36769: exercise both real merge entry points with local GitHub fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=../full-loop-helper-merge.sh
source "${SCRIPT_DIR}/full-loop-helper-merge.sh"
# Match the full-loop entrypoint's readonly directory before cold-loading Pulse.
readonly SCRIPT_DIR
# shellcheck source=../pulse-merge.sh
source "${SCRIPT_DIR}/pulse-merge.sh"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
LOGFILE="${TEST_ROOT}/pulse.log"
export TMPDIR="$TEST_ROOT"
AIDEVOPS_TRUSTED_AUTHORS_CONF="${TEST_ROOT}/no-allowlist"
unset AIDEVOPS_HEADLESS Claude_HEADLESS GITHUB_ACTIONS WORKER_SESSION_KEY
FULL_LOOP_HEADLESS=true
AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1
ISSUE_ASSOC=CONTRIBUTOR
ISSUE_LOGIN=outsider
ISSUE_PERMISSION="read"
ISSUE_STATE=open
ISSUE_LABELS='[]'
PR_BODY='Resolves #42'
PR_LABELS='[{"name":"origin:worker"}]'
CRYPTO_APPROVED=0
USER_API_FAIL=0
PR_API_FAIL=0
PR_BODY_ONLY_FAIL=0
WRITER_LOGIN=runner
SYNC_HEAD=""
PR_FILES='[{"filename":".agents/scripts/example.sh","status":"modified"}]'
PR_FILES_API_FAIL=0
ROUTINE_META=""
ROUTINE_HEAD_CONTENT=""
ROUTINE_BASE_CONTENT=""
ROUTINE_TEMPLATE_CONTENT=""
REPOS_JSON="${TEST_ROOT}/repos.json"
ROUTINE_TREE_MODE=100644
ROUTINE_TREE_TRUNCATED=false
ROUTINE_REF_STATUS=ahead
ROUTINE_HEAD=1111111111111111111111111111111111111111
ROUTINE_BASE=2222222222222222222222222222222222222222
ROUTINE_MERGE_BASE="$ROUTINE_BASE"

# Recursive tree fixture: one entry per changed path. README/workflow entries
# point at the fixture blob for that commit; other outputs get a stable ID.
routine_tree_fixture() {
	local content="$1" files="$2" sha=""
	[[ -z "$content" ]] || sha=$(jq -r '.sha' <<<"$content")
	jq -n --argjson files "$files" --arg sha "${sha:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
		--arg mode "$ROUTINE_TREE_MODE" --argjson truncated "$ROUTINE_TREE_TRUNCATED" \
		'{truncated:$truncated,tree:[$files[] | {path:.filename,type:"blob",mode:$mode,
		 sha:(if .filename == "README.md" or (.filename | startswith(".github/workflows/") and endswith(".yml") and . != ".github/workflows/evil.yml")
		  then $sha else "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" end)}]}'
	return 0
}

# No network calls: any unexpected gh request fails rather than reaching GitHub.
gh() {
	local endpoint="" filter="" arg="" previous="" payload=""
	for arg in "$@"; do
		[[ "$previous" != "--jq" ]] || filter="$arg"
		case "$arg" in repos/* | user) endpoint="$arg" ;; esac
		previous="$arg"
	done
	case "$endpoint" in
	user)
		[[ "$USER_API_FAIL" == 0 ]] || return 1
		payload='{"login":"runner"}'
		;;
	*/comments*)
		payload=$(jq -s '.' "${TEST_ROOT}/comments.jsonl")
		payload="[$payload]"
		;;
	*/collaborators/*/permission) payload=$(jq -n --arg p "$ISSUE_PERMISSION" '{permission:$p}') ;;
	repos/owner/repo/pulls/100/files*)
		[[ "$PR_FILES_API_FAIL" == 0 ]] || return 1
		payload="$PR_FILES"
		;;
	repos/owner/repo/pulls/100)
		payload="$ROUTINE_META"
		[[ -n "$payload" ]] || payload='{"head":{"sha":"0123456789abcdef0123456789abcdef01234567"}}'
		;;
	# Only SHA-pinned reads are answered: an unpinned diff read fails the test.
	repos/owner/repo/compare/"${ROUTINE_BASE}...${ROUTINE_HEAD}?per_page=1")
		[[ "$PR_FILES_API_FAIL" == 0 ]] || return 1
		payload=$(jq -n --argjson files "$PR_FILES" --arg mb "$ROUTINE_MERGE_BASE" \
			'{merge_base_commit:{sha:$mb},files:$files}')
		;;
	repos/owner/repo/git/blobs/*)
		payload="$ROUTINE_BASE_CONTENT"
		[[ "$endpoint" != */"$(jq -r .sha <<<"$ROUTINE_HEAD_CONTENT")" ]] || payload="$ROUTINE_HEAD_CONTENT"
		;;
	repos/marcusquinn/aidevops/compare/*)
		payload=$(jq -n --arg status "$ROUTINE_REF_STATUS" '{status:$status}')
		;;
	repos/owner/repo/git/trees/"$ROUTINE_HEAD"'?recursive=1')
		payload=$(routine_tree_fixture "$ROUTINE_HEAD_CONTENT" "$PR_FILES")
		;;
	repos/owner/repo/git/trees/"$ROUTINE_MERGE_BASE"'?recursive=1')
		payload=$(routine_tree_fixture "$ROUTINE_BASE_CONTENT" \
			'[{"filename":"README.md"},{"filename":".github/workflows/loc-badge.yml"},{"filename":".github/workflows/review-bot-gate.yml"}]')
		;;
	repos/owner/repo/issues/42)
		payload=$(jq -n --arg assoc "$ISSUE_ASSOC" --arg login "$ISSUE_LOGIN" --arg state "$ISSUE_STATE" \
			--argjson labels "$ISSUE_LABELS" \
			'{number:42,author_association:$assoc,user:{login:$login,type:"User"},state:$state,labels:$labels,title:"Generated service sync"}')
		;;
	repos/marcusquinn/aidevops/contents/.agents/templates/workflows/*) payload="$ROUTINE_TEMPLATE_CONTENT" ;;
	repos/owner/repo) payload='{"permissions":{"push":true},"default_branch":"main"}' ;;
	*) printf 'Unexpected gh call: %s\n' "$*" >&2; return 1 ;;
	esac
	if [[ -n "$filter" ]]; then jq -r "$filter" <<<"$payload"; else printf '%s\n' "$payload"; fi
	return 0
}

gh_pr_view() {
	local arg="" previous="" filter="" payload="" body="$PR_BODY"
	[[ "$PR_API_FAIL" == 0 ]] || return 1
	if [[ "${TEST_STALE_CACHE:-0}" == 1 && "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" != 1 ]]; then
		body=$'Resolves #42\nResolves #43'
	fi
	for arg in "$@"; do
		[[ "$previous" != "--jq" ]] || filter="$arg"
		previous="$arg"
	done
	[[ "$PR_BODY_ONLY_FAIL" != 1 || -z "$filter" ]] || return 1
	payload=$(jq -n --arg body "$body" --argjson labels "$PR_LABELS" '{body:$body,labels:$labels,isDraft:false,headRefOid:"fixture-head"}')
	if [[ -n "$filter" ]]; then jq -r "$filter" <<<"$payload"; else printf '%s\n' "$payload"; fi
	return 0
}

gh_issue_comment() {
	local arg="" previous="" body_file=""
	for arg in "$@"; do
		[[ "$previous" != "--body-file" ]] || body_file="$arg"
		previous="$arg"
	done
	jq -n --rawfile body "$body_file" --arg login "$WRITER_LOGIN" '{user:{login:$login},body:$body}' >>"${TEST_ROOT}/comments.jsonl"
	return 0
}

_issue_has_verified_crypto_approval() {
	[[ "$CRYPTO_APPROVED" == 1 ]] && return 0
	return 1
}

_pulse_is_trusted_issue_sync_pr() {
	local head_sha="$3"
	[[ "$SYNC_HEAD" == "$head_sha" ]] && return 0
	return 1
}

expect_parity() {
	local expected="$1" name="$2" deterministic=0 full_loop=0
	local linked_issue="${3-42}"
	_attempt_worker_briefed_auto_merge 100 owner/repo origin:worker false "$linked_issue" || deterministic=$?
	_merge_worker_briefed_trust_gate 100 owner/repo 1 || full_loop=$?
	[[ "$deterministic" == "$expected" && "$full_loop" == "$expected" ]] || {
		printf 'FAIL %s: deterministic=%s full-loop=%s\n' "$name" "$deterministic" "$full_loop" >&2
		return 1
	}
	printf 'PASS %s\n' "$name"
	return 0
}

: >"${TEST_ROOT}/comments.jsonl"
expect_parity 1 'external issue denied even with headless --admin'
WORKER_SESSION_KEY=supervisor-pulse
FULL_LOOP_HEADLESS=false
expect_parity 1 'supervisor denied even with --admin and no headless flag'
unset WORKER_SESSION_KEY
FULL_LOOP_HEADLESS=true
ISSUE_ASSOC=OWNER
expect_parity 0 'owner issue allowed'
TEST_STALE_CACHE=1
[[ "$(worker_briefed_trust_verdict 100 owner/repo)" == deny:* ]]
_merge_worker_briefed_trust_gate 100 owner/repo 0
unset TEST_STALE_CACHE
printf 'PASS full-loop trust gate bypasses stale ambiguous PR body\n'
PR_BODY_ONLY_FAIL=1
[[ "$(worker_briefed_trust_verdict 100 owner/repo)" == allow ]]
PR_BODY='For #42'
[[ "$(worker_briefed_trust_verdict 100 owner/repo)" == allow ]]
printf 'PASS closing and explicit references use the same metadata body without a second body read\n'
PR_BODY_ONLY_FAIL=0
PR_BODY='Resolves #42'
ISSUE_ASSOC=COLLABORATOR
ISSUE_PERMISSION="write"
expect_parity 0 'live write authority allowed'
ISSUE_PERMISSION="read"
CRYPTO_APPROVED=1
expect_parity 0 'verified crypto approval allowed'
CRYPTO_APPROVED=0
ISSUE_ASSOC=OWNER
PR_BODY='For #42'
expect_parity 0 'open non-parent For reference allowed'
ISSUE_STATE=closed
expect_parity 1 'closed non-closing reference denied'
ISSUE_STATE=open
ISSUE_LABELS='[{"name":"parent-task"}]'
expect_parity 1 'non-closing parent reference denied'
_merge_worker_briefed_trust_gate 100 owner/repo 0 >"${TEST_ROOT}/parent-code.log" 2>&1 || true
grep -q 'only eligible for a planning checkpoint' "${TEST_ROOT}/parent-code.log"
printf 'PASS parent code diff refusal names the planning-checkpoint policy\n'
# GH#36922: planning checkpoints for an open parent use the same guarded route.
PR_FILES='[{"filename":"TODO.md","status":"modified"},{"filename":"todo/tasks/t1-brief.md","status":"added"}]'
expect_parity 0 'trusted parent planning checkpoint allowed'
ISSUE_ASSOC=CONTRIBUTOR
expect_parity 1 'untrusted parent planning checkpoint denied'
ISSUE_ASSOC=OWNER
PR_FILES_API_FAIL=1
expect_parity 1 'parent planning file metadata failure denied'
_merge_worker_briefed_trust_gate 100 owner/repo 0 >"${TEST_ROOT}/parent-meta.log" 2>&1 || true
grep -q 'linked issue metadata unavailable: PR #100 file list' "${TEST_ROOT}/parent-meta.log"
printf 'PASS metadata failure is distinct from parent-link policy refusal\n'
PR_FILES_API_FAIL=0
PR_FILES='[{"filename":".agents/scripts/example.sh","status":"modified"}]'
ISSUE_LABELS='[]'
PR_BODY=$'Routine r004 scheduled content update\n\nRef #42'
ISSUE_LABELS='[{"name":"routine-tracking"},{"name":"persistent"},{"name":"no-auto-dispatch"}]'
expect_parity 0 'routine without a task issue allowed through maintainer tracking anchor'
ISSUE_ASSOC=CONTRIBUTOR
expect_parity 1 'routine tracking labels cannot authorize an untrusted anchor author'
ISSUE_ASSOC=OWNER
PR_BODY='Routine r004 scheduled content update; TODO.md SOP only'
expect_parity 1 'routine entry without an anchor reference is not merge authority' ''
ISSUE_LABELS='[]'
PR_BODY='Resolves #42'
ISSUE_ASSOC=CONTRIBUTOR
ISSUE_LOGIN='github-actions[bot]'
expect_parity 1 'workflow bot remains denied and gets a decision'
expect_parity 1 'repeated workflow-bot denial does not duplicate comment'
[[ "$(jq -s 'length' "${TEST_ROOT}/comments.jsonl")" == 1 ]]
jq -es '.[0].body | contains("sudo aidevops approve issue 42")' "${TEST_ROOT}/comments.jsonl" >/dev/null
printf 'PASS exactly one workflow-bot decision with the approval command\n'

: >"${TEST_ROOT}/comments.jsonl"
USER_API_FAIL=1
WRITER_LOGIN='github-actions[bot]'
expect_parity 1 'installation token without user endpoint records bot decision'
expect_parity 1 'installation token deduplicates its bot decision'
[[ "$(jq -s 'length' "${TEST_ROOT}/comments.jsonl")" == 1 ]]
USER_API_FAIL=0
WRITER_LOGIN=runner
PR_API_FAIL=1
if _merge_worker_briefed_trust_gate 100 owner/repo 1 >/dev/null 2>&1; then
	printf 'FAIL missing PR metadata allowed merge\n' >&2
	exit 1
fi
PR_API_FAIL=0
PR_LABELS=null
if _merge_worker_briefed_trust_gate 100 owner/repo 1 >/dev/null 2>&1; then
	printf 'FAIL malformed PR labels allowed merge\n' >&2
	exit 1
fi
PR_LABELS='[{"name":"origin:worker"}]'
printf 'PASS missing/malformed PR metadata fails closed\n'

# Prove cmd_merge exits before pre-merge/native/admin transport on denial.
_merge_handle_already_merged_provenance() { return 2; }
_merge_check_closing_guards() { return 0; }
_merge_pre_merge_gate_with_admission_retry() { printf 'unexpected gate\n' >>"${TEST_ROOT}/transport"; return 0; }
_merge_execute() { printf 'unexpected merge\n' >>"${TEST_ROOT}/transport"; return 1; }
if cmd_merge 100 owner/repo --admin >"${TEST_ROOT}/command.log" 2>&1; then
	printf 'FAIL cmd_merge accepted untrusted issue\n' >&2
	exit 1
fi
if [[ -e "${TEST_ROOT}/transport" ]]; then
	printf 'FAIL cmd_merge reached merge transport before the t2449 denial\n' >&2
	exit 1
fi
if ! grep -q 't2449/t3052' "${TEST_ROOT}/command.log"; then
	printf 'FAIL cmd_merge denial lacked t2449/t3052 reason; log: %s\n' "$(tr '\n' ' ' <"${TEST_ROOT}/command.log")" >&2
	exit 1
fi
printf 'PASS cmd_merge denies with t2449 reason before any merge/admin fallback\n'

FULL_LOOP_HEADLESS=false
_merge_worker_briefed_trust_gate 100 owner/repo 1 >"${TEST_ROOT}/override.log" 2>&1
grep -q 'Explicit interactive --admin overrides t2449' "${TEST_ROOT}/override.log"
if _merge_worker_briefed_trust_gate 100 owner/repo 0 >/dev/null 2>&1; then
	printf 'FAIL implicit interactive override\n' >&2
	exit 1
fi
printf 'PASS interactive override requires explicit --admin and is logged\n'

FULL_LOOP_HEADLESS=true
PR_BODY='Generated Issue Sync PR without a linked issue'
SYNC_HEAD=fixture-head
_merge_worker_briefed_trust_gate 100 owner/repo 0
SYNC_HEAD=stale-head
if _merge_worker_briefed_trust_gate 100 owner/repo 0 >/dev/null 2>&1; then
	printf 'FAIL stale Issue Sync trust evidence bypassed linked issue gate\n' >&2
	exit 1
fi
printf 'PASS existing exact-head Issue Sync exception retained; stale head denied\n'

# Exercise the actual anchor creation path in a fresh shell (SCRIPT_DIR above is
# readonly). Fixtures deny unexpected network calls, including label failures.
bash -s -- "$SCRIPT_DIR" "$TEST_ROOT" <<'ANCHOR_TEST'
set -euo pipefail
source "$1/routine-log-helper.sh"
FIXTURE_ROOT="$2"
CRON_BASE="$FIXTURE_ROOT/cron"
gh() {
	local command="$1" endpoint="${2:-}"
	case "$command:$endpoint" in
	api:repos/owner/repo/labels/*) return 1 ;;
	label:create) printf '%s\n' "$3" >>"$FIXTURE_ROOT/labels" ;;
	*) printf 'Unexpected gh call: %s\n' "$*" >&2; return 1 ;;
	esac
	return 0
}
gh_create_issue() {
	local args="$*" arg="" previous="" body_file=""
	for arg in "$@"; do
		[[ "$previous" != --body-file ]] || body_file="$arg"
		previous="$arg"
	done
	[[ -f "$body_file" ]] || return 1
	[[ "$args" == *'--label persistent'* && "$args" == *'--label no-auto-dispatch'* ]] || return 1
	grep -q 'persistent tracking anchor' "$body_file" || return 1
	printf 'https://github.com/owner/repo/issues/42\n'
	return 0
}
cmd_create_issue r004 --repo owner/repo --title 'r004: Content update' >/dev/null
[[ "$(_get_state_field r004 issue_number)" == 42 ]]
[[ "$(wc -l <"$FIXTURE_ROOT/labels")" -eq 4 ]]
printf 'PASS routine setup provisions labels and creates a persistent non-dispatchable anchor\n'
gh() { return 1; }
if _create_github_issue owner/repo 'r004: Content update' body >/dev/null 2>&1; then
	printf 'FAIL label provisioning failure allowed issue creation\n' >&2
	exit 1
fi
printf 'PASS label provisioning failure prevents anchor creation\n'
ANCHOR_TEST

# GH#39785: exercise the actual shared scope predicate through both merge paths.
PR_BODY='<!-- aidevops:routine-pr:badges-sync -->'
ISSUE_PERMISSION="write"
PR_FILES='[{"filename":"docs/metrics/repo-metrics.json","status":"modified"}]'
ROUTINE_META=$(jq -n --arg body "$PR_BODY" '{state:"open",draft:false,body:$body,
 labels:[{name:"origin:worker"}],user:{login:"runner"},changed_files:1,
 head:{ref:"chore/badges-sync-123",sha:"1111111111111111111111111111111111111111",repo:{full_name:"owner/repo"}},
 base:{sha:"2222222222222222222222222222222222222222",repo:{full_name:"owner/repo"}}}')
valid_meta="$ROUTINE_META"
expect_parity 0 'badges marker with verified scope and no anchor admitted' ''
# The verdict binds the merge to the admitted head on both paths.
WORKER_BRIEFED_EXPECTED_HEAD=3333333333333333333333333333333333333333 \
	expect_parity 1 'routine verdict for a different Pulse-pinned head denied' ''
unset FULL_LOOP_EXPECTED_PR_HEAD_SHA
_merge_worker_briefed_gate_pinned 100 owner/repo 0
[[ "$FULL_LOOP_EXPECTED_PR_HEAD_SHA" == "$ROUTINE_HEAD" ]]
FULL_LOOP_EXPECTED_PR_HEAD_SHA=3333333333333333333333333333333333333333
if _merge_worker_briefed_gate_pinned 100 owner/repo 0 2>/dev/null; then exit 1; fi
unset FULL_LOOP_EXPECTED_PR_HEAD_SHA
printf 'PASS routine admission publishes the admitted head as the full-loop merge pin\n'
for mutation in '.head.repo.full_name="outsider/fork"' '.head.ref="feature/forged"' \
	'.changed_files=100' '.changed_files=2' '.head.sha="missing"' \
	'.labels += [{name:"hold-for-review"}]' '.draft=true' \
	'.body += "\n<!-- aidevops:routine-pr:unknown\n -->"'; do
	ROUTINE_META=$(jq "$mutation" <<<"$valid_meta")
	expect_parity 1 "routine metadata denied: $mutation" ''
done
ROUTINE_META="$valid_meta"
ISSUE_PERMISSION="read"
expect_parity 1 'read-only routine author denied' ''
ISSUE_PERMISSION="write"
PR_FILES_API_FAIL=1
expect_parity 1 'routine file API failure denied' ''
PR_FILES_API_FAIL=0
for path in .github/workflows/evil.yml src/evil.sh; do
	PR_FILES=$(jq -n --arg path "$path" '[{filename:$path,status:"modified"}]')
	expect_parity 1 "out-of-scope routine path denied: $path" ''
done
PR_FILES='[{"filename":"docs/metrics/x","status":"renamed","previous_filename":"src/x"}]'
expect_parity 1 'routine rename denied' ''
PR_FILES='[{"filename":"README.md\nREADME.md","status":"added"}]'
expect_parity 1 'newline filename denied before line conversion' ''
PR_FILES='[{"filename":"docs/metrics/x","status":"modified"}]'
ROUTINE_TREE_MODE=120000
expect_parity 1 'symlinked metrics output denied by pinned head tree' ''
ROUTINE_TREE_MODE=100644
PR_BODY='<!-- aidevops:routine-pr:unknown -->'
ROUTINE_META=$(jq --arg body "$PR_BODY" '.body=$body' <<<"$valid_meta")
expect_parity 1 'unknown routine marker denied' ''
PR_BODY='<!-- aidevops:routine-pr:badges-sync -->'
ROUTINE_META="$valid_meta"

content_fixture() {
	local text="$1" data="" sha=""
	data=$(printf '%s' "$text" | base64 | tr -d '\n')
	sha=$(printf '%s' "$text" | git hash-object --stdin)
	jq -n --arg data "$data" --arg sha "$sha" --argjson size "$(printf '%s' "$text" | wc -c)" \
		'{type:"file",encoding:"base64",content:$data,sha:$sha,size:$size}'
	return 0
}
PR_FILES='[{"filename":"README.md","status":"modified"}]'
ROUTINE_BASE_CONTENT=$(content_fixture $'intro\n<!-- aidevops:badges:start -->old<!-- aidevops:badges:end -->\nend\n')
ROUTINE_HEAD_CONTENT=$(content_fixture $'intro\n<!-- aidevops:badges:start -->new<!-- aidevops:badges:end -->\nend\n')
expect_parity 0 'README badge-only edit admitted' ''
# The base tip advanced past the merge base: prose is compared at the merge base.
ROUTINE_MERGE_BASE=3333333333333333333333333333333333333333
expect_parity 0 'README badge-only edit admitted against merge base after base advanced' ''
ROUTINE_MERGE_BASE="$ROUTINE_BASE"
ROUTINE_TREE_MODE=120000
expect_parity 1 'README symlink denied by pinned head tree' ''
ROUTINE_TREE_MODE=100644
ROUTINE_TREE_TRUNCATED=true
expect_parity 1 'truncated tree evidence denied' ''
ROUTINE_TREE_TRUNCATED=false
ROUTINE_HEAD_CONTENT=$(content_fixture $'evil\n<!-- aidevops:badges:start -->new<!-- aidevops:badges:end -->\nend\n')
expect_parity 1 'README edit outside badge block denied' ''
ROUTINE_HEAD_CONTENT=$(content_fixture $'intro\n<!-- aidevops:badges:start -->new\nend\n')
expect_parity 1 'README missing end marker denied' ''
ROUTINE_HEAD_CONTENT=$(jq '.size=9999' <<<"$ROUTINE_BASE_CONTENT")
expect_parity 1 'truncated content denied' ''
ROUTINE_BASE_CONTENT=$(content_fixture $'# Project\n\nOriginal prose\n')
ROUTINE_HEAD_CONTENT=$(content_fixture $'# Project\n\n<!-- aidevops:badges:start -->new<!-- aidevops:badges:end -->\n\nOriginal prose\n')
expect_parity 0 'deterministic first badge block insertion admitted' ''
PR_FILES='[{"filename":".github/workflows/loc-badge.yml","status":"added"}]'
workflow=$(sed -E 's/@main$/@1111111111111111111111111111111111111111/; s/^(      aidevops_ref:).*$/\1 1111111111111111111111111111111111111111/' "$SCRIPT_DIR/../templates/workflows/loc-badge-caller.yml")
ROUTINE_HEAD_CONTENT=$(content_fixture "$workflow"$'\n')
expect_parity 0 'exact pinned workflow template admitted' ''
ROUTINE_REF_STATUS=diverged
expect_parity 1 'workflow ref not reachable from framework main denied' ''
ROUTINE_REF_STATUS=ahead
ROUTINE_HEAD_CONTENT=$(content_fixture "$workflow"$'\n# unexpected workflow content\n')
expect_parity 1 'modified workflow template denied' ''

# GH#39793: sync-workflows marker admission by exact trusted-ref re-rendering.
SYNC_SHA=1111111111111111111111111111111111111111
sync_render() {
	local name="$1" sha="$2" repo="${3:-marcusquinn/aidevops}"
	sed -E -e 's|^([[:space:]]*uses:[[:space:]]*)marcusquinn/aidevops(/\.github/workflows/[^@[:space:]]+)@[^[:space:]]+|\1'"$repo"'\2@'"$sha"'|' \
		-e 's|marcusquinn/aidevops(/\.github/workflows/[^[:space:]]+)|'"$repo"'\1|g' \
		-e 's|^(      aidevops_ref:).*$|\1 '"$sha"'|' "$SCRIPT_DIR/../templates/workflows/${name}-caller.yml"
	return 0
}
sync_template() {
	content_fixture "$(<"$SCRIPT_DIR/../templates/workflows/${1}-caller.yml")"$'\n'
	return 0
}
PR_BODY='<!-- aidevops:routine-pr:sync-workflows -->'
sync_meta=$(jq -n --arg body "$PR_BODY" '{state:"open",draft:false,body:$body,
 labels:[{name:"origin:worker"}],user:{login:"runner"},changed_files:1,
 head:{ref:"chore/workflow-sync-20261122",sha:"1111111111111111111111111111111111111111",repo:{full_name:"owner/repo"}},
 base:{ref:"main",sha:"2222222222222222222222222222222222222222",repo:{full_name:"owner/repo"}}}')
ROUTINE_META="$sync_meta"
rm -f "$REPOS_JSON"
PR_FILES='[{"filename":".github/workflows/review-bot-gate.yml","status":"added"}]'
ROUTINE_TEMPLATE_CONTENT=$(sync_template review-bot-gate)
ROUTINE_HEAD_CONTENT=$(content_fixture "$(sync_render review-bot-gate "$SYNC_SHA")"$'\n')
expect_parity 0 'sync-workflows exact trusted-ref render admitted without an anchor' ''
for mutation in '.head.repo.full_name="outsider/fork"' '.head.ref="chore/badges-sync-1"' \
	'.base.ref="develop"' '.changed_files=2' '.labels += [{name:"hold-for-review"}]' \
	'.body="<!-- aidevops:routine-pr:badges-sync -->"'; do
	ROUTINE_META=$(jq "$mutation" <<<"$sync_meta")
	expect_parity 1 "sync-workflows metadata denied: $mutation" ''
done
ROUTINE_META="$sync_meta"
ISSUE_PERMISSION="read"
expect_parity 1 'read-only sync-workflows author denied' ''
ISSUE_PERMISSION="write"
ROUTINE_REF_STATUS=diverged
expect_parity 1 'sync-workflows ref not reachable from framework main denied' ''
ROUTINE_REF_STATUS=ahead
ROUTINE_HEAD_CONTENT=$(content_fixture "$(sync_render review-bot-gate "$SYNC_SHA")"$'\n      malicious: true\n')
expect_parity 1 'sync-workflows caller with extra content denied' ''
ROUTINE_HEAD_CONTENT=$(content_fixture "$(sync_render review-bot-gate main)"$'\n')
expect_parity 1 'sync-workflows floating ref denied' ''
ROUTINE_HEAD_CONTENT=$(content_fixture "$(sync_render review-bot-gate "$SYNC_SHA")"$'\n')
ROUTINE_HEAD_CONTENT=$(jq '.size=9999' <<<"$ROUTINE_HEAD_CONTENT")
expect_parity 1 'sync-workflows truncated blob denied' ''
ROUTINE_HEAD_CONTENT=$(content_fixture "$(sync_render review-bot-gate "$SYNC_SHA")"$'\n')
ROUTINE_TREE_TRUNCATED=true
expect_parity 1 'sync-workflows truncated tree denied' ''
ROUTINE_TREE_TRUNCATED=false
for path in .github/workflows/evil.yml .github/workflows/release-verify.yml \
	.github/workflows/linked-issue-check.yml CONTRIBUTING.md; do
	PR_FILES=$(jq -n --arg path "$path" '[{filename:$path,status:"added"}]')
	expect_parity 1 "sync-workflows unmanaged path denied: $path" ''
done
PR_FILES='[{"filename":".github/workflows/review-bot-gate.yml","status":"added"},{"filename":"src/evil.sh","status":"added"}]'
ROUTINE_META=$(jq '.changed_files=2' <<<"$sync_meta")
expect_parity 1 'sync-workflows out-of-scope companion file denied' ''
ROUTINE_META="$sync_meta"
# Modified caller: the base file is compared at the merge base and its runner kept.
PR_FILES='[{"filename":".github/workflows/review-bot-gate.yml","status":"modified"}]'
ROUTINE_BASE_CONTENT=$(sync_template review-bot-gate)
expect_parity 0 'sync-workflows modified caller admitted against merge base' ''
awk '{print} /^    with:$/ {print "      runner: custom-label"}' "$SCRIPT_DIR/../templates/workflows/review-bot-gate-caller.yml" >"${TEST_ROOT}/base-runner.yml"
ROUTINE_BASE_CONTENT=$(content_fixture "$(<"${TEST_ROOT}/base-runner.yml")"$'\n')
expect_parity 1 'sync-workflows drops an existing runner label: denied' ''
ROUTINE_HEAD_CONTENT=$(content_fixture "$(sync_render review-bot-gate "$SYNC_SHA" | awk '{print} /^    with:$/ {print "      runner: custom-label"}')"$'\n')
expect_parity 0 'sync-workflows preserves the base file runner label' ''
ROUTINE_BASE_CONTENT=$(sync_template review-bot-gate)
expect_parity 1 'sync-workflows invents a runner label absent from policy: denied' ''
# Declared per-repo policy from the registry: runner override and mirror repo.
printf '{"initialized_repos":[{"slug":"owner/repo","runner":"ubuntu-24.04"}]}\n' >"$REPOS_JSON"
expect_parity 1 'sync-workflows registry runner missing from head denied' ''
ROUTINE_HEAD_CONTENT=$(content_fixture "$(sync_render review-bot-gate "$SYNC_SHA" | awk '{print} /^    with:$/ {print "      runner: ubuntu-24.04"}')"$'\n')
expect_parity 0 'sync-workflows registry runner override admitted' ''
PR_FILES='[{"filename":".github/workflows/maintainer-gate.yml","status":"added"}]'
ROUTINE_TEMPLATE_CONTENT=$(sync_template maintainer-gate)
printf '{"initialized_repos":[{"slug":"owner/repo","workflow_reusable_repo":"mirror/aidevops"}]}\n' >"$REPOS_JSON"
ROUTINE_HEAD_CONTENT=$(content_fixture "$(sync_render maintainer-gate "$SYNC_SHA")"$'\n')
expect_parity 1 'sync-workflows default repo caller denied when the registry declares a mirror' ''
ROUTINE_HEAD_CONTENT=$(content_fixture "$(sync_render maintainer-gate "$SYNC_SHA" mirror/aidevops)"$'\n')
expect_parity 0 'sync-workflows declared mirror caller admitted' ''
printf '{"initialized_repos":[{"slug":"owner/repo","workflow_reusable_repo":"evil/aidevops"}]}\n' >"$REPOS_JSON"
expect_parity 1 'sync-workflows mirror absent from registry policy denied' ''
rm -f "$REPOS_JSON"
PR_FILES='[{"filename":".github/workflows/maintainer-gate.yml","status":"added"}]'
ROUTINE_HEAD_CONTENT=$(content_fixture "$(sync_render maintainer-gate "$SYNC_SHA" mirror/aidevops)"$'\n')
expect_parity 1 'sync-workflows mirror without any registry policy denied' ''

_GH_PR_IDENTITY_ORIGIN=origin:worker
_gh_validate_pr_worker_identity '<!-- aidevops:routine-pr:badges-sync -->' --repo owner/repo
_gh_validate_pr_worker_identity '<!-- aidevops:routine-pr:sync-workflows -->' --repo owner/repo
for body in '<!-- aidevops:routine-pr:unknown -->' '<!-- aidevops:routine-pr:sync-workflows -->
<!-- aidevops:routine-pr:badges-sync -->' \
	$'<!-- aidevops:routine-pr:badges-sync -->\n<!-- aidevops:routine-pr:unknown -->' \
	'<!-- aidevops:routine-pr:badges-sync --><!-- aidevops:routine-pr:unknown -->'; do
	if _gh_validate_pr_worker_identity "$body" --repo owner/repo; then exit 1; fi
done
unset _GH_PR_IDENTITY_ORIGIN
printf 'PASS worker identity accepts the badges/sync-workflows markers only, not unknown or multiple policies\n'

# Retirement uses the existing helper, with no GitHub writes or new harness.
bash -s -- "$SCRIPT_DIR" "$TEST_ROOT" <<'RETIRE_TEST'
	set -euo pipefail
	source "$1/routine-log-helper.sh"
	TEST_ROOT="$2"
	RETIRE_PRS='[{"body":"Ref #77"}]'
	RETIRE_MARKED='[]'
	RETIRE_OPEN='[{"number":77,"state":"OPEN","body":"<!-- aidevops:routine-anchor:badges-sync -->"},{"number":78,"state":"OPEN","body":"<!-- aidevops:routine-anchor:sync-workflows -->"}]'
	RETIRE_REOPEN_FAIL=0
	RETIRE_CALLS="$TEST_ROOT/retirement-calls"
	# Live issue state, independent of the listing snapshot.
	RETIRE_LIVE="$TEST_ROOT/retirement-live-state"
	printf 'OPEN\n' >"$RETIRE_LIVE"
	: >"$RETIRE_CALLS"
	gh() {
		local command="$1" action="${2:-}"
		case "$command:$action" in
		issue:list)
			if [[ "$*" == *'--label routine-anchor-retiring'* ]]; then
				printf '%s\n' "$RETIRE_MARKED"
			else
				printf '%s\n' "$RETIRE_OPEN"
			fi
			;;
		pr:list)
			# Simulate a legacy writer adding Ref #77 while the close is in flight.
			if [[ -n "${RETIRE_PRS_AFTER_CLOSE:-}" ]] && grep -q 'issue close 77' "$RETIRE_CALLS"; then
				printf '%s\n' "$RETIRE_PRS_AFTER_CLOSE"
			else
				printf '%s\n' "$RETIRE_PRS"
			fi
			;;
		api:repos/owner/repo/labels/routine-anchor-retiring) ;;
		issue:view) cat "$RETIRE_LIVE" ;;
		issue:reopen)
			printf '%s\n' "$*" >>"$RETIRE_CALLS"
			[[ "$RETIRE_REOPEN_FAIL" == 0 ]] || return 1
			printf 'OPEN\n' >"$RETIRE_LIVE"
			;;
		issue:close)
			printf '%s\n' "$*" >>"$RETIRE_CALLS"
			printf 'CLOSED\n' >"$RETIRE_LIVE"
			;;
		issue:edit) printf '%s\n' "$*" >>"$RETIRE_CALLS" ;;
		*) return 1 ;;
		esac
		return 0
	}
	gh_issue_comment() {
		local body=""
		body=$(cat)
		[[ "$*" == '77 --repo owner/repo --body-file -' && "$body" == *'verified diff scope'* ]] || return 1
		printf 'comment 77\n' >>"$RETIRE_CALLS"
		return 0
	}
	cmd_retire_anchor badges-sync --repo owner/repo
	[[ ! -s "$RETIRE_CALLS" ]]
	# Every supported reference form keeps the anchor, not only `Ref #N`.
	for body in 'For #77' 'Resolves owner/repo#77' 'see GH#77.'; do
		RETIRE_PRS=$(jq -n --arg body "$body" '[{body:$body}]')
		cmd_retire_anchor badges-sync --repo owner/repo
		[[ ! -s "$RETIRE_CALLS" ]]
	done
	RETIRE_PRS='null'
	if cmd_retire_anchor badges-sync --repo owner/repo; then exit 1; fi
	[[ ! -s "$RETIRE_CALLS" ]]
	RETIRE_PRS=$(jq -n '[range(1000) | {body:""}]')
	if cmd_retire_anchor badges-sync --repo owner/repo; then exit 1; fi
	[[ ! -s "$RETIRE_CALLS" ]]
	RETIRE_PRS='[{"body":"Ref #777"}]'
	cmd_retire_anchor badges-sync --repo owner/repo
	# The marker is recorded before the first destructive step and cleared last.
	[[ "$(sed -n '1p' "$RETIRE_CALLS")" == *'issue edit 77 --repo owner/repo --add-label routine-anchor-retiring'* ]]
	grep -q 'issue edit 77 .*--remove-label persistent' "$RETIRE_CALLS"
	grep -q 'issue close 77 .*--reason not planned' "$RETIRE_CALLS"
	[[ "$(sed -n '$p' "$RETIRE_CALLS")" == *'issue edit 77 --repo owner/repo --remove-label routine-anchor-retiring'* ]]
	if grep -q 'issue close 78' "$RETIRE_CALLS"; then exit 1; fi
	if grep -q 'issue reopen' "$RETIRE_CALLS"; then exit 1; fi
	if cmd_retire_anchor other-routine --repo owner/repo; then exit 1; fi
	# GH#39793: the sync-workflows key is accepted, still keeping a referenced legacy anchor.
	: >"$RETIRE_CALLS"
	RETIRE_PRS='[{"body":"Ref #78"}]'
	cmd_retire_anchor sync-workflows --repo owner/repo
	[[ ! -s "$RETIRE_CALLS" ]]
	RETIRE_PRS='[{"body":"Ref #777"}]'
	printf 'PASS retirement keeps referenced anchor, retires unreferenced badge anchor only\n'
	: >"$RETIRE_CALLS"
	RETIRE_PRS_AFTER_CLOSE='[{"body":"For #77"}]'
	cmd_retire_anchor badges-sync --repo owner/repo 2>/dev/null
	grep -q 'issue reopen 77 --repo owner/repo' "$RETIRE_CALLS"
	grep -q 'issue edit 77 .*--add-label persistent' "$RETIRE_CALLS"
	[[ "$(sed -n '$p' "$RETIRE_CALLS")" == *'--remove-label routine-anchor-retiring'* ]]
	printf 'PASS reference added during close reopens the anchor with persistent restored\n'
	# A failed reopen leaves the marker; the next run restores the closed anchor.
	: >"$RETIRE_CALLS"
	RETIRE_REOPEN_FAIL=1
	if cmd_retire_anchor badges-sync --repo owner/repo 2>/dev/null; then exit 1; fi
	if grep -q -- '--remove-label routine-anchor-retiring' "$RETIRE_CALLS"; then exit 1; fi
	: >"$RETIRE_CALLS"
	RETIRE_REOPEN_FAIL=0
	unset RETIRE_PRS_AFTER_CLOSE
	RETIRE_PRS='[{"body":"For #77"}]'
	RETIRE_MARKED='[{"number":77,"state":"CLOSED","body":"<!-- aidevops:routine-anchor:badges-sync -->"}]'
	RETIRE_OPEN=$(jq '[.[] | select(.number != 77)]' <<<"$RETIRE_OPEN")
	cmd_retire_anchor badges-sync --repo owner/repo 2>/dev/null
	grep -q 'issue reopen 77 --repo owner/repo' "$RETIRE_CALLS"
	grep -q 'issue edit 77 .*--add-label persistent' "$RETIRE_CALLS"
	[[ "$(sed -n '$p' "$RETIRE_CALLS")" == *'--remove-label routine-anchor-retiring'* ]]
	if grep -q 'issue close' "$RETIRE_CALLS"; then exit 1; fi
	# A marked, closed and still unreferenced anchor stays retired.
	: >"$RETIRE_CALLS"
	RETIRE_PRS='[]'
	cmd_retire_anchor badges-sync --repo owner/repo
	[[ "$(cat "$RETIRE_CALLS")" == 'issue edit 77 --repo owner/repo --remove-label routine-anchor-retiring' ]]
	printf 'PASS failed restoration stays marked and is retried while the anchor is closed\n'
	# A stale open snapshot cannot skip the reopen: restore reads live state.
	: >"$RETIRE_CALLS"
	printf 'CLOSED\n' >"$RETIRE_LIVE"
	RETIRE_PRS='[{"body":"For #77"}]'
	RETIRE_MARKED='[{"number":77,"state":"OPEN","body":"<!-- aidevops:routine-anchor:badges-sync -->"}]'
	cmd_retire_anchor badges-sync --repo owner/repo 2>/dev/null
	grep -q 'issue reopen 77 --repo owner/repo' "$RETIRE_CALLS"
	[[ "$(sed -n '$p' "$RETIRE_CALLS")" == *'--remove-label routine-anchor-retiring'* ]]
	printf 'PASS restoration reopens from live state, not a stale open snapshot\n'
RETIRE_TEST
