#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u
# Fixture repositories are disposable; bypass interactive canonical-repo guards.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
PUBLISHER="${SCRIPT_DIR_TEST}/../planning-publisher.sh"
PASS=0
FAIL=0

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}
fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL %s: %s\n' "$name" "$detail"
	FAIL=$((FAIL + 1))
	return 0
}

setup_repo() {
	local root="$1"
	git init --bare --initial-branch=main "${root}/remote.git" >/dev/null 2>&1 || git init --bare "${root}/remote.git" >/dev/null 2>&1 || return 1
	git clone "${root}/remote.git" "${root}/work" >/dev/null 2>&1 || return 1
	printf '# Tasks\n' >"${root}/work/TODO.md"
	mkdir -p "${root}/work/todo/tasks" || return 1
	printf 'base\n' >"${root}/work/README.md"
	git -C "${root}/work" add TODO.md README.md || return 1
	GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid \
		git -C "${root}/work" commit -m seed >/dev/null || return 1
	git -C "${root}/work" push origin main >/dev/null 2>&1 || return 1
	return 0
}

state_digest() {
	local repo="$1"
	{
		git -C "$repo" rev-parse HEAD
		git -C "$repo" ls-files -s
		git -C "$repo" diff --binary
		git -C "$repo" diff --cached --binary
	} | git hash-object --stdin
	return 0
}

run_publish() {
	local repo="$1"
	local validator="${2:-/usr/bin/true}"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_VALIDATOR="$validator" planning_publish "$repo" "plan: test publication" origin main
	)
	return $?
}

test_state_allowlist_and_idempotence() {
	local name="preserves local state, publishes only allowlisted bytes, and is idempotent"
	local root="" repo="" before="" after="" first_remote="" second_remote="" count=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t001 test ref:GH#1' >>"${repo}/TODO.md"
	printf 'brief\n' >"${repo}/todo/tasks/t001.md"
	printf 'local-only\n' >>"${repo}/README.md"
	git -C "$repo" add README.md
	before=$(state_digest "$repo")
	run_publish "$repo" || {
		fail "$name" publish
		return 0
	}
	after=$(state_digest "$repo")
	first_remote=$(git --git-dir="${root}/remote.git" rev-parse main)
	run_publish "$repo" || {
		fail "$name" replay
		return 0
	}
	second_remote=$(git --git-dir="${root}/remote.git" rev-parse main)
	count=$(git --git-dir="${root}/remote.git" log --format=%B main | grep -c 'Planning-Publication-ID:' || true)
	if [[ "$before" == "$after" && "$first_remote" == "$second_remote" && "$count" -eq 1 ]] &&
		git --git-dir="${root}/remote.git" show main:TODO.md | grep -q t001 &&
		[[ "$(git --git-dir="${root}/remote.git" show main:README.md)" == "base" ]]; then pass "$name"; else fail "$name" invariant; fi
	rm -rf "$root"
	return 0
}

test_validation_failure_pushes_nothing() {
	local name="validator failure pushes nothing"
	local root="" repo="" before="" rc=0
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t002 rejected ref:GH#2' >>"${repo}/TODO.md"
	before=$(git --git-dir="${root}/remote.git" rev-parse main)
	run_publish "$repo" /usr/bin/false || rc=$?
	if [[ $rc -ne 0 && "$before" == "$(git --git-dir="${root}/remote.git" rev-parse main)" ]]; then pass "$name"; else fail "$name" "rc=$rc"; fi
	rm -rf "$root"
	return 0
}

