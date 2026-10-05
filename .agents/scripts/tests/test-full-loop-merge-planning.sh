#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Planning publication readiness and isolated prospective TODO merge cases.
# Usage: sourced by test-full-loop-merge.sh after its shared cases harness.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_TEST_FULL_LOOP_MERGE_PLANNING_LOADED:-}" ]] && return 0
_TEST_FULL_LOOP_MERGE_PLANNING_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_merge_planning_path="${BASH_SOURCE[0]%/*}"
	[[ "$_merge_planning_path" == "${BASH_SOURCE[0]}" ]] && _merge_planning_path="."
	SCRIPT_DIR="$(cd "$_merge_planning_path" && pwd)"
	unset _merge_planning_path
fi

handoff_state_digest() {
	local repo="$1"
	{
		/usr/bin/git -C "$repo" rev-parse HEAD
		/usr/bin/git -C "$repo" ls-files -s
		/usr/bin/git -C "$repo" diff --binary
		/usr/bin/git -C "$repo" diff --cached --binary
		/usr/bin/git -C "$repo" status --porcelain=v1 --untracked-files=all
	} | /usr/bin/git -C "$repo" hash-object --stdin
	return $?
}

create_planning_handoff_fixture() {
	local fixture_name="$1"
	local scripts_dir="${SCRIPT_DIR}/.."
	local publication_output=""
	HANDOFF_ROOT="${TEST_ROOT}/handoff-${fixture_name}"
	HANDOFF_REPO="${HANDOFF_ROOT}/work"
	HANDOFF_RECEIPT_DIR="${HANDOFF_ROOT}/receipts"
	HANDOFF_RECEIPT=""
	HANDOFF_SOURCE_HEAD=""
	HANDOFF_PUBLISHED_COMMIT=""
	mkdir -p "$HANDOFF_ROOT" || return 1
	/usr/bin/git init --bare --initial-branch=main "${HANDOFF_ROOT}/remote.git" >/dev/null 2>&1 || return 1
	/usr/bin/git clone "${HANDOFF_ROOT}/remote.git" "$HANDOFF_REPO" >/dev/null 2>&1 || return 1
	/usr/bin/git -C "$HANDOFF_REPO" config user.email test@test.local || return 1
	/usr/bin/git -C "$HANDOFF_REPO" config user.name Test || return 1
	/usr/bin/git -C "$HANDOFF_REPO" config commit.gpgsign false || return 1
	printf '# Tasks\n' >"${HANDOFF_REPO}/TODO.md"
	printf 'base\n' >"${HANDOFF_REPO}/README.md"
	/usr/bin/git -C "$HANDOFF_REPO" add TODO.md README.md || return 1
	/usr/bin/git -C "$HANDOFF_REPO" commit -q -m seed || return 1
	/usr/bin/git -C "$HANDOFF_REPO" push -q origin main || return 1
	printf '%s\n' '- [ ] t900 checkout-free handoff ref:GH#900' >>"${HANDOFF_REPO}/TODO.md"
	cp "${HANDOFF_REPO}/TODO.md" "${HANDOFF_ROOT}/expected-TODO.md" || return 1
	publication_output=$(
		SCRIPT_DIR="$scripts_dir"
		# shellcheck source=../planning-publisher.sh
		source "${scripts_dir}/planning-publisher.sh"
		AIDEVOPS_PLANNING_GIT_BIN=/usr/bin/git \
			AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true \
			AIDEVOPS_PLANNING_RECEIPT_DIR="$HANDOFF_RECEIPT_DIR" \
			AIDEVOPS_PLANNING_WRITE_RECEIPT=true \
			planning_publish "$HANDOFF_REPO" "plan: checkout-free handoff" origin main || exit $?
		printf '%s\t%s\t%s\n' "$PLANNING_PUBLICATION_RECEIPT" "$PLANNING_PUBLICATION_SOURCE_HEAD" "$PLANNING_PUBLISHED_COMMIT"
	) || return 1
	IFS=$'\t' read -r HANDOFF_RECEIPT HANDOFF_SOURCE_HEAD HANDOFF_PUBLISHED_COMMIT <<<"$publication_output"
	[[ -f "$HANDOFF_RECEIPT" && -n "$HANDOFF_SOURCE_HEAD" && -n "$HANDOFF_PUBLISHED_COMMIT" ]]
	return $?
}

write_handoff_gh_stub() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
	printf '{"data":{"repository":{"pullRequest":{"state":"OPEN","isDraft":false,"reviewDecision":"","headRefOid":"%s","headRefName":"main"}},"rateLimit":{"cost":1}}}\n' "${HANDOFF_EXPECTED_HEAD:?}"
	exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
	if [[ "$*" == *"--json headRefOid"* ]]; then
		printf '%s\n' "${HANDOFF_EXPECTED_HEAD:?}"
		exit 0
	fi
fi
exit 1
GHSTUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

