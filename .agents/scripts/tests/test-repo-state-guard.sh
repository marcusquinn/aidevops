#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

call_log="${tmp_dir}/gh-calls.log"
mode_file="${tmp_dir}/mode"
printf 'external\n' >"$mode_file"

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GH_CALL_LOG}"
mode=$(cat "${GH_MODE_FILE}")
if [[ "$1" == "api" && "$2" == "user" ]]; then
  printf '%s\n' "tester"
  exit 0
fi
if [[ "$1" == "api" && "$2" == "-i" && "${3:-}" == */collaborators/*/permission ]]; then
  if [[ "$mode" == "managed" ]]; then
    printf 'HTTP/2.0 200 OK\n\n{"permission":"write"}\n'
    exit 0
  fi
  printf 'HTTP/2.0 403 Forbidden\n\n{"message":"Must have push access"}\n' >&2
  exit 1
fi
if [[ "$1" == "api" && ( "$2" == repos/*/collaborators/*/permission || "$2" == /repos/*/collaborators/*/permission ) ]]; then
  if [[ "$mode" == "managed" ]]; then
    printf '%s\n' "write"
    exit 0
  fi
  if [[ "$mode" == "routine-maintain" ]]; then
    printf '%s\n' "maintain"
    exit 0
  fi
  printf '%s\n' '{"message":"Must have push access"}' >&2
  exit 1
fi
if [[ "$1" == "api" && "$2" == repos/*/issues/*/comments ]]; then
  if [[ "$mode" == "posted" ]]; then
    printf '%s\n' '[]'
    exit 0
  fi
  printf '%s\n' '{"id":123}'
  exit 0
fi
exit 0
STUB
chmod +x "${tmp_dir}/bin/gh"

export PATH="${tmp_dir}/bin:${PATH}"
export GH_CALL_LOG="$call_log"
export GH_MODE_FILE="$mode_file"
export DISPATCH_CLAIM_WINDOW=0
export AIDEVOPS_VERSION_FILE="${tmp_dir}/VERSION"
printf '9.9.9\n' >"$AIDEVOPS_VERSION_FILE"

# shellcheck source=../shared-repo-state-guard.sh
source "${AGENTS_SCRIPTS_DIR}/shared-repo-state-guard.sh"

pass_count=0
fail_count=0

check() {
	local condition="$1"
	local name="$2"
	local detail="${3:-}"
	if [[ "$condition" == "1" ]]; then
		printf 'PASS %s\n' "$name"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL %s %s\n' "$name" "$detail"
		fail_count=$((fail_count + 1))
	fi
	return 0
}

if aidevops_can_manage_repo_issue_state "tester/project"; then
	check 1 "repo owner may manage state"
else
	check 0 "repo owner may manage state"
fi

if aidevops_can_run_repo_routines "tester/project"; then
	check 1 "repo owner may run routines"
else
	check 0 "repo owner may run routines"
fi

if aidevops_can_manage_repo_issue_state "other/project"; then
	check 0 "external non-maintainer is blocked"
else
	check 1 "external non-maintainer is blocked"
fi

if aidevops_can_run_repo_routines "other/project"; then
	check 0 "external non-maintainer routine is blocked"
else
	check 1 "external non-maintainer routine is blocked"
fi

printf 'managed\n' >"$mode_file"
if aidevops_can_manage_repo_issue_state "other/project"; then
	check 1 "write collaborator may manage state"
else
	check 0 "write collaborator may manage state"
fi

if aidevops_can_run_repo_routines "other/project"; then
	check 0 "write collaborator routine is blocked"
else
	check 1 "write collaborator routine is blocked"
fi

printf 'routine-maintain\n' >"$mode_file"
if aidevops_can_run_repo_routines "other/project"; then
	check 1 "maintain collaborator may run routines"
else
	check 0 "maintain collaborator may run routines"
fi

printf 'external\n' >"$mode_file"
: >"$call_log"
if aidevops_can_manage_repo_issue_state "other/project" "tester"; then
	check 0 "explicit user override still blocks external repo"
else
	check 1 "explicit user override still blocks external repo"
fi
if grep -q '^api user' "$call_log"; then
	check 0 "explicit user override skips current-user lookup"
else
	check 1 "explicit user override skips current-user lookup"
fi

: >"$call_log"
set +e
claim_output=$("${AGENTS_SCRIPTS_DIR}/dispatch-claim-helper.sh" claim 866 afragen/git-updater tester 2>&1)
claim_rc=$?
set -e
if [[ "$claim_rc" -eq 1 && "$claim_output" == *"CLAIM_SKIPPED"* ]]; then
	check 1 "dispatch claim blocks unmanaged repo"
else
	check 0 "dispatch claim blocks unmanaged repo" "rc=${claim_rc} output=${claim_output}"
fi

if grep -q 'repos/afragen/git-updater/issues/866/comments' "$call_log"; then
	check 0 "unmanaged dispatch claim posts no comment"
else
	check 1 "unmanaged dispatch claim posts no comment"
fi

if grep -q '^api user' "$call_log"; then
	check 0 "dispatch claim passes resolved runner to state guard"
else
	check 1 "dispatch claim passes resolved runner to state guard"
fi

set +e
release_skip_output=$(bash -c '
  source "${0}/shared-constants.sh"
  source "${0}/worker-lifecycle-common.sh"
  source "${0}/headless-runtime-failure.sh"
  WORKER_ISSUE_NUMBER=866 DISPATCH_REPO_SLUG=afragen/git-updater _release_dispatch_claim issue-866 worker_complete 0 0
' "$AGENTS_SCRIPTS_DIR" 2>&1)
release_skip_rc=$?
set -e
if [[ "$release_skip_rc" -eq 0 && "$release_skip_output" == *"Skipping CLAIM_RELEASED"* ]]; then
	check 1 "unmanaged release skips comment"
else
	check 0 "unmanaged release skips comment" "rc=${release_skip_rc} output=${release_skip_output}"
fi

printf 'managed\n' >"$mode_file"
set +e
release_output=$(bash -c '
  source "${0}/shared-constants.sh"
  source "${0}/worker-lifecycle-common.sh"
  source "${0}/headless-runtime-failure.sh"
  WORKER_ISSUE_NUMBER=866 DISPATCH_REPO_SLUG=afragen/git-updater _release_dispatch_claim issue-866 worker_complete 0 0
' "$AGENTS_SCRIPTS_DIR" 2>&1)
release_rc=$?
set -e
if [[ "$release_rc" -eq 0 && "$release_output" == *"Released claim"* ]]; then
	check 1 "managed release still posts"
else
	check 0 "managed release still posts" "rc=${release_rc} output=${release_output}"
fi

printf '\nResult: %d passed, %d failed\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
