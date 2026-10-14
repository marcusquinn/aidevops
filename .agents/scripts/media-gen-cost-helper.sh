#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091

# Media Generation Cost Helper - compare per-output API pricing with rented GPU
# time for a batch of finished assets. Rates are always caller-supplied so the
# helper never goes stale; see content/media-generation-providers.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
if [[ ! -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	printf 'ERROR: shared-constants.sh not found beside media-gen-cost-helper.sh\n' >&2
	exit 1
fi
source "${SCRIPT_DIR}/shared-constants.sh"

readonly MGC_NUMBER_RE='^[0-9]+([.][0-9]+)?$'

_mgc_usage() {
	cat <<'EOF'
media-gen-cost-helper.sh - compare API vs GPU-rental cost for a media batch

Usage:
  media-gen-cost-helper.sh compare --clips N [options] --api SPEC... [--gpu SPEC...]
  media-gen-cost-helper.sh help

Batch:
  --clips N              Finished assets you need (required)
  --secs-per-clip S      Output seconds per asset for per-second APIs (default 1)
  --takes T              Average generations per kept asset (default 1)

Routes (repeatable; at least one --api or --gpu):
  --api "LABEL=RATE[:sec|asset][:FEE_PCT]"
                         Per-output API. sec = RATE per output second (default),
                         asset = RATE per image/clip. FEE_PCT adds a platform
                         fee, e.g. 2.5 for VideoRouter.
  --gpu "LABEL=HOURLY_RATE"
                         Rented GPU (Runpod Pod/Serverless, Vast.ai, Lambda)
  --gpu-secs-per-clip G  Measured GPU-seconds per generation (required with --gpu)
  --setup-hours H        Billable setup/benchmark hours per GPU route (default 0)
  --idle-hours I         Billable idle/warm hours per GPU route (default 0)

Examples:
  media-gen-cost-helper.sh compare --clips 200 --secs-per-clip 6 --takes 3 \
    --api "h3-max-videorouter=0.016:sec:2.5" --api "veo3.1-fast-runway=0.10" \
    --gpu "wan-on-l40s=0.86" --gpu-secs-per-clip 240 --setup-hours 3

Rates are inputs, not built-in data: copy live list prices from the provider
pricing pages and a measured GPU-seconds figure from one benchmark run.
EOF
	return 0
}

_mgc_require_number() {
	local name="$1"
	local value="$2"
	if [[ ! "$value" =~ $MGC_NUMBER_RE ]]; then
		print_error "${name} must be a non-negative number, got: ${value}"
		return 1
	fi
	return 0
}

# Prints "LABEL<TAB>PER_KEEPER_COST" for an API spec.
_mgc_api_per_keeper() {
	local spec="$1"
	local secs="$2"
	local takes="$3"
	local label="${spec%%=*}"
	local rest="${spec#*=}"
	local rate="" unit="sec" fee="0"
	if [[ -z "$label" || "$label" == "$spec" ]]; then
		print_error "Invalid --api spec (expected LABEL=RATE[:unit][:fee]): ${spec}"
		return 1
	fi
	IFS=':' read -r rate unit fee <<<"$rest"
	unit="${unit:-sec}"
	fee="${fee:-0}"
	_mgc_require_number "--api rate for ${label}" "$rate" || return 1
	_mgc_require_number "--api fee for ${label}" "$fee" || return 1
	if [[ "$unit" != "sec" && "$unit" != "asset" ]]; then
		print_error "--api unit for ${label} must be sec or asset, got: ${unit}"
		return 1
	fi
	awk -v l="$label" -v r="$rate" -v u="$unit" -v f="$fee" -v s="$secs" -v t="$takes" 'BEGIN {
		per_gen = (u == "sec") ? r * s : r
		printf "%s\t%.6f\n", l, per_gen * (1 + f / 100) * t
	}'
	return 0
}

# Prints "LABEL<TAB>VARIABLE_PER_KEEPER<TAB>FIXED_COST" for a GPU spec.
_mgc_gpu_costs() {
	local spec="$1"
	local gsecs="$2"
	local takes="$3"
	local fixed_hours="$4"
	local label="${spec%%=*}"
	local rate="${spec#*=}"
	if [[ -z "$label" || "$label" == "$spec" ]]; then
		print_error "Invalid --gpu spec (expected LABEL=HOURLY_RATE): ${spec}"
		return 1
	fi
	_mgc_require_number "--gpu rate for ${label}" "$rate" || return 1
	awk -v l="$label" -v r="$rate" -v g="$gsecs" -v t="$takes" -v h="$fixed_hours" 'BEGIN {
		printf "%s\t%.6f\t%.6f\n", l, r / 3600 * g * t, r * h
	}'
	return 0
}

