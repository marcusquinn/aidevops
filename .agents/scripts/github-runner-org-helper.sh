#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Onboard a GitHub org onto org-scoped, GitHub-App-authenticated, ephemeral
# self-hosted runners: private-only runner group, App key verification and
# key delivery to the runner host. Server-side runner services stay
# operator-owned. Key material is read only from an env var injected by
# `aidevops secret NAME -- ...`; it is never printed, put in argv or written
# to local files. Only the public-key SHA-256 is displayed.
#
# Usage: github-runner-org-helper.sh help

set -euo pipefail

RUNNER_ORG_HELPER_DIR="${RUNNER_ORG_HELPER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
if [[ -r "${RUNNER_ORG_HELPER_DIR}/shared-constants.sh" ]]; then
	source "${RUNNER_ORG_HELPER_DIR}/shared-constants.sh" 2>/dev/null || true
fi

RUNNER_ORG_SELF="${BASH_SOURCE[0]}"
RUNNER_ORG_REEXEC_GUARD="RUNNER_ORG_HELPER_REEXEC"
RUNNER_ORG_REQUIRED_PERMISSIONS='{"organization_self_hosted_runners":"write"}'

_ro_err() {
	local msg="$1"
	printf 'ERROR: %s\n' "$msg" >&2
	return 0
}

_ro_require_tools() {
	local tool
	for tool in "$@"; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			_ro_err "required tool unavailable: ${tool}"
			return 1
		fi
	done
	return 0
}

_ro_b64url() {
	openssl base64 -A | tr '+/' '-_' | tr -d '='
	return 0
}

_ro_gpath() {
	local org="$1"
	local gid="$2"
	printf 'orgs/%s/actions/runner-groups/%s' "$org" "$gid"
	return 0
}