run_handoff_readiness() {
	local repo="$1"
	local receipt_dir="$2"
	local expected_head="$3"
	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	local rc=0
	write_handoff_gh_stub || return 1
	tmp_runner=$(mktemp) || return 1
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
HEADLESS=true
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-commit.sh'
_full_loop_query_required_checks() {
	local pr_number="\$1"
	local repo="\$2"
	local pr_head_ref="\$3"
	: "\$pr_number" "\$repo" "\$pr_head_ref"
	FULL_LOOP_REQUIRED_CHECKS_JSON='[]'
	FULL_LOOP_REQUIRED_CHECKS_SUCCESS_EVIDENCE='no-required-checks'
	FULL_LOOP_REQUIRED_CHECKS_SUCCESS_SUMMARY='no required checks are configured'
	return 0
}
_full_loop_persist_pr_check_evidence() {
	local status="\$1"
	local head_sha="\$2"
	local evidence="\${3:-}"
	: "\$status" "\$head_sha" "\$evidence"
	return 0
}
cd '${repo}'
_full_loop_verify_pr_readiness '42' 'testorg/testrepo'
RUNNER_EOF
	chmod +x "$tmp_runner"
	env PATH="${TEST_ROOT}/bin:/usr/bin:/bin:/opt/homebrew/bin:${PATH}" \
		HANDOFF_EXPECTED_HEAD="$expected_head" \
		AIDEVOPS_PLANNING_GIT_BIN=/usr/bin/git \
		AIDEVOPS_PLANNING_RECEIPT_DIR="$receipt_dir" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	return $rc
}

test_checkout_free_publication_readiness_handoff() {
	local output="" before="" after="" valid_rc=0 changed_rc=0 added_rc=0 ordinary_rc=0 advanced_rc=0
	local ordinary_repo="" ordinary_receipts="" ordinary_head=""
	local advanced_repo="" advanced_receipts="" advanced_root="" advanced_head=""
	create_planning_handoff_fixture valid || {
		print_result "planning handoff: fixture setup succeeds" 1
		return 0
	}
	before=$(handoff_state_digest "$HANDOFF_REPO")
	output=$(run_handoff_readiness "$HANDOFF_REPO" "$HANDOFF_RECEIPT_DIR" "$HANDOFF_PUBLISHED_COMMIT") || valid_rc=$?
	after=$(handoff_state_digest "$HANDOFF_REPO")
	print_result "planning handoff: exact checkout-free receipt passes readiness" "$valid_rc" "output=$output"
	print_result "planning handoff: readiness preserves local HEAD, index, and files" "$([[ "$before" == "$after" ]] && printf '0' || printf '1')"
	printf '%s\n' '- [ ] t901 post-publication drift ref:GH#901' >>"${HANDOFF_REPO}/TODO.md"
	run_handoff_readiness "$HANDOFF_REPO" "$HANDOFF_RECEIPT_DIR" "$HANDOFF_PUBLISHED_COMMIT" >/dev/null 2>&1 || changed_rc=$?
	print_result "planning handoff: changed local planning snapshot is blocked" "$((changed_rc == 0 ? 1 : 0))"
	cp "${HANDOFF_ROOT}/expected-TODO.md" "${HANDOFF_REPO}/TODO.md" || return 0
	mkdir -p "${HANDOFF_REPO}/todo" || return 0
	printf '%s\n' '# Added after publication' >"${HANDOFF_REPO}/todo/t902.md"
	run_handoff_readiness "$HANDOFF_REPO" "$HANDOFF_RECEIPT_DIR" "$HANDOFF_PUBLISHED_COMMIT" >/dev/null 2>&1 || added_rc=$?
	print_result "planning handoff: newly added planning path is blocked" "$((added_rc == 0 ? 1 : 0))"

	create_planning_handoff_fixture ordinary || return 0
	ordinary_repo="$HANDOFF_REPO"
	ordinary_receipts="$HANDOFF_RECEIPT_DIR"
	ordinary_head="$HANDOFF_PUBLISHED_COMMIT"
	printf 'ordinary local commit\n' >>"${ordinary_repo}/README.md"
	/usr/bin/git -C "$ordinary_repo" add README.md
	/usr/bin/git -C "$ordinary_repo" commit -q -m 'ordinary local drift'
	run_handoff_readiness "$ordinary_repo" "$ordinary_receipts" "$ordinary_head" >/dev/null 2>&1 || ordinary_rc=$?
	print_result "planning handoff: ordinary unpushed local commit remains blocked" "$((ordinary_rc == 0 ? 1 : 0))"

	create_planning_handoff_fixture advanced || return 0
	advanced_repo="$HANDOFF_REPO"
	advanced_receipts="$HANDOFF_RECEIPT_DIR"
	advanced_root="$HANDOFF_ROOT"
	/usr/bin/git clone "${advanced_root}/remote.git" "${advanced_root}/competitor" >/dev/null 2>&1 || return 0
	/usr/bin/git -C "${advanced_root}/competitor" config user.email test@test.local
	/usr/bin/git -C "${advanced_root}/competitor" config user.name Test
	/usr/bin/git -C "${advanced_root}/competitor" config commit.gpgsign false
	printf 'remote advancement\n' >>"${advanced_root}/competitor/README.md"
	/usr/bin/git -C "${advanced_root}/competitor" commit -q -am 'advance remote head'
	/usr/bin/git -C "${advanced_root}/competitor" push -q origin main
	advanced_head=$(/usr/bin/git -C "${advanced_root}/competitor" rev-parse HEAD)
	run_handoff_readiness "$advanced_repo" "$advanced_receipts" "$advanced_head" >/dev/null 2>&1 || advanced_rc=$?
	print_result "planning handoff: advanced remote PR head makes receipt stale" "$((advanced_rc == 0 ? 1 : 0))"
	return 0
}

