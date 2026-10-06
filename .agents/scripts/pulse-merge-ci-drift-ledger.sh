#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Runner-local, signature-keyed CI-drift attempts (GH#33794).
# Deleting the ledger restores one drift attempt per PR.

_ci_drift_ledger_should_skip() {
	local repo_slug="$1" pr_number="$2" head="$3" signature="$4"
	local ledger="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-$HOME/.aidevops/.agent-workspace/tmp/headless-runtime}/ci-drift-ledger.tsv"
	local ttl="${PULSE_CI_DRIFT_LEDGER_TTL_S:-604800}" now=""
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=604800
	[[ -e "$ledger" ]] || return 1
	now=$(date +%s)
	# Validate the entire file before using it; corrupt/unreadable state is absent.
	if ! awk -F '\t' 'NF != 4 || $2 !~ /^[[:xdigit:]]+$/ || $3 == "" || $4 !~ /^[0-9]+$/ { exit 1 }' "$ledger" 2>/dev/null; then
		echo "[pulse-merge] CI-drift ledger unreadable or corrupt; allowing one rebase" >>"$LOGFILE"
		return 1
	fi
	if awk -F '\t' -v key="${repo_slug}#${pr_number}" -v sig="$signature" -v head="$head" -v now="$now" -v ttl="$ttl" '
		BEGIN { key_col=1; sig_col=2; head_col=3; time_col=4 }
		$key_col == key && $sig_col == sig && $head_col != head && $time_col <= now && now - $time_col <= ttl { found=1 }
		END { exit !found }' "$ledger"; then
		return 0
	fi
	return 1
}

_ci_drift_ledger_record() {
	local repo_slug="$1" pr_number="$2" prior_head="$3" signature="$4"
	local state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-$HOME/.aidevops/.agent-workspace/tmp/headless-runtime}"
	local ttl="${PULSE_CI_DRIFT_LEDGER_TTL_S:-604800}" now="" temp=""
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=604800
	[[ -n "$prior_head" && -n "$signature" ]] || return 1
	mkdir -p "$state_dir" || return 1
	now=$(date +%s)
	temp=$(mktemp "${state_dir}/ci-drift-ledger.XXXXXX") || return 1
	if [[ -r "${state_dir}/ci-drift-ledger.tsv" ]]; then
		awk -F '\t' -v key="${repo_slug}#${pr_number}" -v now="$now" -v ttl="$ttl" '
			BEGIN { key_col=1; sig_col=2; head_col=3; time_col=4 }
			NF == 4 && $key_col != key && $sig_col ~ /^[[:xdigit:]]+$/ && $head_col != "" && $time_col ~ /^[0-9]+$/ && $time_col <= now && now - $time_col <= ttl { print }' \
			"${state_dir}/ci-drift-ledger.tsv" >"$temp" || { rm -f "$temp"; return 1; }
	fi
	printf '%s\t%s\t%s\t%s\n' "${repo_slug}#${pr_number}" "$signature" "$prior_head" "$now" >>"$temp" &&
		mv "$temp" "${state_dir}/ci-drift-ledger.tsv" || { rm -f "$temp"; return 1; }
	return 0
}
