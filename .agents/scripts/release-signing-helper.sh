#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Read-only release signing preflight; never registers keys or changes trust.

release_signing_preflight() {
	local repo_root="$1"
	local format="" key="" keys="" fingerprint="" registered="" candidate=""
	local program="" key_ids="" exact="" selector=""
	format=$(git -C "$repo_root" config --get gpg.format) || format="openpgp"
	key=$(git -C "$repo_root" config --get user.signingkey) || key=""
	case "$format" in
	ssh)
		if [[ -z "$key" ]]; then
			printf 'Release signing preflight: configure an explicit user.signingkey; dynamic SSH key selection cannot be verified before tagging\n' >&2
			return 1
		fi
		if [[ "$key" == key::* || "$key" == ssh-* ]]; then
			fingerprint=$(printf '%s\n' "${key#key::}" | ssh-keygen -E sha256 -lf /dev/stdin 2>/dev/null) || return 1
		else
			key="${key/#\~\//$HOME/}"
			[[ "$key" == /* ]] || key="${repo_root}/${key}"
			fingerprint=$(ssh-keygen -E sha256 -lf "$key" 2>/dev/null) || {
				printf 'Release signing preflight: cannot fingerprint configured SSH signing key\n' >&2
				return 1
			}
		fi
		fingerprint=$(awk '{print $2}' <<<"$fingerprint")
		keys=$(gh api --paginate --slurp user/ssh_signing_keys) || {
			printf 'Release signing preflight: cannot read authenticated GitHub SSH signing keys; check gh authentication and key-read permission\n' >&2
			return 1
		}
		registered=$(jq -er '.[][] | .key' <<<"$keys") || registered=""
		while IFS= read -r candidate; do
			[[ -n "$candidate" ]] || continue
			candidate=$(printf '%s\n' "$candidate" | ssh-keygen -E sha256 -lf /dev/stdin 2>/dev/null) || continue
			if [[ "$(awk '{print $2}' <<<"$candidate")" == "$fingerprint" ]]; then
				return 0
			fi
		done <<<"$registered"
		printf 'Release signing preflight: SSH key %s is not registered for the authenticated GitHub user; add this public key as an SSH signing key (not an authentication key), then retry\n' "$fingerprint" >&2
		return 1
		;;
	openpgp)
		if [[ -z "$key" ]]; then
			printf 'Release signing preflight: configure an explicit user.signingkey; implicit OpenPGP signer selection cannot be verified before tagging\n' >&2
			return 1
		fi
		program=$(git -C "$repo_root" config --get gpg.openpgp.program) ||
			program=$(git -C "$repo_root" config --get gpg.program) || program="gpg"
		[[ "$key" != *'!' ]] || exact=1
		selector=$(printf '%s' "${key%!}" | tr '[:lower:]' '[:upper:]')
		selector="${selector#0X}"
		key_ids=$("$program" --batch --with-colons --fingerprint --list-secret-keys "${key%!}" 2>/dev/null |
			awk -F: -v exact="$exact" -v selector="$selector" '
				BEGIN {key_id_field = 5; fingerprint_field = 10}
				/^(sec|ssb):/ {id = toupper($key_id_field); if (!exact) print id}
				/^fpr:/ && exact && (id == selector || toupper($fingerprint_field) == selector ||
					(length(selector) == 8 && substr(id, length(id) - 7) == selector)) {print id}
			') || {
			printf 'Release signing preflight: cannot resolve configured OpenPGP signing key\n' >&2
			return 1
		}
		# Ambiguous selectors must not approve a different key from the one Git uses.
		if [[ -z "$key_ids" ]]; then
			printf 'Release signing preflight: configured OpenPGP key has no resolvable secret signing key\n' >&2
			return 1
		fi
		if [[ -n "$exact" && "$key_ids" == *$'\n'* ]]; then
			printf 'Release signing preflight: ambiguous forced OpenPGP key; configure the full signing fingerprint\n' >&2
			return 1
		fi
		keys=$(gh api --paginate --slurp user/gpg_keys) || {
			printf 'Release signing preflight: cannot read authenticated GitHub GPG keys; check gh authentication and key-read permission\n' >&2
			return 1
		}
		while IFS= read -r candidate; do
			if ! jq -e --arg id "$candidate" 'any(.[][]; ((.key_id | ascii_upcase) == $id) or any(.subkeys[]?; (.key_id | ascii_upcase) == $id))' <<<"$keys" >/dev/null; then
				printf 'Release signing preflight: GPG key %s is not registered for the authenticated GitHub user; register the signing public key, then retry\n' "$candidate" >&2
				return 1
			fi
		done <<<"$key_ids"
		return 0
		;;
	*)
		printf 'Release signing preflight: unsupported signing format %s; GitHub-verifiable SSH or OpenPGP signing is required\n' "$format" >&2
		return 1
		;;
	esac
	return 1
}