run_prospective_todo_guard() {
	local fixture_dir="$1"
	local base_sha="$2"
	local head_sha="$3"
	local fetch_mode="${4:-stub}"
	local remote_url="${5:-https://github.com/testorg/testrepo.git}"
	local reported_repo="${6:-testorg/testrepo}"
	local caller_context="${7:-$fixture_dir}"
	local real_git_bin="${8:-/usr/bin/git}"
	local scripts_dir="${SCRIPT_DIR}/.."
	local tmp_runner=""
	local verification_tmp="${fixture_dir}/verification-tmp"
	local attacker_home="${fixture_dir}/attacker-home"
	local driver_script="${fixture_dir}/merge-driver.sh"
	local driver_marker="${fixture_dir}/merge-driver-ran"
	local hostile_objects="${fixture_dir}/hostile-objects"
	local hostile_alternates="${fixture_dir}/hostile-alternates"
	local hostile_index="${fixture_dir}/hostile-index"
	local guard_path="${AIDEVOPS_TEST_GUARD_PATH:-${TEST_ROOT}/bin:${scripts_dir}:/usr/bin:/bin:${PATH}}"
	local fetch_override=""
	local validation_override=""
	if [[ "$fetch_mode" == "stub" ]]; then
		fetch_override="_merge_fetch_pinned_commit_objects() { printf '%s\\n' '${fixture_dir}/.git/objects' >\"\$5/objects/info/alternates\"; return 0; }"
	else
		validation_override='_merge_validate_target_remote_url() { return 0; }'
	fi
	mkdir -p "$verification_tmp" "$attacker_home" "$hostile_objects" "$hostile_alternates"
	# shellcheck disable=SC2016  # The generated driver expands this at execution time.
	printf '%s\n' '#!/usr/bin/env bash' ': >"${AIDEVOPS_TEST_MERGE_DRIVER_MARKER:?}"' 'exit 1' >"$driver_script"
	chmod +x "$driver_script"
	HOME="$attacker_home" /usr/bin/git config --global merge.aidevops-test.driver \
		"${driver_script} %O %A %B"
	rm -f "$driver_marker"
	tmp_runner=$(mktemp)
	cat >"$tmp_runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${scripts_dir}'
source '${scripts_dir}/shared-constants.sh'
source '${scripts_dir}/full-loop-helper-merge.sh'
_merge_fetch_pr_refs_rest() { printf 'main\t%s\t%s\t%s\t%s\n' '${base_sha}' '${head_sha}' '${reported_repo}' '${remote_url}'; return 0; }
${fetch_override}
${validation_override}
	cd '${caller_context}'
	_merge_guard_prospective_todo '42' 'testorg/testrepo'
RUNNER_EOF
	chmod +x "$tmp_runner"
	local rc=0
	env PATH="$guard_path" \
		HOME="$attacker_home" AIDEVOPS_TEMP_DIR="$verification_tmp" \
		AIDEVOPS_REAL_GIT_BIN="$real_git_bin" AIDEVOPS_TEST_MERGE_DRIVER_MARKER="$driver_marker" \
		GIT_ALTERNATE_OBJECT_DIRECTORIES="$hostile_alternates" \
		GIT_ATTR_SOURCE=refs/heads/aidevops-hostile GIT_INDEX_FILE="$hostile_index" \
		GIT_OBJECT_DIRECTORY="$hostile_objects" \
		bash "$tmp_runner" 2>&1 || rc=$?
	rm -f "$tmp_runner"
	[[ "$rc" -eq 0 ]] && return 0
	return 1
}

prospective_contexts_clean() {
	local fixture_dir="$1"
	local leftovers=""
	leftovers=$(compgen -G "${fixture_dir}/verification-tmp/aidevops-prospective-todo.*" || true)
	[[ -z "$leftovers" ]]
	return $?
}

prospective_hostile_git_environment_clean() {
	local fixture_dir="$1"
	[[ ! -e "${fixture_dir}/hostile-index" ]] || return 1
	rmdir "${fixture_dir}/hostile-objects" 2>/dev/null || return 1
	rmdir "${fixture_dir}/hostile-alternates" 2>/dev/null || return 1
	return 0
}

prospective_git_storage_digest() {
	local fixture_dir="$1"
	{
		/usr/bin/git -C "$fixture_dir" count-objects -v
		/usr/bin/git -C "$fixture_dir" for-each-ref --format='%(refname) %(objectname)'
	} | /usr/bin/git -C "$fixture_dir" hash-object --stdin
	return $?
}