test_contention_replay_and_conflict() {
	local name="replays unrelated contention"
	local root="" repo="" hook="" rc=0
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t003 replay ref:GH#3' >>"${repo}/TODO.md"
	hook="${root}/contend.sh"
	cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
repo="$1"; remote="$2"; branch="$3"; attempt="$6"
[[ "$attempt" == "1" ]] || exit 0
tmp=$(mktemp -d)
git clone -q "$(git -C "$repo" remote get-url "$remote")" "$tmp/work"
printf 'upstream\n' >>"$tmp/work/README.md"
git -C "$tmp/work" add README.md
GIT_AUTHOR_NAME=Rival GIT_AUTHOR_EMAIL=rival@example.invalid GIT_COMMITTER_NAME=Rival GIT_COMMITTER_EMAIL=rival@example.invalid git -C "$tmp/work" commit -qm rival
git -C "$tmp/work" push -q origin "$branch"
rm -rf "$tmp"
exit 0
HOOK
	chmod +x "$hook"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK="$hook" planning_publish "$repo" "plan: contention" origin main
	) || rc=$?
	if [[ $rc -eq 0 ]] && git --git-dir="${root}/remote.git" show main:README.md | grep -q upstream && git --git-dir="${root}/remote.git" show main:TODO.md | grep -q t003; then pass "$name"; else fail "$name" "replay rc=$rc"; fi
	rm -rf "$root"
	return 0
}

test_crash_replay_is_single_publication() {
	local name="crash before push replays once"
	local root="" repo="" rc=0 count=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t004 crash replay ref:GH#4' >>"${repo}/TODO.md"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK=/usr/bin/false planning_publish "$repo" "plan: crash" origin main
	) || rc=$?
	if [[ $rc -eq 0 ]]; then
		fail "$name" "simulated crash succeeded"
		rm -rf "$root"
		return 0
	fi
	run_publish "$repo" || {
		fail "$name" replay
		rm -rf "$root"
		return 0
	}
	run_publish "$repo" || {
		fail "$name" idempotence
		rm -rf "$root"
		return 0
	}
	count=$(git --git-dir="${root}/remote.git" log --format=%B main | grep -c 'Planning-Publication-ID:' || true)
	if [[ $count -eq 1 ]]; then pass "$name"; else fail "$name" "publication count=$count"; fi
	rm -rf "$root"
	return 0
}

test_same_path_contention_is_retryable() {
	local name="same-path contention returns retryable conflict"
	local root="" repo="" hook="" rc=0 remote_todo=""
	root=$(mktemp -d) || return 0
	setup_repo "$root" || {
		fail "$name" setup
		return 0
	}
	repo="${root}/work"
	printf '%s\n' '- [ ] t005 local ref:GH#5' >>"${repo}/TODO.md"
	hook="${root}/same-path.sh"
	cat >"$hook" <<'HOOK'
#!/usr/bin/env bash
repo="$1"; remote="$2"; branch="$3"; attempt="$6"
[[ "$attempt" == "1" ]] || exit 0
tmp=$(mktemp -d)
git clone -q "$(git -C "$repo" remote get-url "$remote")" "$tmp/work"
printf '%s\n' '- [ ] t999 rival ref:GH#999' >>"$tmp/work/TODO.md"
git -C "$tmp/work" add TODO.md
GIT_AUTHOR_NAME=Rival GIT_AUTHOR_EMAIL=rival@example.invalid GIT_COMMITTER_NAME=Rival GIT_COMMITTER_EMAIL=rival@example.invalid git -C "$tmp/work" commit -qm rival
git -C "$tmp/work" push -q origin "$branch"
rm -rf "$tmp"
exit 0
HOOK
	chmod +x "$hook"
	(
		SCRIPT_DIR="$(dirname "$PUBLISHER")"
		# shellcheck source=../planning-publisher.sh
		source "$PUBLISHER"
		AIDEVOPS_PLANNING_VALIDATOR=/usr/bin/true AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK="$hook" planning_publish "$repo" "plan: conflict" origin main
	) || rc=$?
	remote_todo=$(git --git-dir="${root}/remote.git" show main:TODO.md)
	if [[ $rc -eq 2 && "$remote_todo" == *"t999"* && "$remote_todo" != *"t005"* ]]; then pass "$name"; else fail "$name" "rc=$rc"; fi
	rm -rf "$root"
	return 0
}

main() {
	test_state_allowlist_and_idempotence
	test_validation_failure_pushes_nothing
	test_contention_replay_and_conflict
	test_crash_replay_is_single_publication
	test_same_path_contention_is_retryable
	printf '%s passed, %s failed\n' "$PASS" "$FAIL"
	[[ $FAIL -eq 0 ]] || return 1
	return 0
}

main "$@"
