#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# open-design-helper.sh — Optional Open Design peripheral management

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

if [[ -z "${GREEN+x}" ]]; then GREEN=""; fi
if [[ -z "${YELLOW+x}" ]]; then YELLOW=""; fi
if [[ -z "${RED+x}" ]]; then RED=""; fi
if [[ -z "${BLUE+x}" ]]; then BLUE=""; fi
if [[ -z "${NC+x}" ]]; then NC=""; fi

OPEN_DESIGN_REPO="https://github.com/nexu-io/open-design.git"
DEFAULT_OPEN_DESIGN_DIR="${HOME}/.aidevops/peripherals/open-design"

info() {
	local message="$1"
	printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$message"
	return 0
}

ok() {
	local message="$1"
	printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$message"
	return 0
}

warn() {
	local message="$1"
	printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$message"
	return 0
}

fail() {
	local message="$1"
	printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$message" >&2
	return 1
}

usage() {
	cat <<'EOF'
Usage: open-design-helper.sh <command> [options]

Commands:
  status                         Check optional Open Design peripheral status
  install [--execute] [--dir D]   Print install plan, or execute with --execute
  start [--dir D] [--https-local NAME]
                                 Start Open Design directly or via localdev HTTPS
  skills                         Print aidevops ingestion recommendation summary
  route <brief>                  Recommend route for an artifact request
  help                           Show this help

Environment:
  OPEN_DESIGN_DIR                Override install directory

Notes:
  Open Design is optional. aidevops remains self-contained and keeps .agents/
  plus Google DESIGN.md as the canonical agent/design surfaces.
EOF
	return 0
}

command_exists() {
	local command_name="$1"
	command -v "$command_name" >/dev/null 2>&1
	return $?
}

detect_open_design_cli() {
	if ! command_exists od; then
		return 1
	fi

	local od_path
	od_path="$(command -v od)"
	case "$od_path" in
	/bin/od|/usr/bin/od)
		return 1
		;;
	*)
		printf '%s\n' "$od_path"
		return 0
		;;
	esac
}

resolve_dir() {
	local requested_dir="$1"
	if [[ -n "$requested_dir" ]]; then
		printf '%s\n' "$requested_dir"
	else
		printf '%s\n' "${OPEN_DESIGN_DIR:-$DEFAULT_OPEN_DESIGN_DIR}"
	fi
	return 0
}

cmd_status() {
	local install_dir="${1:-}"
	local resolved_dir
	resolved_dir="$(resolve_dir "$install_dir")"

	info "Open Design peripheral status"
	printf 'Install dir: %s\n' "$resolved_dir"

	if [[ -d "$resolved_dir/.git" ]]; then
		ok "Repository present"
	else
		warn "Repository not installed"
	fi

	local open_design_cli
	if open_design_cli="$(detect_open_design_cli)"; then
		ok "Open Design od command found: $open_design_cli"
	else
		warn "Open Design od command not found on PATH (ignoring system /usr/bin/od)"
	fi

	if command_exists node; then
		printf 'node: %s\n' "$(node --version 2>/dev/null || true)"
	else
		warn "node not found; Open Design expects Node ~24"
	fi

	if command_exists corepack; then
		ok "corepack found"
	else
		warn "corepack not found"
	fi

	if command_exists pnpm; then
		printf 'pnpm: %s\n' "$(pnpm --version 2>/dev/null || true)"
	else
		warn "pnpm not found directly; corepack can provide it"
	fi

	if command_exists localdev-helper.sh; then
		ok "localdev-helper.sh found for HTTPS .local routing"
	else
		warn "localdev-helper.sh not found on PATH; use ~/.aidevops/agents/scripts/localdev-helper.sh if deployed"
	fi

	return 0
}

cmd_install() {
	local execute="false"
	local install_dir=""
	local ref=""

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--execute)
			execute="true"
			shift
			;;
		--dir)
			install_dir="$2"
			shift 2
			;;
		--ref)
			ref="$2"
			shift 2
			;;
		*)
			fail "Unknown install option: $arg"
			return 1
			;;
		esac
	done

	local resolved_dir
	resolved_dir="$(resolve_dir "$install_dir")"

	if [[ "$execute" != "true" ]]; then
		cat <<EOF