create_prospective_fixture() {
	local mode="$1"
	local fixture_dir="${TEST_ROOT}/prospective-${mode}"
	mkdir -p "$fixture_dir"
	(
		cd "$fixture_dir" || exit 1
		/usr/bin/git init -q
		/usr/bin/git config user.email test@test.local
		/usr/bin/git config user.name Test
		/usr/bin/git config commit.gpgsign false
		printf 'TODO.md merge=aidevops-test\n' >.gitattributes
		printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n\n## Branch tasks\n' >TODO.md
		/usr/bin/git add .gitattributes TODO.md
		/usr/bin/git commit -q -m root
		local root_sha=""
		root_sha=$(/usr/bin/git rev-parse HEAD)
		printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n- [ ] t2 Base addition ref:GH#2\n\n## Branch tasks\n' >TODO.md
		/usr/bin/git commit -q -am base
		/usr/bin/git rev-parse HEAD >base.sha
		/usr/bin/git checkout -q --detach "$root_sha"
		if [[ "$mode" == "collision" ]]; then
			printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n\n## Branch tasks\n- [ ] t2 Head addition ref:GH#2\n' >TODO.md
		else
			printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n\n## Branch tasks\n- [ ] t3 Unique head addition ref:GH#3\n' >TODO.md
		fi
		/usr/bin/git commit -q -am head
		/usr/bin/git rev-parse HEAD >head.sha
	)
	printf '%s\n' "$fixture_dir"
	return 0
}

create_prospective_fetch_fixture() {
	local fixture_root="${TEST_ROOT}/prospective-fetch"
	local remote_repo="${fixture_root}/remote.git"
	local fixture_dir="${fixture_root}/work"
	local competitor="${fixture_root}/competitor"
	local caller_remote="${fixture_root}/caller-remote.git"
	local caller="${fixture_root}/caller"
	local root_sha="" base_sha="" head_sha=""
	mkdir -p "$fixture_root" || return 1
	/usr/bin/git init --bare --initial-branch=main "$remote_repo" >/dev/null 2>&1 || return 1
	# Mirror GitHub: partial-clone filters and object-ID wants are supported.
	/usr/bin/git -C "$remote_repo" config uploadpack.allowFilter true || return 1
	/usr/bin/git -C "$remote_repo" config uploadpack.allowAnySHA1InWant true || return 1
	/usr/bin/git clone "$remote_repo" "$fixture_dir" >/dev/null 2>&1 || return 1
	/usr/bin/git -C "$fixture_dir" config user.email test@test.local || return 1
	/usr/bin/git -C "$fixture_dir" config user.name Test || return 1
	/usr/bin/git -C "$fixture_dir" config commit.gpgsign false || return 1
	# Large history the PR never touches: neither blob may be transferred (GH#32641).
	head -c 1048576 /dev/urandom >"${fixture_dir}/large.bin" || return 1
	/usr/bin/git -C "$fixture_dir" add large.bin || return 1
	/usr/bin/git -C "$fixture_dir" commit -q -m 'large history v1' || return 1
	/usr/bin/git -C "$fixture_dir" rev-parse HEAD:large.bin >"${fixture_root}/unrelated.blobs" || return 1
	head -c 1048576 /dev/urandom >"${fixture_dir}/large.bin" || return 1
	/usr/bin/git -C "$fixture_dir" commit -q -am 'large history v2' || return 1
	/usr/bin/git -C "$fixture_dir" rev-parse HEAD:large.bin >>"${fixture_root}/unrelated.blobs" || return 1
	printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n\n## Branch tasks\n' >"${fixture_dir}/TODO.md"
	/usr/bin/git -C "$fixture_dir" add TODO.md || return 1
	/usr/bin/git -C "$fixture_dir" commit -q -m root || return 1
	root_sha=$(/usr/bin/git -C "$fixture_dir" rev-parse HEAD) || return 1
	/usr/bin/git -C "$fixture_dir" push -q origin main || return 1
	printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n- [ ] t2 Base addition ref:GH#2\n\n## Branch tasks\n' >"${fixture_dir}/TODO.md"
	/usr/bin/git -C "$fixture_dir" commit -q -am base || return 1
	base_sha=$(/usr/bin/git -C "$fixture_dir" rev-parse HEAD) || return 1
	/usr/bin/git -C "$fixture_dir" push -q origin main || return 1
	/usr/bin/git clone "$remote_repo" "$competitor" >/dev/null 2>&1 || return 1
	/usr/bin/git -C "$competitor" config user.email test@test.local || return 1
	/usr/bin/git -C "$competitor" config user.name Test || return 1
	/usr/bin/git -C "$competitor" config commit.gpgsign false || return 1
	/usr/bin/git -C "$competitor" checkout -q --detach "$root_sha" || return 1
	printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n\n## Branch tasks\n- [ ] t3 Unique head addition ref:GH#3\n' >"${competitor}/TODO.md"
	/usr/bin/git -C "$competitor" commit -q -am head || return 1
	head_sha=$(/usr/bin/git -C "$competitor" rev-parse HEAD) || return 1
	/usr/bin/git -C "$competitor" push -q origin "${head_sha}:refs/pull/42/head" || return 1
	/usr/bin/git init --bare --initial-branch=main "$caller_remote" >/dev/null 2>&1 || return 1
	/usr/bin/git clone "$caller_remote" "$caller" >/dev/null 2>&1 || return 1
	/usr/bin/git -C "$caller" config user.email test@test.local || return 1
	/usr/bin/git -C "$caller" config user.name Test || return 1
	/usr/bin/git -C "$caller" config commit.gpgsign false || return 1
	printf 'unrelated caller repository\n' >"${caller}/README.md"
	/usr/bin/git -C "$caller" add README.md || return 1
	/usr/bin/git -C "$caller" commit -q -m root || return 1
	/usr/bin/git -C "$caller" push -q origin main || return 1
	printf '%s\n' "$base_sha" >"${fixture_root}/base.sha"
	printf '%s\n' "$head_sha" >"${fixture_root}/head.sha"
	printf '%s\n' "$remote_repo" >"${fixture_root}/remote.url"
	printf '%s\n' "$caller"
	return 0
}