_ro_valid_name() {
	local value="$1"
	[[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
	return $?
}

_ro_valid_secret_name() {
	local value="$1"
	[[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
	return $?
}

# Classify a gh failure without echoing response bodies.
_ro_gh_fail() {
	local context="$1"
	local err_file="$2"
	if grep -Eqi '403|forbidden|permission|resource not accessible|admin:org|authentication|401' "$err_file" 2>/dev/null; then
		_ro_err "${context}: permission denied (gh token needs admin:org)"
	elif grep -Eqi '404|not found' "$err_file" 2>/dev/null; then
		_ro_err "${context}: not found"
	else
		_ro_err "${context}: API request failed"
	fi
	return 0
}

# Run gh api with captured stdout; error text is classified, not echoed.
_ro_api() {
	local context="$1"
	shift
	local err_file out
	err_file=$(mktemp)
	if out="$(gh api "$@" 2>"$err_file")"; then
		rm -f "$err_file"
		printf '%s' "$out"
		return 0
	fi
	_ro_gh_fail "$context" "$err_file"
	rm -f "$err_file"
	return 1
}

# ---------------------------------------------------------------- status

cmd_status() {
	local org="" group=""
	while [[ $# -gt 0 ]]; do
		local opt="$1" val="${2:-}"
		case "$opt" in
		--org)
			org="$val"
			shift 2
			;;
		--group)
			group="$val"
			shift 2
			;;
		*)
			_ro_err "status: unknown option: ${opt}"
			return 1
			;;
		esac
	done
	if ! _ro_valid_name "$org"; then
		_ro_err "status: --org is required"
		return 1
	fi
	_ro_require_tools gh jq || return 1

	local groups
	groups=$(_ro_api "list runner groups" --paginate "orgs/${org}/actions/runner-groups" --jq '.runner_groups[]' | jq -sc '.') || return 1
	printf 'Runner groups for %s:\n' "$org"
	local gid gname visibility public count
	while IFS=$'\t' read -r gid gname visibility public; do
		[[ -z "$gid" ]] && continue
		count="all"
		if [[ "$visibility" == selected ]]; then
			count=$(_ro_api "list group repositories" "$(_ro_gpath "$org" "$gid")/repositories" --jq '.total_count') || count="unknown"
		fi
		printf '  %s\tid=%s\tvisibility=%s\tpublic=%s\trepos=%s\n' "$gname" "$gid" "$visibility" "$public" "$count"
	done < <(printf '%s' "$groups" | jq -r --arg g "$group" '.[] | select($g == "" or .name == $g) | [.id, .name, .visibility, .allows_public_repositories] | @tsv')

	if [[ -n "$group" ]]; then
		gid=$(printf '%s' "$groups" | jq -r --arg g "$group" '.[] | select(.name == $g) | .id' | sed -n '1p')
		if [[ -z "$gid" ]]; then
			_ro_err "status: group not found: ${group}"
			return 1
		fi
		printf 'Runners in group %s:\n' "$group"
		_ro_api "list group runners" --paginate "orgs/${org}/actions/runner-groups/${gid}/runners" \
			--jq '.runners[] | "  \(.name)\tstatus=\(.status)\tbusy=\(.busy)\tlabels=\([.labels[].name] | join(","))"' || return 1
		printf '\n'
	fi
	return 0
}

# ----------------------------------------------------------- group-ensure

# Resolve target repos into a JSON array of {id,name,private}. Refuses public.
_ro_resolve_repos() {
	local org="$1"
	local spec="$2"
	local repos
	if [[ "$spec" == "all-private" ]]; then
		repos=$(_ro_api "list org repositories" --paginate "orgs/${org}/repos" \
			--jq '.[] | select(.private and (.archived | not)) | {id, name, private}' | jq -sc '.') || return 1
	else
		local name entries=""
		local IFS=','
		for name in $spec; do
			if ! _ro_valid_name "$name"; then
				_ro_err "group-ensure: invalid repo name in --repos"
				return 1
			fi
			local one
			one=$(_ro_api "resolve repo ${name}" "repos/${org}/${name}" --jq '{id, name, private}') || return 1
			entries+="${one}"$'\n'
		done
		repos=$(printf '%s' "$entries" | jq -sc '.')
	fi
	if printf '%s' "$repos" | jq -e 'any(.[]; .private != true)' >/dev/null; then
		_ro_err "group-ensure: refusing public repository in runner group"
		return 1
	fi
	printf '%s' "$repos"
	return 0
}

_ro_print_group() {
	local org="$1"
	local gid="$2"
	local group_json
	group_json=$(_ro_api "re-read runner group" "orgs/${org}/actions/runner-groups/${gid}") || return 1
	local visibility public
	visibility=$(printf '%s' "$group_json" | jq -r '.visibility')
	public=$(printf '%s' "$group_json" | jq -r '.allows_public_repositories')
	local repos
	repos=$(_ro_api "re-read group repositories" --paginate "$(_ro_gpath "$org" "$gid")/repositories" \
		--jq '.repositories[] | "\(.name)\t\(.private)"') || return 1
	printf 'Group id: %s\nvisibility: %s\nallows_public_repositories: %s\nSelected repositories:\n' "$gid" "$visibility" "$public"
	printf '%s\n' "$repos" | cut -f1 | sed 's/^/  /'
	if [[ "$public" == "true" ]] || printf '%s\n' "$repos" | cut -f2 | grep -x 'false' >/dev/null; then
		_ro_err "group-ensure: group allows public repositories or contains a public repo"
		return 1
	fi
	return 0
}

cmd_group_ensure() {
	local org="" name="" repos_spec="all-private" dry_run=false
	while [[ $# -gt 0 ]]; do
		local opt="$1" val="${2:-}"
		case "$opt" in
		--org)
			org="$val"
			shift 2
			;;
		--name)
			name="$val"
			shift 2
			;;
		--repos)
			repos_spec="$val"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		*)
			_ro_err "group-ensure: unknown option: ${opt}"
			return 1
			;;
		esac
	done
	if ! _ro_valid_name "$org" || [[ -z "$name" || ! "$name" =~ ^[A-Za-z0-9._\ -]+$ ]]; then
		_ro_err "group-ensure: --org and --name are required"
		return 1
	fi
	_ro_require_tools gh jq || return 1

	local repos ids
	repos=$(_ro_resolve_repos "$org" "$repos_spec") || return 1
	ids=$(printf '%s' "$repos" | jq -c '[.[].id]')

	local existing gid
	existing=$(_ro_api "list runner groups" --paginate "orgs/${org}/actions/runner-groups" --jq '.runner_groups[]' | jq -sc '.') || return 1
	gid=$(printf '%s' "$existing" | jq -r --arg n "$name" '[.[] | select(.name == $n)][0].id // empty')

	local create_payload update_payload
	create_payload=$(jq -nc --arg n "$name" --argjson ids "$ids" \
		'{name: $n, visibility: "selected", allows_public_repositories: false, selected_repository_ids: $ids}')
	update_payload=$(printf '%s' "$create_payload" | jq -c 'del(.selected_repository_ids)')

	if [[ "$dry_run" == "true" ]]; then
		printf 'DRY-RUN: org=%s group=%s action=%s\n' "$org" "$name" "$([[ -n "$gid" ]] && echo reconcile || echo create)"
		printf 'DRY-RUN: allows_public_repositories=false visibility=selected\n'
		printf 'DRY-RUN: payload=%s\n' "$create_payload"
		printf 'DRY-RUN: repositories:\n'
		printf '%s' "$repos" | jq -r '.[] | "  \(.name)"'
		return 0
	fi

	if [[ -z "$gid" ]]; then
		local err_file out
		err_file=$(mktemp)
		if out="$(printf '%s' "$create_payload" | gh api -X POST "orgs/${org}/actions/runner-groups" --input - 2>"$err_file")"; then
			gid=$(printf '%s' "$out" | jq -r '.id')
		elif grep -Eqi '409|422|already exists|name.*taken' "$err_file"; then
			# Concurrent creator won the race: reconcile the existing group.
			gid="$(_ro_api "re-list runner groups" --paginate "orgs/${org}/actions/runner-groups" \
				--jq ".runner_groups[] | select(.name == \"${name}\") | .id" | sed -n '1p')" || {
				rm -f "$err_file"
				return 1
			}
		else
			_ro_gh_fail "create runner group" "$err_file"
			rm -f "$err_file"
			return 1
		fi
		rm -f "$err_file"
	fi
	if [[ -z "$gid" ]]; then
		_ro_err "group-ensure: could not determine group id"
		return 1
	fi

	printf '%s' "$update_payload" | _ro_api "update runner group" -X PATCH "orgs/${org}/actions/runner-groups/${gid}" --input - >/dev/null || return 1
	jq -nc --argjson ids "$ids" '{selected_repository_ids: $ids}' |
		_ro_api "set group repositories" -X PUT "$(_ro_gpath "$org" "$gid")/repositories" --input - >/dev/null || return 1

	_ro_print_group "$org" "$gid"
	return $?
}

