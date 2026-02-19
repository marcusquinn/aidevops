#!/usr/bin/env bash
# shellcheck disable=SC2034

# Multi-Org Helper - Organisation management and tenant context operations
# Manages multi-org data isolation for aidevops framework
#
# Schema: .agents/services/database/schemas/multi-org.ts
# Context: .agents/services/database/schemas/tenant-context.ts
# Design: .agents/services/database/multi-org-isolation.md
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly MULTI_ORG_CONFIG="$CONFIG_DIR/multi-org-config.json"
readonly MULTI_ORG_CONFIG_TEMPLATE="${SCRIPT_DIR}/../../configs/multi-org-config.json.txt"
readonly ORGS_DIR="$CONFIG_DIR/organisations"
readonly ACTIVE_ORG_FILE="$CONFIG_DIR/active-org"
readonly PROJECT_ORG_FILE=".aidevops-org"

# Slug validation: lowercase alphanumeric, hyphens only, 3-63 chars
readonly SLUG_REGEX='^[a-z][a-z0-9-]{1,61}[a-z0-9]$'

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

validate_slug() {
	local slug="$1"
	if [[ ! "$slug" =~ $SLUG_REGEX ]]; then
		print_error "Invalid org slug: '$slug'. Use lowercase alphanumeric and hyphens, 3-63 chars."
		return 1
	fi
	return 0
}

validate_role() {
	local role="$1"
	case "$role" in
	owner | admin | member | viewer) return 0 ;;
	*)
		print_error "Invalid role: '$role'. Must be: owner, admin, member, viewer."
		return 1
		;;
	esac
}

validate_plan() {
	local plan="$1"
	case "$plan" in
	free | pro | enterprise) return 0 ;;
	*)
		print_error "Invalid plan: '$plan'. Must be: free, pro, enterprise."
		return 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# Org directory helpers
# ---------------------------------------------------------------------------

ensure_orgs_dir() {
	if [[ ! -d "$ORGS_DIR" ]]; then
		mkdir -p "$ORGS_DIR"
		chmod 700 "$ORGS_DIR"
	fi
	return 0
}

get_org_dir() {
	local slug="$1"
	echo "$ORGS_DIR/$slug"
	return 0
}

get_org_metadata_file() {
	local slug="$1"
	echo "$ORGS_DIR/$slug/org.json"
	return 0
}

org_exists() {
	local slug="$1"
	local org_dir
	org_dir="$(get_org_dir "$slug")"
	[[ -d "$org_dir" && -f "$org_dir/org.json" ]]
}

# ---------------------------------------------------------------------------
# Active org resolution
# ---------------------------------------------------------------------------