# Criss-cross history (two merge bases) where an existing JSON file changes on
# both lines of history. merge-ort must read the root-side blob to build its
# virtual merge base, which a single-level enumeration never requests (GH#33513).
create_prospective_crisscross_fixture() {
	local fixture_root="${TEST_ROOT}/prospective-crisscross"
	local remote_repo="${fixture_root}/remote.git"
	local work="${fixture_root}/work"
	local root_sha="" x_sha="" y_sha="" base_sha="" head_sha=""
	mkdir -p "${fixture_root}/caller" || return 1
	/usr/bin/git init --bare --initial-branch=main "$remote_repo" >/dev/null 2>&1 || return 1
	/usr/bin/git -C "$remote_repo" config uploadpack.allowFilter true || return 1
	/usr/bin/git -C "$remote_repo" config uploadpack.allowAnySHA1InWant true || return 1
	/usr/bin/git clone "$remote_repo" "$work" >/dev/null 2>&1 || return 1
	/usr/bin/git -C "$work" config user.email test@test.local || return 1
	/usr/bin/git -C "$work" config user.name Test || return 1
	/usr/bin/git -C "$work" config commit.gpgsign false || return 1
	printf '## Base tasks\n- [ ] t1 Root ref:GH#1\n' >"${work}/TODO.md"
	printf '{\n "a": 0,\n "pad1": 1,\n "pad2": 2,\n "pad3": 3,\n "b": 0\n}\n' >"${work}/settings.json"
	/usr/bin/git -C "$work" add -A && /usr/bin/git -C "$work" commit -q -m root || return 1
	root_sha=$(/usr/bin/git -C "$work" rev-parse HEAD) || return 1
	printf '{\n "a": 1,\n "pad1": 1,\n "pad2": 2,\n "pad3": 3,\n "b": 0\n}\n' >"${work}/settings.json"
	/usr/bin/git -C "$work" commit -q -am x || return 1
	x_sha=$(/usr/bin/git -C "$work" rev-parse HEAD) || return 1
	/usr/bin/git -C "$work" checkout -q --detach "$root_sha" || return 1
	printf '{\n "a": 0,\n "pad1": 1,\n "pad2": 2,\n "pad3": 3,\n "b": 1\n}\n' >"${work}/settings.json"
	/usr/bin/git -C "$work" commit -q -am y || return 1
	y_sha=$(/usr/bin/git -C "$work" rev-parse HEAD) || return 1
	/usr/bin/git -C "$work" checkout -q --detach "$x_sha" || return 1
	/usr/bin/git -C "$work" merge -q --no-edit "$y_sha" >/dev/null 2>&1 || return 1
	printf 'base side\n' >"${work}/base.txt"
	/usr/bin/git -C "$work" add -A && /usr/bin/git -C "$work" commit -q -m base || return 1
	base_sha=$(/usr/bin/git -C "$work" rev-parse HEAD) || return 1
	/usr/bin/git -C "$work" checkout -q --detach "$y_sha" || return 1
	/usr/bin/git -C "$work" merge -q --no-edit "$x_sha" >/dev/null 2>&1 || return 1
	printf 'head side\n' >"${work}/head.txt"
	/usr/bin/git -C "$work" add -A && /usr/bin/git -C "$work" commit -q -m head || return 1
	head_sha=$(/usr/bin/git -C "$work" rev-parse HEAD) || return 1
	/usr/bin/git -C "$work" push -q origin "${base_sha}:refs/heads/main" || return 1
	/usr/bin/git -C "$work" push -q origin "${head_sha}:refs/pull/42/head" || return 1
	printf '%s\n' "$base_sha" >"${fixture_root}/base.sha"
	printf '%s\n' "$head_sha" >"${fixture_root}/head.sha"
	printf '%s\n' "$remote_repo" >"${fixture_root}/remote.url"
	printf '%s\n' "${fixture_root}/caller"
	return 0
}

