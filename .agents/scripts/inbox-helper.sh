#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# =============================================================================
# Inbox Helper Script (t2866)
# =============================================================================
# Establishes and manages the _inbox/ directory contract for aidevops-managed
# repos. The inbox is a transit zone — files land here until triage routes them
# to the appropriate knowledge plane or discards them.
#
# Usage:
#   inbox-helper.sh <command> [options]
#
# Commands:
#   provision <repo-path>      Create _inbox/ directory contract in a repo
#   provision-workspace        Provision cross-repo inbox at
#                              ~/.aidevops/.agent-workspace/inbox/
#   status [repo-path]         Report item counts per sub-folder and oldest age
#   validate [repo-path]       Check that _inbox/ structure is complete
#   help                       Show this help
#
# Sub-folders created under _inbox/:
#   _drop/          General-purpose drop (paste, quick captures)
#   email/          Email captures (forwarded messages, exported threads)
#   web/            Web page captures (saved HTML, PDFs, screenshots)
#   scan/           Scanned documents / OCR input
#   voice/          Voice memos / audio transcripts awaiting triage
#   import/         Bulk imports from external sources
#   _needs-review/  Items flagged as needing manual review before routing
#
# Sensitivity contract:
#   Nothing in _inbox/ flows to cloud LLMs until triage classifies it.
#   The LLM routing helper (P0.5b) checks plane membership: _inbox/
#   membership = local-only routing until a sensitivity label is assigned.
#
# Examples:
#   inbox-helper.sh provision ~/Git/myproject
#   inbox-helper.sh provision-workspace
#   inbox-helper.sh status ~/Git/myproject
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source shared constants for colour vars and utilities.
# Guard: older deployments may not have shared-constants.sh.
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
	[[ -z "${YELLOW+x}" ]] && YELLOW='\033[0;33m'
	[[ -z "${RED+x}" ]] && RED='\033[0;31m'
	[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
	[[ -z "${NC+x}" ]] && NC='\033[0m'
fi

# Template path for _inbox/README.md content.
INBOX_README_TEMPLATE="${SCRIPT_DIR}/../templates/inbox-readme.md"

# Sub-folders that make up the _inbox/ directory contract.
INBOX_SUBFOLDERS=("_drop" "email" "web" "scan" "voice" "import" "_needs-review")

# =============================================================================
# Internal helpers
# =============================================================================

_print_info() {
	local msg="$1"
	printf "${CYAN}[inbox]${NC} %s\n" "$msg"
	return 0
}

_print_success() {
	local msg="$1"
	printf "${GREEN}[inbox]${NC} %s\n" "$msg"
	return 0
}

_print_warning() {
	local msg="$1"
	printf "${YELLOW}[inbox] WARNING:${NC} %s\n" "$msg" >&2
	return 0
}

_print_error() {
	local msg="$1"
	printf "${RED}[inbox] ERROR:${NC} %s\n" "$msg" >&2
	return 0
}

# Resolve the inbox root for a given repo path.
# Usage: _inbox_root <repo-path>
_inbox_root() {
	local repo_path="$1"
	echo "${repo_path}/_inbox"
	return 0
}

# Write _inbox/README.md from template or embedded fallback.
# Usage: _write_inbox_readme <inbox-root>
_write_inbox_readme() {
	local inbox_root="$1"
	local readme_path="${inbox_root}/README.md"

	if [[ -f "$INBOX_README_TEMPLATE" ]]; then
		cp "$INBOX_README_TEMPLATE" "$readme_path"
	else
		# Embedded fallback if template is not deployed yet.
		cat >"$readme_path" <<'EOF'
<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# _inbox/ — Transit Zone

This directory is a **transit zone**: captures land here first, then triage
routes them to the appropriate knowledge plane or discards them.

## Sub-folders

| Folder | Purpose |
|--------|---------|
| `_drop/` | General-purpose drop — quick paste, text snippets |
| `email/` | Email captures — forwarded messages, exported threads |
| `web/` | Web captures — saved HTML, PDFs, screenshots |
| `scan/` | Scanned documents awaiting OCR / classification |
| `voice/` | Voice memos and audio transcripts |
| `import/` | Bulk imports from external sources |
| `_needs-review/` | Flagged items requiring manual review before routing |

## Sensitivity Contract

**Nothing in `_inbox/` may be sent to cloud LLMs until triage assigns a
sensitivity label.** The LLM routing helper treats `_inbox/` membership as
`local-only` by default. After classification (P2c), items move to their
target plane and inherit that plane's sensitivity baseline.

## Triage Log

`triage.log` is a JSONL audit file recording routing decisions. Each line is a
JSON object: `{"ts":"ISO8601","file":"path","action":"routed|discarded",
"target":"plane/subfolder","sensitivity":"unverified|public|private|privileged"}`.

Do not edit `triage.log` by hand — append via the triage CLI (P2c).

## What Does Not Belong Here

- Final classified content (move to the target plane)
- Secrets or credentials (use `aidevops secret set`)
- Build artefacts or generated files (use .gitignore)
EOF
	fi
	return 0
}

# Write _inbox/.gitignore — exclude binary sub-folder contents, keep
# README.md and triage.log.
# Usage: _write_inbox_gitignore <inbox-root>
_write_inbox_gitignore() {
	local inbox_root="$1"
	local gitignore_path="${inbox_root}/.gitignore"

	cat >"$gitignore_path" <<'EOF'
# _inbox/.gitignore (t2866)
# Transit-zone captures: exclude binary and bulk content from git.
# README.md and triage.log are committed for visibility and audit trail.

# Exclude everything by default…
*

# …then re-include files that belong in version control.
!README.md
!.gitignore
!triage.log

# Sub-folders are excluded entirely (binary captures, PDFs, audio, images)
# When triage routes an item to a plane, it is copied/moved; the plane
# applies its own .gitignore policy.
EOF
	return 0
}

# Write an empty triage.log (JSONL append target for P2c triage CLI).
# Usage: _write_triage_log <inbox-root>
_write_triage_log() {
	local inbox_root="$1"
	local log_path="${inbox_root}/triage.log"
	[[ -f "$log_path" ]] && return 0
	: >"$log_path"
	return 0
}

# Core provisioning logic — shared between provision and provision-workspace.
# Usage: _provision_inbox_at <inbox-root> <label>
_provision_inbox_at() {
	local inbox_root="$1"
	local label="$2"
	local created=0
	local already_ok=0

	if [[ ! -d "$inbox_root" ]]; then
		mkdir -p "$inbox_root"
		_print_info "Created $label/_inbox/"
		created=1
	fi

	# Create sub-folders (idempotent).
	local folder
	for folder in "${INBOX_SUBFOLDERS[@]}"; do
		local sub="${inbox_root}/${folder}"
		if [[ ! -d "$sub" ]]; then
			mkdir -p "$sub"
			_print_info "  + $folder/"
			created=1
		fi
	done

	# Write supporting files (idempotent — only create, never overwrite).
	if [[ ! -f "${inbox_root}/README.md" ]]; then
		_write_inbox_readme "$inbox_root"
		_print_info "  + README.md"
		created=1
	fi

	if [[ ! -f "${inbox_root}/.gitignore" ]]; then
		_write_inbox_gitignore "$inbox_root"
		_print_info "  + .gitignore"
		created=1
	fi

	_write_triage_log "$inbox_root"

	if [[ "$created" -eq 0 ]]; then
		already_ok=1
	fi

	if [[ "$already_ok" -eq 1 ]]; then
		_print_success "$label/_inbox/ already provisioned (idempotent)"
	else
		_print_success "$label/_inbox/ provisioned successfully"
	fi
	return 0
}

# =============================================================================
# Commands
# =============================================================================

# cmd_provision: provision _inbox/ in a given repo path.
# Usage: cmd_provision <repo-path>
cmd_provision() {
	local repo_path="${1:-}"
	if [[ -z "$repo_path" ]]; then
		_print_error "Usage: inbox-helper.sh provision <repo-path>"
		return 1
	fi
	if [[ ! -d "$repo_path" ]]; then
		_print_error "Directory not found: $repo_path"
		return 1
	fi
	local inbox_root
	inbox_root="$(_inbox_root "$repo_path")"
	_provision_inbox_at "$inbox_root" "$(basename "$repo_path")"
	return 0
}

# cmd_provision_workspace: provision cross-repo inbox at
# ~/.aidevops/.agent-workspace/inbox/
# Usage: cmd_provision_workspace
cmd_provision_workspace() {
	local workspace_inbox="${HOME}/.aidevops/.agent-workspace/inbox"
	_print_info "Provisioning workspace inbox at $workspace_inbox"

	if [[ ! -d "${HOME}/.aidevops/.agent-workspace" ]]; then
		mkdir -p "${HOME}/.aidevops/.agent-workspace"
	fi

	_provision_inbox_at "$workspace_inbox" "${HOME}/.aidevops/.agent-workspace"
	return 0
}

# cmd_status: report item counts per sub-folder and oldest item age.
# Usage: cmd_status [repo-path]
cmd_status() {
	local repo_path="${1:-$(pwd)}"
	local inbox_root
	inbox_root="$(_inbox_root "$repo_path")"

	if [[ ! -d "$inbox_root" ]]; then
		_print_warning "_inbox/ not found at $inbox_root — run: inbox-helper.sh provision $repo_path"
		return 1
	fi

	printf "\n${CYAN}_inbox/ status for ${NC}%s\n\n" "$(basename "$repo_path")"
	printf "  %-20s %s\n" "Folder" "Items"
	printf "  %s\n" "-----------------------------"

	local total=0
	local oldest_age=-1
	local oldest_file=""
	local now
	now=$(date +%s)

	local folder
	for folder in "${INBOX_SUBFOLDERS[@]}"; do
		local sub="${inbox_root}/${folder}"
		local count=0
		if [[ -d "$sub" ]]; then
			# Count non-hidden files only; stat for oldest mtime.
			# Use find to avoid globbing issues with empty dirs.
			while IFS= read -r -d '' fpath; do
				count=$((count + 1))
				total=$((total + 1))
				local fmtime
				# macOS stat: -f %m; GNU stat: -c %Y
				if fmtime=$(stat -f '%m' "$fpath" 2>/dev/null); then
					: # macOS
				elif fmtime=$(stat -c '%Y' "$fpath" 2>/dev/null); then
					: # GNU/Linux
				else
					fmtime=0
				fi
				if [[ "$oldest_age" -eq -1 ]] || [[ "$fmtime" -lt "$oldest_age" ]]; then
					oldest_age="$fmtime"
					oldest_file="$fpath"
				fi
			done < <(find "$sub" -maxdepth 1 -not -name '.*' -type f -print0 2>/dev/null)
		fi
		printf "  %-20s %d\n" "$folder/" "$count"
	done

	printf "\n  Total items:  %d\n" "$total"

	if [[ "$total" -gt 0 ]] && [[ "$oldest_age" -gt 0 ]]; then
		local age_secs=$(( now - oldest_age ))
		local age_days=$(( age_secs / 86400 ))
		local age_hours=$(( (age_secs % 86400) / 3600 ))
		printf "  Oldest item:  %dd %dh ago (%s)\n" "$age_days" "$age_hours" \
			"$(basename "$oldest_file")"
	fi

	printf "\n"
	return 0
}

# cmd_validate: verify that _inbox/ has all required structure.
# Usage: cmd_validate [repo-path]
cmd_validate() {
	local repo_path="${1:-$(pwd)}"
	local inbox_root
	inbox_root="$(_inbox_root "$repo_path")"
	local fail=0

	if [[ ! -d "$inbox_root" ]]; then
		_print_error "Missing: $inbox_root"
		return 1
	fi

	local folder
	for folder in "${INBOX_SUBFOLDERS[@]}"; do
		if [[ ! -d "${inbox_root}/${folder}" ]]; then
			_print_error "Missing sub-folder: $folder/"
			fail=1
		fi
	done

	for reqfile in "README.md" ".gitignore" "triage.log"; do
		if [[ ! -f "${inbox_root}/${reqfile}" ]]; then
			_print_error "Missing required file: $reqfile"
			fail=1
		fi
	done

	if [[ "$fail" -eq 0 ]]; then
		_print_success "_inbox/ structure valid at $inbox_root"
	fi
	return "$fail"
}

cmd_help() {
	cat <<EOF
Usage: inbox-helper.sh <command> [options]

Commands:
  provision <repo-path>      Create _inbox/ directory contract in a repo
  provision-workspace        Provision cross-repo inbox at
                             ~/.aidevops/.agent-workspace/inbox/
  status [repo-path]         Report item counts per sub-folder and oldest age
  validate [repo-path]       Check that _inbox/ structure is complete
  help                       Show this help

Sub-folders:
  _drop/          General-purpose quick captures
  email/          Email message captures
  web/            Web page captures (HTML, PDFs, screenshots)
  scan/           Scanned documents / OCR input
  voice/          Voice memos / audio transcripts
  import/         Bulk imports from external sources
  _needs-review/  Flagged items requiring manual review

Examples:
  inbox-helper.sh provision ~/Git/myproject
  inbox-helper.sh provision-workspace
  inbox-helper.sh status ~/Git/myproject
  inbox-helper.sh validate ~/Git/myproject
EOF
	return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	provision)
		cmd_provision "$@"
		;;
	provision-workspace | workspace)
		cmd_provision_workspace "$@"
		;;
	status | st)
		cmd_status "$@"
		;;
	validate | check)
		cmd_validate "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		_print_error "Unknown command: $command"
		echo ""
		cmd_help
		return 1
		;;
	esac
}

main "$@"