# ---------------------------------------------------------------- key use

# Ensure the key env var is present; otherwise re-exec via aidevops secret.
_ro_ensure_key_env() {
	local secret="$1"
	shift
	if ! _ro_valid_secret_name "$secret"; then
		_ro_err "invalid --secret name"
		return 1
	fi
	if [[ -n "${!secret:-}" ]]; then
		return 0
	fi
	if [[ -n "${!RUNNER_ORG_REEXEC_GUARD:-}" ]]; then
		_ro_err "secret ${secret} is empty or missing"
		return 1
	fi
	_ro_require_tools aidevops || return 1
	export "${RUNNER_ORG_REEXEC_GUARD}=1"
	exec aidevops secret "$secret" -- "$RUNNER_ORG_SELF" "$@"
}

# Public-key SHA-256 of the key held in env var $1.
_ro_local_fingerprint() {
	local secret="$1"
	printf '%s\n' "${!secret}" | openssl pkey -pubout 2>/dev/null | openssl dgst -sha256 -r | cut -d' ' -f1
	return 0
}

_ro_make_jwt() {
	local secret="$1"
	local app_id="$2"
	local now header payload sig
	now=$(date -u '+%s')
	header=$(printf '{"alg":"RS256","typ":"JWT"}' | _ro_b64url)
	payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 300))" "$app_id" | _ro_b64url)
	sig=$(printf '%s' "${header}.${payload}" | openssl dgst -sha256 -sign <(printf '%s\n' "${!secret}") | _ro_b64url) || return 1
	printf '%s.%s.%s' "$header" "$payload" "$sig"
	return 0
}

