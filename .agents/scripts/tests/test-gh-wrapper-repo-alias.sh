#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
CALLS_FILE="$(mktemp -t gh-wrapper-repo-alias.XXXXXX)"
TARGET_ROOT="$(mktemp -d -t gh-wrapper-repo-target.XXXXXX)"
trap 'rm -f "$CALLS_FILE"; rm -rf "$TARGET_ROOT"' EXIT

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=../shared-gh-wrappers.sh
source "${SCRIPTS_DIR}/shared-gh-wrappers.sh"

privacy_guard_public_write() {
	local repo="$1"
	local text="$2"
	printf '<%s> <%s>\n' "$repo" "$text" >>"$CALLS_FILE"
	if [[ -n "$repo" ]]; then
		return 0
	fi
	return 1
}

# Keep rejection paths out of the operator's real audit log, and keep target
# inference independent of the caller's environment.
_gh_edit_audit_rejection() {
	return 0
}
unset GH_REPO GH_HOST

failures=0

if [[ "$(_gh_extract_repo_from_args -R owner/repo --title example)" == "owner/repo" ]]; then
	printf 'PASS: safe-edit extraction accepts -R\n'
else
	printf 'FAIL: safe-edit extraction accepts -R\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _gh_guard_public_write_args -R public/repo --title "Public title" &&
	grep -Fq '<public/repo>' "$CALLS_FILE"; then
	printf 'PASS: privacy guard receives -R repository\n'
else
	printf 'FAIL: privacy guard receives -R repository\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _gh_guard_public_write_args -R --title "Missing repository"; then
	printf 'FAIL: missing -R value fails closed\n'
	failures=$((failures + 1))
else
	printf 'PASS: missing -R value fails closed\n'
fi

# GH#39801: an omitted --repo resolves to the checkout's base repository and is
# pinned once, so the privacy guard and the native/REST transport share it.
mkdir -p "${TARGET_ROOT}/checkout" "${TARGET_ROOT}/plain"
git -C "${TARGET_ROOT}/checkout" init -q
git -C "${TARGET_ROOT}/checkout" remote add origin https://github.com/inferred/repo.git
: >"$CALLS_FILE"
pinned=""
if (cd "${TARGET_ROOT}/checkout" &&
	_gh_wrapper_pin_target_repo "gh pr create" --title "Inferred" --body "Body" &&
	_gh_guard_public_write_args "${_GH_WRAPPER_TARGET_ARGS[@]}" &&
	printf '%s|' "${_GH_WRAPPER_TARGET_ARGS[@]}" >"${TARGET_ROOT}/pinned"); then
	pinned=$(<"${TARGET_ROOT}/pinned")
fi
if [[ "$pinned" == "--title|Inferred|--body|Body|--repo|inferred/repo|" ]] &&
	grep -Fq '<inferred/repo>' "$CALLS_FILE"; then
	printf 'PASS: omitted --repo pins the checkout repository for guard and transport\n'
else
	printf 'FAIL: omitted --repo pins the checkout repository for guard and transport (%s)\n' "$pinned"
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
unresolved_rc=0
unresolved_err=$(cd "${TARGET_ROOT}/plain" &&
	_gh_wrapper_pin_target_repo "gh issue create" --title "Nowhere" 2>&1 >/dev/null) || unresolved_rc=$?
if [[ "$unresolved_rc" -ne 0 && "$unresolved_err" == *"no target repository"* && ! -s "$CALLS_FILE" ]]; then
	printf 'PASS: unresolvable target blocks with a target diagnostic before the privacy guard\n'
else
	printf 'FAIL: unresolvable target blocks with a target diagnostic (rc=%s err=%s)\n' "$unresolved_rc" "$unresolved_err"
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
url_args=""
if (cd "${TARGET_ROOT}/plain" &&
	_gh_wrapper_pin_target_repo "gh issue comment" https://github.com/url/repo/issues/7 --body "Hi" &&
	_gh_guard_public_write_args "${_GH_WRAPPER_TARGET_ARGS[@]}" &&
	printf '%s|' "${_GH_WRAPPER_TARGET_ARGS[@]}" >"${TARGET_ROOT}/url-args"); then
	url_args=$(<"${TARGET_ROOT}/url-args")