get_active_org() {
	# Priority: 1) Project override, 2) Global active, 3) empty (no default)
	if [[ -f "$PROJECT_ORG_FILE" ]]; then
		local project_org
		project_org=$(tr -d '[:space:]' <"$PROJECT_ORG_FILE" 2>/dev/null)
		if [[ -n "$project_org" ]]; then
			echo "$project_org"
			return 0
		fi
	fi

	if [[ -f "$ACTIVE_ORG_FILE" ]]; then
		local active
		active=$(tr -d '[:space:]' <"$ACTIVE_ORG_FILE" 2>/dev/null)
		if [[ -n "$active" ]]; then
			echo "$active"
			return 0
		fi
	fi

	# No default — multi-org requires explicit selection
	echo ""
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_init() {
	ensure_orgs_dir

	# Copy config template if no config exists
	if [[ ! -f "$MULTI_ORG_CONFIG" && -f "$MULTI_ORG_CONFIG_TEMPLATE" ]]; then
		cp "$MULTI_ORG_CONFIG_TEMPLATE" "$MULTI_ORG_CONFIG"
		chmod 600 "$MULTI_ORG_CONFIG"
		print_success "Created multi-org config: $MULTI_ORG_CONFIG"
	fi

	print_success "Multi-org storage initialised: $ORGS_DIR"
	return 0
}

cmd_create() {
	local slug="$1"
	local name="${2:-$slug}"
	local plan="${3:-free}"

	validate_slug "$slug" || return 1
	validate_plan "$plan" || return 1
	ensure_orgs_dir

	local org_dir
	org_dir="$(get_org_dir "$slug")"

	if [[ -d "$org_dir" ]]; then
		print_error "Organisation '$slug' already exists."
		return 1
	fi

	mkdir -p "$org_dir"
	chmod 700 "$org_dir"

	# Write org metadata
	local metadata_file
	metadata_file="$(get_org_metadata_file "$slug")"
	local created_at
	created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	cat >"$metadata_file" <<METADATA_EOF
{
  "slug": "$slug",
  "name": "$name",
  "plan": "$plan",
  "created_at": "$created_at",
  "settings": {}
}
METADATA_EOF
	chmod 600 "$metadata_file"

	print_success "Created organisation: $slug ($name) [plan: $plan]"
	return 0
}

cmd_delete() {
	local slug="$1"

	validate_slug "$slug" || return 1

	if ! org_exists "$slug"; then
		print_error "Organisation '$slug' does not exist."
		return 1
	fi

	local org_dir
	org_dir="$(get_org_dir "$slug")"

	# Safety: check if this is the active org
	local active_org
	active_org="$(get_active_org)"
	if [[ "$active_org" == "$slug" ]]; then
		print_warning "Removing active org. Clearing active-org pointer."
		rm -f "$ACTIVE_ORG_FILE"
	fi

	rm -rf "$org_dir"
	print_success "Deleted organisation: $slug"
	return 0
}

cmd_list() {
	ensure_orgs_dir

	local active_org
	active_org="$(get_active_org)"

	if [[ ! -d "$ORGS_DIR" ]] || [[ -z "$(ls -A "$ORGS_DIR" 2>/dev/null)" ]]; then
		print_info "No organisations found. Create one with: multi-org-helper.sh create <slug> <name>"
		return 0
	fi

	printf "%-20s %-30s %-12s %s\n" "SLUG" "NAME" "PLAN" "STATUS"
	printf "%-20s %-30s %-12s %s\n" "----" "----" "----" "------"

	local slug
	for org_dir in "$ORGS_DIR"/*/; do
		[[ -d "$org_dir" ]] || continue
		slug="$(basename "$org_dir")"
		local metadata_file="$org_dir/org.json"

		if [[ -f "$metadata_file" ]]; then
			local name plan status
			name=$(grep -o '"name": *"[^"]*"' "$metadata_file" | head -1 | sed 's/"name": *"//;s/"$//')
			plan=$(grep -o '"plan": *"[^"]*"' "$metadata_file" | head -1 | sed 's/"plan": *"//;s/"$//')
			status=""
			if [[ "$slug" == "$active_org" ]]; then
				status="(active)"
			fi
			printf "%-20s %-30s %-12s %s\n" "$slug" "$name" "$plan" "$status"
		fi
	done

	return 0
}

cmd_switch() {
	local slug="$1"

	validate_slug "$slug" || return 1

	if ! org_exists "$slug"; then
		print_error "Organisation '$slug' does not exist."
		return 1
	fi

	ensure_orgs_dir
	echo "$slug" >"$ACTIVE_ORG_FILE"
	chmod 600 "$ACTIVE_ORG_FILE"

	print_success "Switched active organisation to: $slug"
	return 0
}

cmd_use() {
	local slug="$1"

	if [[ "$slug" == "--clear" ]]; then
		rm -f "$PROJECT_ORG_FILE"
		print_success "Cleared project-level organisation override."
		return 0
	fi

	validate_slug "$slug" || return 1

	if ! org_exists "$slug"; then
		print_error "Organisation '$slug' does not exist."
		return 1
	fi

	echo "$slug" >"$PROJECT_ORG_FILE"
	print_success "Set project-level organisation to: $slug"
	print_info "Add '$PROJECT_ORG_FILE' to .gitignore if not already present."
	return 0
}

cmd_status() {
	local active_org
	active_org="$(get_active_org)"

	echo "Multi-Org Status"
	echo "================"
	echo ""

	if [[ -n "$active_org" ]]; then
		echo "Active org: $active_org"

		if org_exists "$active_org"; then
			local metadata_file
			metadata_file="$(get_org_metadata_file "$active_org")"
			if [[ -f "$metadata_file" ]]; then
				local name plan
				name=$(grep -o '"name": *"[^"]*"' "$metadata_file" | head -1 | sed 's/"name": *"//;s/"$//')
				plan=$(grep -o '"plan": *"[^"]*"' "$metadata_file" | head -1 | sed 's/"plan": *"//;s/"$//')
				echo "  Name: $name"
				echo "  Plan: $plan"
			fi
		fi
	else
		echo "Active org: (none)"
	fi

	echo ""

	# Resolution source
	if [[ -f "$PROJECT_ORG_FILE" ]]; then
		local project_org
		project_org=$(tr -d '[:space:]' <"$PROJECT_ORG_FILE" 2>/dev/null)
		echo "Resolved via: project_config ($PROJECT_ORG_FILE = $project_org)"
	elif [[ -f "$ACTIVE_ORG_FILE" ]]; then
		echo "Resolved via: global ($ACTIVE_ORG_FILE)"
	else
		echo "Resolved via: (no org context)"
	fi

	echo ""

	# Count orgs
	local org_count=0
	if [[ -d "$ORGS_DIR" ]]; then
		org_count=$(find "$ORGS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
	fi
	echo "Total organisations: $org_count"

	return 0
}

cmd_info() {
	local slug="$1"

	validate_slug "$slug" || return 1

	if ! org_exists "$slug"; then
		print_error "Organisation '$slug' does not exist."
		return 1
	fi

	local metadata_file
	metadata_file="$(get_org_metadata_file "$slug")"

	if [[ -f "$metadata_file" ]]; then
		cat "$metadata_file"
	else
		print_error "No metadata found for '$slug'."
		return 1
	fi

	return 0
}

cmd_set_plan() {
	local slug="$1"
	local plan="$2"

	validate_slug "$slug" || return 1
	validate_plan "$plan" || return 1

	if ! org_exists "$slug"; then
		print_error "Organisation '$slug' does not exist."
		return 1
	fi

	local metadata_file
	metadata_file="$(get_org_metadata_file "$slug")"

	if [[ ! -f "$metadata_file" ]]; then
		print_error "No metadata found for '$slug'."
		return 1
	fi

	# Update plan in metadata (simple sed replacement)
	local tmp_file="${metadata_file}.tmp"
	sed "s/\"plan\": *\"[^\"]*\"/\"plan\": \"$plan\"/" "$metadata_file" >"$tmp_file"
	mv "$tmp_file" "$metadata_file"
	chmod 600 "$metadata_file"

	print_success "Updated plan for '$slug' to: $plan"
	return 0
}

cmd_context() {
	# Output current org context as environment variables (for eval)
	local active_org
	active_org="$(get_active_org)"

	if [[ -z "$active_org" ]]; then
		print_error "No active organisation. Use 'switch' or 'use' to set one."
		return 1
	fi

	if ! org_exists "$active_org"; then
		print_error "Active organisation '$active_org' does not exist."
		return 1
	fi

	local metadata_file
	metadata_file="$(get_org_metadata_file "$active_org")"

	local name plan
	name=$(grep -o '"name": *"[^"]*"' "$metadata_file" | head -1 | sed 's/"name": *"//;s/"$//')
	plan=$(grep -o '"plan": *"[^"]*"' "$metadata_file" | head -1 | sed 's/"plan": *"//;s/"$//')

	echo "export AIDEVOPS_ORG_SLUG=\"$active_org\""
	echo "export AIDEVOPS_ORG_NAME=\"$name\""
	echo "export AIDEVOPS_ORG_PLAN=\"$plan\""

	return 0
}

cmd_help() {
	cat <<'HELP_EOF'
Multi-Org Helper - Organisation management and tenant context

Usage: multi-org-helper.sh <command> [arguments]

Commands:
  init                          Initialise multi-org storage
  create <slug> [name] [plan]   Create a new organisation
  delete <slug>                 Delete an organisation
  list                          List all organisations
  switch <slug>                 Set global active organisation
  use <slug|--clear>            Set/clear project-level organisation
  status                        Show current org context and resolution
  info <slug>                   Show organisation metadata
  set-plan <slug> <plan>        Update organisation plan (free|pro|enterprise)
  context                       Output org context as env vars (for eval)
  help                          Show this help

Examples:
  multi-org-helper.sh create acme-corp "Acme Corporation" pro
  multi-org-helper.sh switch acme-corp
  multi-org-helper.sh use acme-corp          # Per-project override
  eval "$(multi-org-helper.sh context)"      # Load org context into shell

Plans: free, pro, enterprise
Roles: owner, admin, member, viewer

Schema: .agents/services/database/schemas/multi-org.ts
Design: .agents/services/database/multi-org-isolation.md
HELP_EOF
	return 0
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	init) cmd_init ;;
	create)
		if [[ $# -lt 1 ]]; then
			print_error "Usage: multi-org-helper.sh create <slug> [name] [plan]"
			return 1
		fi
		cmd_create "$@"
		;;
	delete)
		if [[ $# -lt 1 ]]; then
			print_error "Usage: multi-org-helper.sh delete <slug>"
			return 1
		fi
		cmd_delete "$1"
		;;
	list) cmd_list ;;
	switch)
		if [[ $# -lt 1 ]]; then
			print_error "Usage: multi-org-helper.sh switch <slug>"
			return 1
		fi
		cmd_switch "$1"
		;;
	use)
		if [[ $# -lt 1 ]]; then
			print_error "Usage: multi-org-helper.sh use <slug|--clear>"
			return 1
		fi
		cmd_use "$1"
		;;
	status) cmd_status ;;
	info)
		if [[ $# -lt 1 ]]; then
			print_error "Usage: multi-org-helper.sh info <slug>"
			return 1
		fi
		cmd_info "$1"
		;;
	set-plan)
		if [[ $# -lt 2 ]]; then
			print_error "Usage: multi-org-helper.sh set-plan <slug> <plan>"
			return 1
		fi
		cmd_set_plan "$1" "$2"
		;;
	context) cmd_context ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