# gh api with a Bearer JWT; token is passed via env, not argv, using a header file on stdin.
_ro_app_api() {
	local secret="$1"
	local app_id="$2"
	local endpoint="$3"
	local jwt
	jwt=$(_ro_make_jwt "$secret" "$app_id") || {
		_ro_err "failed to sign JWT (invalid key?)"
		return 1
	}
	local err_file out
	err_file=$(mktemp)
	# curl reads headers from stdin (-H @-) so the JWT never appears in argv.
	if out="$(printf 'Authorization: Bearer %s\n' "$jwt" | curl -fsS -H @- \
		-H 'Accept: application/vnd.github+json' "https://api.github.com/${endpoint}" 2>"$err_file")"; then
		rm -f "$err_file"
		printf '%s' "$out"
		return 0
	fi
	_ro_err "GitHub App API request failed: ${endpoint}"
	rm -f "$err_file"
	return 1
}

cmd_verify_key() {
	local org="" app_id="" secret="" original=("$@")
	while [[ $# -gt 0 ]]; do
		local opt="$1" val="${2:-}"
		case "$opt" in
		--org)
			org="$val"
			shift 2
			;;
		--app-id)
			app_id="$val"
			shift 2
			;;
		--secret)
			secret="$val"
			shift 2
			;;
		*)
			_ro_err "verify-key: unknown option: ${opt}"
			return 1
			;;
		esac
	done
	if ! _ro_valid_name "$org" || [[ ! "$app_id" =~ ^[0-9]+$ || -z "$secret" ]]; then
		_ro_err "verify-key: --org, --app-id (numeric) and --secret are required"
		return 1
	fi
	_ro_require_tools jq openssl curl || return 1
	_ro_ensure_key_env "$secret" verify-key "${original[@]}" || return 1

	local app
	app=$(_ro_app_api "$secret" "$app_id" "app") || return 1
	local got_id owner slug
	got_id=$(printf '%s' "$app" | jq -r '.id')
	owner=$(printf '%s' "$app" | jq -r '.owner.login')
	slug=$(printf '%s' "$app" | jq -r '.slug')
	if [[ "$got_id" != "$app_id" ]]; then
		_ro_err "verify-key: App ID mismatch (key belongs to a different App)"
		return 1
	fi
	if [[ "${owner,,}" != "${org,,}" ]]; then
		_ro_err "verify-key: App owner does not match --org"
		return 1
	fi

	local installs inst_id perms
	installs=$(_ro_app_api "$secret" "$app_id" "app/installations") || return 1
	inst_id=$(printf '%s' "$installs" | jq -r --arg o "$org" '[.[] | select(.account.login | ascii_downcase == ($o | ascii_downcase))][0].id // empty')
	if [[ -z "$inst_id" ]]; then
		_ro_err "verify-key: no installation found for org"
		return 1
	fi
	perms=$(printf '%s' "$installs" | jq -c --arg o "$org" '[.[] | select(.account.login | ascii_downcase == ($o | ascii_downcase))][0].permissions')
	if ! printf '%s' "$perms" | jq -e --argjson want "$RUNNER_ORG_REQUIRED_PERMISSIONS" '. == $want' >/dev/null; then
		_ro_err "verify-key: installation permissions are not exactly organization_self_hosted_runners:write"
		return 1
	fi

	printf 'App slug: %s\nApp ID: %s\nInstallation ID: %s\nPublic key SHA-256: %s\nOK: key, owner and permissions verified\n' \
		"$slug" "$got_id" "$inst_id" "$(_ro_local_fingerprint "$secret")"
	return 0
}

