#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
#
# Runtime evidence for Linux procfs observer changes (worktree_process_proc.py,
# worktree_process_attestation.py, lease census) from any host with Docker.
# Runs process fixtures in a stock Linux container and prints a diffable report.
#
# Usage:
#   linux-procfs-runtime-check.sh [--head DIR] [--base DIR] [--image IMG] [--uid N] [--forged]
# DIR is a scripts directory holding worktree_process_proc.py. Default head: this
# script's directory. With --base, prints base report, head report and a diff.
# Exit: 0 ok, 1 usage/runtime unavailable, 2 a container run failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${PROCFS_CHECK_IMAGE:-debian:stable-slim}"
BOOTSTRAP='command -v python3 >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq python3 >/dev/null 2>&1; }; exec python3 /fixture.py /scripts "$@"'

usage() {
	printf 'Usage: %s [--head DIR] [--base DIR] [--image IMG] [--uid N] [--forged]\n' "$(basename "$0")" >&2
	return 0
}

die() {
	local message="$1"
	printf 'linux-procfs-runtime-check: %s\n' "$message" >&2
	return 0
}

require_runtime() {
	command -v docker >/dev/null 2>&1 || {
		die "docker not found; a Linux container runtime is required"
		return 1
	}
	docker info >/dev/null 2>&1 || {
		die "docker daemon unavailable; start it to run Linux procfs fixtures"
		return 1
	}
	return 0
}

# run_report LABEL DIR UID FORGED -> prints the fixture report for one scripts dir.
run_report() {
	local label="$1" dir="$2" uid="$3" forged="$4"
	local extra=()
	[[ "$forged" == "1" ]] && extra+=(--forged)
	printf '# %s: %s\n' "$label" "$dir"
	local cid_dir cid_file cid
	cid_dir="$(mktemp -d)" || return 2
	cid_file="${cid_dir}/cid"
	docker run --rm --init --cidfile "$cid_file" --pids-limit 512 \
		--mount "type=bind,source=${dir},target=/scripts,readonly" \
		--mount "type=bind,source=${SCRIPT_DIR}/linux-procfs-runtime-fixture.py,target=/fixture.py,readonly" \
		"$IMAGE" sh -c "$BOOTSTRAP" sh "$uid" ${extra[@]+"${extra[@]}"} || {
		if [[ -s "$cid_file" ]]; then
			cid="$(<"$cid_file")"
			docker rm -f "$cid" >/dev/null 2>&1 || true
		fi
		rm -rf "$cid_dir"
		die "container run failed for ${label}"
		return 2
	}
	rm -rf "$cid_dir"
	return 0
}

main() {
	local head_dir="$SCRIPT_DIR" base_dir="" uid=1000 forged=0
	local opt value
	while [[ $# -gt 0 ]]; do
		opt="${1:-}"
		value="${2:-}"
		case "$opt" in
		--head | --base | --image | --uid)
			[[ $# -ge 2 ]] || {
				usage
				return 1
			}
			case "$opt" in
			--head) head_dir="$value" ;;
			--base) base_dir="$value" ;;
			--image) IMAGE="$value" ;;
			--uid) uid="$value" ;;
			esac
			shift 2
			;;
		--forged)
			forged=1
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			usage
			return 1
			;;
		esac
	done
	[[ "$uid" =~ ^[1-9][0-9]*$ ]] || {
		die "--uid must be a positive integer"
		return 1
	}
	local dir
	for dir in "$head_dir" ${base_dir:+"$base_dir"}; do
		[[ -f "$dir/worktree_process_proc.py" ]] || {
			die "missing worktree_process_proc.py in ${dir}"
			return 1
		}
	done
	require_runtime || return 1
	head_dir="$(cd "$head_dir" && pwd)"
	local head_out base_out=""
	if [[ -n "$base_dir" ]]; then
		base_dir="$(cd "$base_dir" && pwd)"
		base_out="$(run_report base "$base_dir" "$uid" "$forged")" || return 2
	fi
	head_out="$(run_report head "$head_dir" "$uid" "$forged")" || return 2
	if [[ -n "$base_out" ]]; then
		printf '%s\n\n' "$base_out"
	fi
	printf '%s\n' "$head_out"
	if [[ -n "$base_out" ]]; then
		printf '\n# diff base -> head\n'
		diff <(printf '%s\n' "$base_out" | tail -n +2) <(printf '%s\n' "$head_out" | tail -n +2) || true
	fi
	return 0
}

main "$@"