_mgc_compare() {
	local clips="" secs="1" takes="1" gsecs="" setup="0" idle="0"
	local -a apis=() gpus=()
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		local val="${2:-}"
		case "$opt" in
		--clips | --secs-per-clip | --takes | --api | --gpu | --gpu-secs-per-clip | --setup-hours | --idle-hours)
			if [[ $# -lt 2 ]]; then
				print_error "${opt} requires a value"
				return 1
			fi
			;;
		esac
		case "$opt" in
		--clips) clips="$val" ;;
		--secs-per-clip) secs="$val" ;;
		--takes) takes="$val" ;;
		--api) apis+=("$val") ;;
		--gpu) gpus+=("$val") ;;
		--gpu-secs-per-clip) gsecs="$val" ;;
		--setup-hours) setup="$val" ;;
		--idle-hours) idle="$val" ;;
		-h | --help)
			_mgc_usage
			return 0
			;;
		*)
			print_error "Unknown option: ${opt}"
			return 1
			;;
		esac
		shift 2
	done

	if [[ -z "$clips" ]]; then
		print_error "--clips is required"
		return 1
	fi
	_mgc_require_number "--clips" "$clips" || return 1
	_mgc_require_number "--secs-per-clip" "$secs" || return 1
	_mgc_require_number "--takes" "$takes" || return 1
	_mgc_require_number "--setup-hours" "$setup" || return 1
	_mgc_require_number "--idle-hours" "$idle" || return 1
	if [[ ${#apis[@]} -eq 0 && ${#gpus[@]} -eq 0 ]]; then
		print_error "Provide at least one --api or --gpu route"
		return 1
	fi
	if [[ ${#gpus[@]} -gt 0 ]]; then
		if [[ -z "$gsecs" ]]; then
			print_error "--gpu-secs-per-clip is required with --gpu (benchmark one generation first)"
			return 1
		fi
		_mgc_require_number "--gpu-secs-per-clip" "$gsecs" || return 1
	fi

	local fixed_hours=""
	fixed_hours="$(awk -v a="$setup" -v b="$idle" 'BEGIN { printf "%.6f", a + b }')"

	local rows="" spec="" line=""
	if [[ ${#apis[@]} -gt 0 ]]; then
		for spec in "${apis[@]}"; do
			line="$(_mgc_api_per_keeper "$spec" "$secs" "$takes")" || return 1
			rows+="api"$'\t'"${line}"$'\t'"0"$'\n'
		done
	fi
	if [[ ${#gpus[@]} -gt 0 ]]; then
		for spec in "${gpus[@]}"; do
			line="$(_mgc_gpu_costs "$spec" "$gsecs" "$takes" "$fixed_hours")" || return 1
			rows+="gpu"$'\t'"${line}"$'\n'
		done
	fi

	_mgc_render_report "$rows" "$clips" "$secs" "$takes"
	return $?
}

# Renders the comparison table, cheapest route and GPU break-even volumes from
# rows of "KIND<TAB>LABEL<TAB>VARIABLE_PER_KEEPER<TAB>FIXED_COST".
_mgc_render_report() {
	local rows="$1"
	local clips="$2"
	local secs="$3"
	local takes="$4"
	printf '%s' "$rows" | awk -v n="$clips" -v s="$secs" -v t="$takes" '
	{
		split($0, f, "\t")
		kind[NR] = f[1]; label[NR] = f[2]; var[NR] = f[3] + 0; fixed[NR] = f[4] + 0
		total[NR] = fixed[NR] + var[NR] * n
		if (kind[NR] == "api" && (best_api == "" || var[NR] < var[best_api])) best_api = NR
	}
	END {
		printf "Batch: %s finished assets, %s output s each, %s takes per keeper\n\n", n, s, t
		printf "%-28s %-5s %14s %12s %14s\n", "ROUTE", "TYPE", "PER KEEPER $", "FIXED $", "TOTAL $"
		best = 1
		for (i = 1; i <= NR; i++) {
			printf "%-28s %-5s %14.4f %12.2f %14.2f\n", label[i], kind[i], var[i] + (n > 0 ? fixed[i] / n : 0), fixed[i], total[i]
			if (total[i] < total[best]) best = i
		}
		printf "\nCheapest at this volume: %s ($%.2f)\n", label[best], total[best]
		if (best_api == "") exit 0
		for (i = 1; i <= NR; i++) {
			if (kind[i] != "gpu") continue
			diff = var[best_api] - var[i]
			if (diff <= 0) {
				printf "Break-even %s vs %s: never (GPU marginal cost is not lower)\n", label[i], label[best_api]
			} else {
				be = fixed[i] / diff
				be = (be == int(be)) ? be : int(be) + 1
				printf "Break-even %s vs %s: %d finished assets\n", label[i], label[best_api], be
			}
		}
	}'
	return 0
}

main() {
	local command="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$command" in
	compare)
		_mgc_compare "$@"
		return $?
		;;
	help | -h | --help)
		_mgc_usage
		return 0
		;;
	*)
		print_error "Unknown command: ${command}"
		_mgc_usage
		return 1
		;;
	esac
}

main "$@"