_ro_remote_cleanup() {
	local host="$1"
	local path="$2"
	ssh -o BatchMode=yes "$host" "rm -f '${path}'" >/dev/null 2>&1 || true
	return 0
}

cmd_push_key() {
	local secret="" host="" dest="" original=("$@")
	while [[ $# -gt 0 ]]; do
		local opt="$1" val="${2:-}"
		case "$opt" in
		--secret)
			secret="$val"
			shift 2
			;;
		--host)
			host="$val"
			shift 2
			;;
		--dest)
			dest="$val"
			shift 2
			;;
		*)
			_ro_err "push-key: unknown option: ${opt}"
			return 1
			;;
		esac
	done
	if [[ -z "$secret" || ! "$host" =~ ^[A-Za-z0-9._@:-]+$ || "$host" == -* || ! "$dest" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
		_ro_err "push-key: --secret, --host USER@HOST and absolute --dest (safe characters) are required"
		return 1
	fi
	_ro_require_tools openssl ssh || return 1
	_ro_ensure_key_env "$secret" push-key "${original[@]}" || return 1

	local local_fp remote_fp tmp_dest="${dest}.tmp"
	local_fp=$(_ro_local_fingerprint "$secret")
	if [[ -z "$local_fp" ]]; then
		_ro_err "push-key: secret is not a valid private key"
		return 1
	fi

	# Write to DEST.tmp (mode 600 via umask), print remote fingerprint.
	if ! remote_fp="$(printf '%s\n' "${!secret}" | ssh -o BatchMode=yes "$host" \
		"umask 077 && cat > '${tmp_dest}' && chmod 600 '${tmp_dest}' && openssl pkey -in '${tmp_dest}' -pubout | openssl dgst -sha256 -r | cut -d' ' -f1")"; then
		_ro_remote_cleanup "$host" "$tmp_dest"
		_ro_err "push-key: remote write failed"
		return 1
	fi
	if [[ "$remote_fp" != "$local_fp" ]]; then
		_ro_remote_cleanup "$host" "$tmp_dest"
		_ro_err "push-key: fingerprint mismatch; remote temp file removed"
		return 1
	fi
	if ! ssh -o BatchMode=yes "$host" "mv -f '${tmp_dest}' '${dest}'"; then
		_ro_remote_cleanup "$host" "$tmp_dest"
		_ro_err "push-key: remote rename failed"
		return 1
	fi
	printf 'OK: key installed at %s:%s (mode 600)\nPublic key SHA-256 (local = remote): %s\n' "$host" "$dest" "$local_fp"
	return 0
}

# ------------------------------------------------------------------ main

usage() {
	cat <<'EOF'
github-runner-org-helper.sh - org self-hosted runner onboarding (GitHub App, private-only group)

Commands:
  group-ensure --org ORG --name NAME [--repos all-private|r1,r2] [--dry-run]
      Create or reconcile a private-only runner group (allows_public_repositories=false).
  verify-key --org ORG --app-id ID --secret NAME
      Verify the App key (JWT), App ID/owner, and installation permissions.
  push-key --secret NAME --host USER@HOST --dest PATH
      Stream the key over ssh stdin to PATH (mode 600) and compare public-key SHA-256.
  status --org ORG [--group NAME]
      Read-only: runner groups and runners.
  help

The key is read from the env var NAME injected by `aidevops secret NAME -- ...`
(the helper re-executes itself that way when NAME is unset). Key material is
never printed, placed in argv, or written to local files.
EOF
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	status) cmd_status "$@" ;;
	group-ensure) cmd_group_ensure "$@" ;;
	verify-key) cmd_verify_key "$@" ;;
	push-key) cmd_push_key "$@" ;;
	help | -h | --help) usage ;;
	*)
		_ro_err "unknown command: ${command}"
		usage >&2
		return 1
		;;
	esac
	return $?
}

main "$@"