# Native Git wrapper that records which unrelated blobs exist in the isolated
# object store when merge-tree runs, and can delay fetches to prove the bound.
create_prospective_git_probe() {
	local probe="${TEST_ROOT}/prospective-git-probe"
	cat >"$probe" <<'PROBE_EOF'
#!/usr/bin/env bash
repo="" prev="" arg="" oid="" subcommand=""
for arg in "$@"; do
	if [[ "$prev" == "-C" ]]; then
		repo="$arg"
	elif [[ -z "$subcommand" && "$prev" != "-c" && "$arg" != -* ]]; then
		subcommand="$arg"
	fi
	prev="$arg"
done
if [[ "$subcommand" == "fetch" && -n "${AIDEVOPS_TEST_FETCH_DELAY:-}" ]]; then
	sleep "$AIDEVOPS_TEST_FETCH_DELAY"
fi
# Simulate a blob fetch that exits zero without materializing objects.
if [[ "$subcommand" == "fetch" && -n "${AIDEVOPS_TEST_SKIP_BLOB_FETCH:-}" && " $* " == *" --stdin "* ]]; then
	cat >/dev/null
	exit 0
fi
if [[ "$subcommand" == "merge-tree" && -n "${AIDEVOPS_TEST_TRANSFER_LOG:-}" ]]; then
	printf 'checked\n' >>"$AIDEVOPS_TEST_TRANSFER_LOG"
	while IFS= read -r oid; do
		if GIT_NO_LAZY_FETCH=1 /usr/bin/git -C "$repo" cat-file -e "$oid" 2>/dev/null; then
			printf 'transferred %s\n' "$oid" >>"$AIDEVOPS_TEST_TRANSFER_LOG"
		fi
	done <"$AIDEVOPS_TEST_UNRELATED_BLOBS"
fi
exec /usr/bin/git "$@"
PROBE_EOF
	chmod +x "$probe" || return 1
	printf '%s\n' "$probe"
	return 0
}

# System tool directory without timeout/gtimeout, forcing timeout_sec onto its
# job-control fallback the way coreutils-less macOS hosts run it (GH#33619).
create_no_timeout_path_dir() {
	local path_dir="${TEST_ROOT}/no-timeout-bin"
	local entry="" name=""
	if [[ ! -d "$path_dir" ]]; then
		mkdir -p "$path_dir" || return 1
		for entry in /usr/bin/* /bin/*; do
			name="${entry##*/}"
			[[ "$name" == "timeout" || "$name" == "gtimeout" ]] && continue
			[[ -e "${path_dir}/${name}" ]] || ln -s "$entry" "${path_dir}/${name}" || return 1
		done
	fi
	printf '%s\n' "$path_dir"
	return 0
}

