#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

printf '%s | fetch_mode=%s pull_mode=%s dirty=%s remote_url=%s\n' \
	"$*" \
	"${FAKE_FETCH_MODE:-unset}" \
	"${FAKE_PULL_MODE:-unset}" \
	"${FAKE_DIRTY:-unset}" \
	"${FAKE_REMOTE_URL:-unset}" >>"${FAKE_GIT_LOG:?}"

repo_path=""
helper_used=0
command_name=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-C)
		repo_path="$2"
		shift 2
		;;
	-c)
		[[ "${2:-}" == "credential.helper=!gh auth git-credential" ]] && helper_used=1
		shift 2
		;;
	*)
		command_name="$1"
		shift
		break
		;;
	esac
done

case "$command_name" in
remote)
	if [[ "${1:-}" == "get-url" ]]; then
		printf '%s\n' "${FAKE_REMOTE_URL:-https://github.com/example/repo.git}"
		exit 0
	fi
	printf 'origin\n'
	exit 0
	;;
symbolic-ref)
	printf 'refs/remotes/origin/main\n'
	exit 0
	;;
show-ref)
	exit 0
	;;
diff)
	if [[ "${FAKE_DIRTY:-0}" == "1" ]]; then
		exit 1
	fi
	exit 0
	;;
rev-parse)
	case "${1:-}" in
	--abbrev-ref) printf '%s\n' "${FAKE_CURRENT_BRANCH:-main}" ;;
	--short) printf '%s\n' "${FAKE_SHORT_SHA:-bbbbbbb}" ;;
	HEAD) printf '%s\n' "${FAKE_LOCAL_SHA:-aaaa}" ;;
	origin/main) printf '%s\n' "${FAKE_UPSTREAM_SHA:-aaaa}" ;;
	*) printf '%s\n' "${FAKE_LOCAL_SHA:-aaaa}" ;;
	esac
	exit 0
	;;
fetch)
	case "${FAKE_FETCH_MODE:-success}" in
	success) exit 0 ;;
	auth_then_success)
		if [[ "$helper_used" == "1" ]]; then
			exit 0
		fi
		printf "fatal: could not read Password for 'https://x-access-token:%s@github.com': terminal prompts disabled\n" "${FAKE_TOKEN:-SECRET_TOKEN}" >&2
		exit 1
		;;
	auth_always_fail)
		printf "fatal: Authentication failed for 'https://x-access-token:%s@github.com/example/repo.git'\n" "${FAKE_TOKEN:-SECRET_TOKEN}" >&2
		exit 1
		;;
	*)
		printf 'fatal: fetch failed for a non-auth reason\n' >&2
		exit 1
		;;
	esac
	;;
pull)
	if [[ "${FAKE_PULL_MODE:-success}" == "diverged" ]]; then
		printf 'fatal: Not possible to fast-forward, aborting.\n' >&2
		exit 1
	fi
	exit 0
	;;
*)
	printf 'unexpected git command: %s repo=%s\n' "$command_name" "$repo_path" >&2
	exit 1
	;;
esac