Optional Open Design install plan (not executed):

  mkdir -p "$(dirname "$resolved_dir")"
  git clone "$OPEN_DESIGN_REPO" "$resolved_dir"
  cd "$resolved_dir"
  corepack enable
  corepack pnpm install

Run with --execute to perform these steps. Use --ref <tag-or-commit> to pin.
EOF
		return 0
	fi

	command_exists git || return 1
	command_exists corepack || return 1

	mkdir -p "$(dirname "$resolved_dir")"
	if [[ -d "$resolved_dir/.git" ]]; then
		info "Updating existing Open Design checkout"
		git -C "$resolved_dir" fetch --tags origin
	else
		git clone "$OPEN_DESIGN_REPO" "$resolved_dir"
	fi

	if [[ -n "$ref" ]]; then
		git -C "$resolved_dir" checkout "$ref"
	fi

	(cd "$resolved_dir" && corepack enable && corepack pnpm install)
	ok "Open Design installed at $resolved_dir"
	return 0
}

cmd_start() {
	local install_dir=""
	local https_name=""

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--dir)
			install_dir="$2"
			shift 2
			;;
		--https-local)
			https_name="$2"
			shift 2
			;;
		*)
			fail "Unknown start option: $arg"
			return 1
			;;
		esac
	done

	local resolved_dir
	resolved_dir="$(resolve_dir "$install_dir")"
	[[ -d "$resolved_dir" ]] || fail "Open Design directory not found: $resolved_dir" || return 1

	if [[ -n "$https_name" ]]; then
		if command_exists localdev-helper.sh; then
			(cd "$resolved_dir" && localdev-helper.sh run --name "$https_name" corepack pnpm tools-dev run web)
		else
			(cd "$resolved_dir" && "${HOME}/.aidevops/agents/scripts/localdev-helper.sh" run --name "$https_name" corepack pnpm tools-dev run web)
		fi
		return $?
	fi

	(cd "$resolved_dir" && corepack pnpm tools-dev run web)
	return $?
}

cmd_skills() {
	cat <<'EOF'
Open Design ingestion summary:

Adopt first:
  web-prototype, wireframe-sketch, saas-landing, pricing-page, dashboard,
  mobile-app, mobile-onboarding, social-carousel, magazine-poster,
  guizang-ppt, html-ppt-pitch-deck, html-ppt-product-launch,
  html-ppt-tech-sharing, pptx-html-fidelity-audit

Adapt with aidevops verification/tooling:
  email-marketing, motion-frames, hyperframes, video-shortform, image-poster,
  weekly-update, html-ppt, html-ppt-presenter-mode-reveal

Combine into existing agents:
  critique, tweaks, design-brief, blog-post, eng-runbook, invoice,
  meeting-notes, pm-spec, team-okrs

Full matrix: .agents/tools/design/open-design-ingestion.md
EOF
	return 0
}

cmd_route() {
	local brief="$*"
	[[ -n "$brief" ]] || fail "route requires an artifact brief" || return 1

	case "$brief" in
	*deck*|*slides*|*PPT*|*presentation*|*keynote*)
		printf 'Route: Open Design deck skill candidate, then aidevops export/fidelity verification.\n'
		;;
	*email*|*newsletter*)
		printf 'Route: Open Design email-marketing candidate, then email-design-test-helper.sh verification.\n'
		;;
	*mobile*|*app*|*onboarding*)
		printf 'Route: Open Design mobile prototype candidate, then aidevops UI verification.\n'
		;;
	*carousel*|*poster*|*social*)
		printf 'Route: Open Design marketing artifact candidate, then brand/export QA.\n'
		;;
	*production*|*implement*|*code*)
		printf 'Route: aidevops native implementation; use Open Design only for preview exploration.\n'
		;;
	*)
		printf 'Route: start with aidevops DESIGN.md/design-agent workflow; use Open Design if live artifact preview/export is valuable.\n'
		;;
	esac
	return 0
}

main() {
	local command_name="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi

	case "$command_name" in
	help|-h|--help)
		usage
		;;
	status)
		cmd_status "$@"
		;;
	install)
		cmd_install "$@"
		;;
	start)
		cmd_start "$@"
		;;
	skills)
		cmd_skills
		;;
	route)
		cmd_route "$@"
		;;
	*)
		fail "Unknown command: $command_name"
		usage
		return 1
		;;
	esac
	return $?
}

main "$@"