fi
if [[ "$url_args" == "https://github.com/url/repo/issues/7|--body|Hi|" ]] &&
	grep -Fq '<url/repo>' "$CALLS_FILE"; then
	printf 'PASS: URL target reaches the guard without an injected --repo\n'
else
	printf 'FAIL: URL target reaches the guard without an injected --repo (%s)\n' "$url_args"
	failures=$((failures + 1))
fi

if _gh_wrapper_pin_target_repo "gh issue comment" https://github.com/url/repo/issues/7 \
	--repo other/repo --body "Hi" 2>/dev/null; then
	printf 'FAIL: URL and --repo naming different repositories fail closed\n'
	failures=$((failures + 1))
else
	printf 'PASS: URL and --repo naming different repositories fail closed\n'
fi

ensure_origin_labels_exist() {
	local repo="$1"
	printf '<origin-labels> <%s>\n' "$repo" >>"$CALLS_FILE"
	return 0
}

: >"$CALLS_FILE"
_ORIGIN_LABELS_ENSURED=""
_ensure_origin_labels_for_args -R labels/repo --title example
if grep -Fq '<origin-labels> <labels/repo>' "$CALLS_FILE"; then
	printf 'PASS: origin-label provisioning accepts -R\n'
else
	printf 'FAIL: origin-label provisioning accepts -R\n'
	failures=$((failures + 1))
fi

gh() {
	printf '<gh> %s\n' "$*" >>"$CALLS_FILE"
	case "$*" in
	*'/pulls'*) printf 'https://github.com/rest/repo/pull/7\n' ;;
	*) printf 'https://github.com/rest/repo/issues/42\n' ;;
	esac
	return 0
}

_rest_api_call() {
	local request_class="$1"
	shift
	printf '<rest:%s> %s\n' "$request_class" "$*" >>"$CALLS_FILE"
	if [[ "$request_class" == "read" ]]; then
		printf '{"labels":[],"assignees":[]}\n'
	fi
	return 0
}

: >"$CALLS_FILE"
if _rest_issue_create -R rest/repo --title "REST issue" >/dev/null &&
	grep -Fq '/repos/rest/repo/issues' "$CALLS_FILE"; then
	printf 'PASS: REST issue create accepts -R\n'
else
	printf 'FAIL: REST issue create accepts -R\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _rest_issue_comment 42 -R rest/repo --body "REST comment" >/dev/null &&
	grep -Fq '/repos/rest/repo/issues/42/comments' "$CALLS_FILE"; then
	printf 'PASS: REST issue comment accepts -R\n'
else
	printf 'FAIL: REST issue comment accepts -R\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _rest_issue_edit 42 -R rest/repo --title "REST edit" &&
	grep -Fq '/repos/rest/repo/issues/42' "$CALLS_FILE"; then
	printf 'PASS: REST issue edit accepts -R\n'
else
	printf 'FAIL: REST issue edit accepts -R\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _rest_issue_edit_preserving_deltas 42 -R rest/repo --add-label status:in-review &&
	grep -Fq '/repos/rest/repo/issues/42/labels' "$CALLS_FILE"; then
	printf 'PASS: REST preserving edit accepts -R\n'
else
	printf 'FAIL: REST preserving edit accepts -R\n'
	failures=$((failures + 1))
fi

: >"$CALLS_FILE"
if _rest_pr_create -R rest/repo --title "REST PR" --head feature --base main >/dev/null &&
	grep -Fq '/repos/rest/repo/pulls' "$CALLS_FILE"; then
	printf 'PASS: REST PR create accepts -R\n'
else
	printf 'FAIL: REST PR create accepts -R\n'
	failures=$((failures + 1))
fi

exit "$failures"