test_timeout_sec_fallback_preserves_stdin() {
	local scripts_dir="${SCRIPT_DIR}/.."
	local path_dir="" sample="${TEST_ROOT}/timeout-stdin-sample" output="" rc=0
	path_dir=$(create_no_timeout_path_dir) || {
		print_result "timeout_sec fallback: no-timeout PATH fixture" 1
		return 0
	}
	printf 'abcdefghijklm\n' >"$sample"
	# The redirect sits inside a subshell, where Bash has no job control: this
	# is the shape that previously handed the command /dev/null.
	# shellcheck disable=SC2016  # Positional parameters expand in the child shell.
	output=$(env PATH="$path_dir" bash -c '
		source "$1/shared-constants.sh" >/dev/null 2>&1 || exit 90
		command -v timeout >/dev/null 2>&1 && exit 91
		command -v gtimeout >/dev/null 2>&1 && exit 91
		( timeout_sec 5 cat <"$2" )
	' _ "$scripts_dir" "$sample") || rc=$?
	print_result "timeout_sec fallback: subshell caller stdin reaches the command" \
		"$([[ "$rc" -eq 0 && "$output" == "abcdefghijklm" ]] && printf '0' || printf '1')" \
		"rc=$rc output=$output"

	rc=0
	# shellcheck disable=SC2016  # Positional parameters expand in the child shell.
	env PATH="$path_dir" bash -c '
		source "$1/shared-constants.sh" >/dev/null 2>&1 || exit 90
		( timeout_sec 1 sleep 5 </dev/null )
	' _ "$scripts_dir" 2>/dev/null || rc=$?
	print_result "timeout_sec fallback: deadline still returns 124" \
		"$([[ "$rc" -eq 124 ]] && printf '0' || printf '1')" "rc=$rc"
	return 0
}

test_todo_duplicate_report_large_baseline() {
	local baseline="${TEST_ROOT}/large-baseline.todo"
	local candidate="${TEST_ROOT}/large-candidate.todo"
	local task_number="1" output="" rc=0 elapsed=0

	while [[ "$task_number" -le 2500 ]]; do
		printf -- '- [ ] t%s Task %s ref:GH#%s\n' "$task_number" "$task_number" "$task_number" >>"$baseline"
		task_number=$((task_number + 1))
	done
	cp "$baseline" "$candidate"
	SECONDS=0
	output=$(source "${SCRIPT_DIR}/../issue-sync-pr-task-resolver.sh" &&
		todo_duplicate_report "$candidate" "$baseline") || rc=$?
	elapsed=$SECONDS
	print_result "prospective TODO: large unique baseline passes within bound" \
		"$([[ "$rc" -eq 0 && "$elapsed" -lt 5 ]] && printf '0' || printf '1')" \
		"rc=$rc elapsed=${elapsed}s output=$output"

	rc=0
	printf -- '- [ ] t2500 Duplicate task ref:GH#2500\n' >>"$candidate"
	SECONDS=0
	output=$(source "${SCRIPT_DIR}/../issue-sync-pr-task-resolver.sh" &&
		todo_duplicate_report "$candidate" "$baseline") || rc=$?
	elapsed=$SECONDS
	print_result "prospective TODO: large introduced duplicate is bounded and reported" \
		"$([[ "$rc" -eq 1 && "$elapsed" -lt 5 && "$output" == *"Duplicate task ID: t2500"* ]] && printf '0' || printf '1')" \
		"rc=$rc elapsed=${elapsed}s output=$output"

	rc=0
	output=$(source "${SCRIPT_DIR}/../issue-sync-pr-task-resolver.sh" &&
		todo_duplicate_report "$candidate" "${TEST_ROOT}/missing-baseline.todo") || rc=$?
	print_result "prospective TODO: unreadable baseline remains indeterminate" "$([[ "$rc" -eq 2 ]] && printf '0' || printf '1')" "rc=$rc"
	return 0
}

test_prospective_todo_merge_guard() {
	local fixture_dir="" base_sha="" head_sha="" output="" rc=0 objects_before="" objects_after=""
	local cleanup_rc=0 environment_rc=0 isolation_rc=0
	fixture_dir=$(create_prospective_fixture collision)
	base_sha=$(<"${fixture_dir}/base.sha")
	head_sha=$(<"${fixture_dir}/head.sha")
	objects_before=$(/usr/bin/git -C "$fixture_dir" count-objects -v)
	output=$(run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha") || rc=$?
	objects_after=$(/usr/bin/git -C "$fixture_dir" count-objects -v)
	prospective_contexts_clean "$fixture_dir" || cleanup_rc=$?
	prospective_hostile_git_environment_clean "$fixture_dir" || environment_rc=$?
	[[ "$cleanup_rc" -eq 0 && "$objects_before" == "$objects_after" ]] || isolation_rc=1
	print_result "prospective TODO: merge-only collision is blocked" "$((rc == 0 ? 1 : 0))" "output=$output"
	print_result "prospective TODO: task and issue duplicates are reported" "$([[ "$output" == *"Duplicate task ID: t2"* && "$output" == *"Duplicate issue mapping: ref:GH#2"* ]] && printf '0' || printf '1')" "output=$output"
	print_result "prospective TODO: configured external merge driver is not executed" \
		"$([[ ! -e "${fixture_dir}/merge-driver-ran" ]] && printf '0' || printf '1')"
	print_result "prospective TODO: hostile repository environment writes no external state" "$environment_rc"
	print_result "prospective TODO: collision writes only to cleaned isolated context" "$isolation_rc"

	rc=0
	cleanup_rc=0
	environment_rc=0
	isolation_rc=0
	fixture_dir=$(create_prospective_fixture unique)
	base_sha=$(<"${fixture_dir}/base.sha")
	head_sha=$(<"${fixture_dir}/head.sha")
	objects_before=$(/usr/bin/git -C "$fixture_dir" count-objects -v)
	run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" >/dev/null || rc=$?
	objects_after=$(/usr/bin/git -C "$fixture_dir" count-objects -v)
	prospective_contexts_clean "$fixture_dir" || cleanup_rc=$?
	prospective_hostile_git_environment_clean "$fixture_dir" || environment_rc=$?
	[[ "$cleanup_rc" -eq 0 && "$environment_rc" -eq 0 && "$objects_before" == "$objects_after" ]] || isolation_rc=1
	print_result "prospective TODO: unique stale branch passes" "$rc"
	print_result "prospective TODO: success writes only to cleaned isolated context" "$isolation_rc"

	rc=0
	cleanup_rc=0
	environment_rc=0
	output=$(run_prospective_todo_guard "$fixture_dir" deadbeef deadbeef) || rc=$?
	print_result "prospective TODO: indeterminate merge-tree fails closed" "$((rc == 0 ? 1 : 0))" "output=$output"
	prospective_contexts_clean "$fixture_dir" || cleanup_rc=$?
	prospective_hostile_git_environment_clean "$fixture_dir" || environment_rc=$?
	[[ "$environment_rc" -eq 0 ]] || cleanup_rc=1
	print_result "prospective TODO: failure cleans isolated context" "$cleanup_rc"
	return 0
}

test_prospective_todo_live_fetch_guard() {
	local fixture_dir="" fixture_root="" base_sha="" head_sha="" remote_url="" supervisor_workspace="" output="" rc=0
	local cleanup_rc=0 environment_rc=0 isolation_rc=0 storage_before="" storage_after="" absent_before=0 absent_after=0
	local git_probe="" transfer_log=""
	fixture_dir=$(create_prospective_fetch_fixture) || return 0
	fixture_root="${fixture_dir%/caller}"
	base_sha=$(<"${fixture_root}/base.sha")
	head_sha=$(<"${fixture_root}/head.sha")
	remote_url=$(<"${fixture_root}/remote.url")
	printf 'advance target default branch after PR snapshot\n' >>"${fixture_root}/work/TODO.md"
	/usr/bin/git -C "${fixture_root}/work" commit -q -am 'advance target main after PR snapshot' || return 0
	/usr/bin/git -C "${fixture_root}/work" push -q origin main || return 0
	storage_before=$(prospective_git_storage_digest "$fixture_dir")
	if /usr/bin/git -C "$fixture_dir" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then absent_before=1; fi
	supervisor_workspace="${fixture_root}/supervisor-workspace"
	mkdir -p "$supervisor_workspace" || return 0
	git_probe=$(create_prospective_git_probe) || return 0
	transfer_log="${fixture_root}/transfer.log"
	: >"$transfer_log"
	output=$(AIDEVOPS_TEST_TRANSFER_LOG="$transfer_log" AIDEVOPS_TEST_UNRELATED_BLOBS="${fixture_root}/unrelated.blobs" \
		run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url" 'testorg/testrepo' \
		"$supervisor_workspace" "$git_probe") || rc=$?
	storage_after=$(prospective_git_storage_digest "$fixture_dir")
	if /usr/bin/git -C "$fixture_dir" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then absent_after=1; fi
	prospective_contexts_clean "$fixture_dir" || cleanup_rc=$?
	prospective_hostile_git_environment_clean "$fixture_dir" || environment_rc=$?
	[[ "$rc" -eq 0 && "$cleanup_rc" -eq 0 && "$environment_rc" -eq 0 &&
		"$absent_before" -eq 0 && "$absent_after" -eq 0 &&
		"$storage_before" == "$storage_after" ]] || isolation_rc=1
	print_result "prospective TODO: explicit target objects fetch from a non-Git supervisor workspace" "$isolation_rc" \
		"rc=$rc output=$output"
	print_result "prospective TODO: unrelated large history blobs are not transferred" \
		"$([[ "$(<"$transfer_log")" == "checked" ]] && printf '0' || printf '1')" \
		"log=$(<"$transfer_log")"

	rc=0
	output=$(AIDEVOPS_PROSPECTIVE_FETCH_TIMEOUT=1 AIDEVOPS_TEST_FETCH_DELAY=5 \
		run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url" 'testorg/testrepo' \
		"$supervisor_workspace" "$git_probe") || rc=$?
	cleanup_rc=0
	prospective_contexts_clean "$fixture_dir" || cleanup_rc=$?
	print_result "prospective TODO: bounded object transfer timeout fails closed" \
		"$([[ "$rc" -ne 0 && "$cleanup_rc" -eq 0 && "$output" == *"object transfer exceeded 1s"* ]] && printf '0' || printf '1')" \
		"output=$output"

	rc=0
	/usr/bin/git -C "$remote_url" config uploadpack.allowFilter false || return 0
	output=$(run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url" 'testorg/testrepo' \
		"$supervisor_workspace") || rc=$?
	/usr/bin/git -C "$remote_url" config uploadpack.allowFilter true || return 0
	print_result "prospective TODO: remote without partial fetch support fails closed" \
		"$([[ "$rc" -ne 0 && "$output" == *"does not support partial fetch"* ]] && printf '0' || printf '1')" \
		"output=$output"

	rc=0
	output=$(run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url" 'otherorg/otherrepo') || rc=$?
	print_result "prospective TODO: target repository mismatch fails closed" \
		"$([[ "$rc" -ne 0 && "$output" == *"does not match the explicit target"* ]] && printf '0' || printf '1')" \
		"output=$output"

	rc=0
	output=$(run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" stub 'https://attacker.invalid/testorg/testrepo.git') || rc=$?
	print_result "prospective TODO: target remote URL mismatch fails closed" \
		"$([[ "$rc" -ne 0 && "$output" == *"remote URL does not match the explicit target"* ]] && printf '0' || printf '1')" \
		"output=$output"
	return 0
}

test_prospective_todo_crisscross_fetch_guard() {
	local fixture_dir="" fixture_root="" base_sha="" head_sha="" remote_url="" git_probe="" output="" rc=0
	local no_timeout_dir=""
	fixture_dir=$(create_prospective_crisscross_fixture) || return 0
	fixture_root="${fixture_dir%/caller}"
	base_sha=$(<"${fixture_root}/base.sha")
	head_sha=$(<"${fixture_root}/head.sha")
	remote_url=$(<"${fixture_root}/remote.url")
	output=$(run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url") || rc=$?
	print_result "prospective TODO: criss-cross virtual merge base blobs are materialized" "$rc" "output=$output"

	rc=0
	no_timeout_dir=$(create_no_timeout_path_dir) || return 0
	output=$(AIDEVOPS_TEST_GUARD_PATH="${TEST_ROOT}/bin:${SCRIPT_DIR}/..:${no_timeout_dir}" \
		run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url") || rc=$?
	print_result "prospective TODO: blobs are materialized without timeout/gtimeout (GH#33619)" "$rc" "output=$output"

	rc=0
	git_probe=$(create_prospective_git_probe) || return 0
	output=$(AIDEVOPS_TEST_SKIP_BLOB_FETCH=1 \
		run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url" 'testorg/testrepo' \
		"$fixture_dir" "$git_probe") || rc=$?
	print_result "prospective TODO: blobs missing after a zero-exit fetch fail closed with counts" \
		"$([[ "$rc" -ne 0 && "$output" == *"required prospective blobs were not materialized"* && "$output" != *"lazy fetching disabled"* ]] && printf '0' || printf '1')" \
		"output=$output"
	rc=0
	prospective_contexts_clean "$fixture_dir" || rc=$?
	print_result "prospective TODO: criss-cross checks clean isolated contexts" "$rc"
	return 0
}
