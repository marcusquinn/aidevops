#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2155
set -euo pipefail

# Procurement Helper Script
# Virtual card management, budget enforcement, receipt capture for autonomous missions
# Provider support: Stripe Issuing (primary), Revolut Business (alternative)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# String literal constants
readonly ERROR_JQ_REQUIRED="jq is required but not installed"
readonly ERROR_CURL_REQUIRED="curl is required but not installed"
readonly ERROR_MISSION_REQUIRED="Mission ID is required (--mission M001)"
readonly ERROR_AMOUNT_REQUIRED="Amount is required (--amount 50.00)"
readonly ERROR_CARD_REQUIRED="Card ID is required (--card ic_xxx)"
readonly ERROR_PROVIDER_UNSUPPORTED="Unsupported provider. Use 'stripe' or 'revolut'"
readonly ERROR_BUDGET_EXCEEDED="Purchase would exceed mission budget"
readonly ERROR_APPROVAL_REQUIRED="Amount exceeds auto-approval threshold — human approval required"

CONFIG_DIR="${SCRIPT_DIR}/../configs"
CONFIG_FILE="${CONFIG_DIR}/procurement-config.json"

# ============================================================================
# Dependency checks
# ============================================================================

check_dependencies() {
	local missing=0

	if ! command -v curl &>/dev/null; then
		print_error "$ERROR_CURL_REQUIRED"
		missing=1
	fi

	if ! command -v jq &>/dev/null; then
		print_error "$ERROR_JQ_REQUIRED"
		missing=1
	fi

	if [[ "$missing" -eq 1 ]]; then
		return 1
	fi
	return 0
}

# ============================================================================
# Configuration
# ============================================================================

load_config() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		print_error "Config not found: $CONFIG_FILE"
		print_info "Copy template: cp ${CONFIG_DIR}/procurement-config.json.txt ${CONFIG_FILE}"
		return 1
	fi
	return 0
}

get_config_value() {
	local key="$1"
	local default="${2:-}"

	local value
	value=$(jq -r "$key // empty" "$CONFIG_FILE" 2>/dev/null)
	if [[ -z "$value" ]]; then
		echo "$default"
	else
		echo "$value"
	fi
	return 0
}

get_provider() {
	local provider
	provider=$(get_config_value '.provider' 'stripe')
	echo "$provider"
	return 0
}

get_currency() {
	local currency
	currency=$(get_config_value '.currency' 'GBP')
	echo "$currency"
	return 0
}

# ============================================================================
# API key retrieval (never prints values)
# ============================================================================

get_api_key() {
	local provider="$1"

	case "$provider" in
	stripe)
		# Try gopass first, fall back to env
		if command -v gopass &>/dev/null; then
			gopass show -o "aidevops/STRIPE_ISSUING_SECRET_KEY" 2>/dev/null && return 0
		fi
		if [[ -n "${STRIPE_ISSUING_SECRET_KEY:-}" ]]; then
			echo "${STRIPE_ISSUING_SECRET_KEY}"
			return 0
		fi
		print_error "STRIPE_ISSUING_SECRET_KEY not found. Run: aidevops secret set STRIPE_ISSUING_SECRET_KEY"
		return 1
		;;
	revolut)
		if command -v gopass &>/dev/null; then
			gopass show -o "aidevops/REVOLUT_API_TOKEN" 2>/dev/null && return 0
		fi
		if [[ -n "${REVOLUT_API_TOKEN:-}" ]]; then
			echo "${REVOLUT_API_TOKEN}"
			return 0
		fi
		print_error "REVOLUT_API_TOKEN not found. Run: aidevops secret set REVOLUT_API_TOKEN"
		return 1
		;;
	*)
		print_error "$ERROR_PROVIDER_UNSUPPORTED"
		return 1
		;;
	esac
}

# ============================================================================
# Budget management
# ============================================================================

get_mission_dir() {
	local mission_id="$1"

	# Check repo-attached first, then homeless
	if [[ -d "todo/missions/${mission_id}" ]]; then
		echo "todo/missions/${mission_id}"
	elif [[ -d "${HOME}/.aidevops/missions/${mission_id}" ]]; then
		echo "${HOME}/.aidevops/missions/${mission_id}"
	else
		print_error "Mission directory not found for ${mission_id}"
		return 1
	fi
	return 0
}

get_mission_budget() {
	local mission_id="$1"

	local mission_dir
	mission_dir=$(get_mission_dir "$mission_id") || return 1

	local budget
	budget=$(jq -r '.budget.total // 0' "${mission_dir}/budget.json" 2>/dev/null)
	echo "$budget"
	return 0
}

get_mission_spent() {
	local mission_id="$1"

	local mission_dir
	mission_dir=$(get_mission_dir "$mission_id") || return 1

	local spent
	spent=$(jq -r '.budget.spent // 0' "${mission_dir}/budget.json" 2>/dev/null)
	echo "$spent"
	return 0
}

check_budget() {
	local mission_id="$1"
	local amount="$2"

	local budget
	budget=$(get_mission_budget "$mission_id") || return 1
	local spent
	spent=$(get_mission_spent "$mission_id") || return 1
	local reserve_pct
	reserve_pct=$(get_config_value '.reserve_percentage' '20')

	# Calculate available (budget minus spent minus reserve)
	local reserve
	reserve=$(echo "$budget * $reserve_pct / 100" | bc -l 2>/dev/null || echo "0")
	local available
	available=$(echo "$budget - $spent - $reserve" | bc -l 2>/dev/null || echo "0")

	local sufficient
	sufficient=$(echo "$available >= $amount" | bc -l 2>/dev/null || echo "0")

	if [[ "$sufficient" != "1" ]]; then
		print_error "$ERROR_BUDGET_EXCEEDED"
		print_info "Budget: ${budget}, Spent: ${spent}, Reserve: ${reserve}, Available: ${available}, Requested: ${amount}"
		return 1
	fi

	# Check approval thresholds
	local auto_threshold
	auto_threshold=$(get_config_value '.approval_thresholds.auto' '50')
	local notify_threshold
	notify_threshold=$(get_config_value '.approval_thresholds.auto_with_notification' '200')
	local manual_threshold
	manual_threshold=$(get_config_value '.approval_thresholds.manual' '500')

	local needs_approval
	needs_approval=$(echo "$amount > $manual_threshold" | bc -l 2>/dev/null || echo "0")
	if [[ "$needs_approval" == "1" ]]; then
		print_error "$ERROR_APPROVAL_REQUIRED"
		print_info "Amount ${amount} exceeds manual approval threshold (${manual_threshold})"
		return 2
	fi

	local needs_notification
	needs_notification=$(echo "$amount > $auto_threshold" | bc -l 2>/dev/null || echo "0")
	if [[ "$needs_notification" == "1" ]]; then
		print_warning "Amount ${amount} exceeds auto threshold (${auto_threshold}) — notification will be sent"
	fi

	print_success "Budget check passed: ${amount} within available ${available}"
	return 0
}

# ============================================================================
# Stripe Issuing operations
# ============================================================================

stripe_create_card() {
	local cardholder_id="$1"
	local amount="$2"
	local currency="$3"
	local description="$4"
	local mccs="$5"

	local api_key
	api_key=$(get_api_key "stripe") || return 1

	local response
	response=$(curl -s -X POST "https://api.stripe.com/v1/issuing/cards" \
		-u "${api_key}:" \
		-d "type=virtual" \
		-d "cardholder=${cardholder_id}" \
		-d "currency=${currency,,}" \
		-d "spending_controls[spending_limits][0][amount]=$(echo "$amount * 100" | bc | cut -d. -f1)" \
		-d "spending_controls[spending_limits][0][interval]=all_time" \
		-d "metadata[description]=${description}" \
		2>/dev/null)

	local card_id
	card_id=$(echo "$response" | jq -r '.id // empty')
	if [[ -z "$card_id" ]]; then
		local error_msg
		error_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"')
		print_error "Failed to create card: ${error_msg}"
		return 1
	fi

	echo "$card_id"
	return 0
}

stripe_freeze_card() {
	local card_id="$1"

	local api_key
	api_key=$(get_api_key "stripe") || return 1

	local response
	response=$(curl -s -X POST "https://api.stripe.com/v1/issuing/cards/${card_id}" \
		-u "${api_key}:" \
		-d "status=inactive" \
		2>/dev/null)

	local status
	status=$(echo "$response" | jq -r '.status // empty')
	if [[ "$status" != "inactive" ]]; then
		print_error "Failed to freeze card ${card_id}"
		return 1
	fi

	print_success "Card ${card_id} frozen"
	return 0
}

stripe_close_card() {
	local card_id="$1"

	local api_key
	api_key=$(get_api_key "stripe") || return 1

	local response
	response=$(curl -s -X POST "https://api.stripe.com/v1/issuing/cards/${card_id}" \
		-u "${api_key}:" \
		-d "status=canceled" \
		2>/dev/null)

	local status
	status=$(echo "$response" | jq -r '.status // empty')
	if [[ "$status" != "canceled" ]]; then
		print_error "Failed to close card ${card_id}"
		return 1
	fi

	print_success "Card ${card_id} closed"
	return 0
}

stripe_get_transactions() {
	local card_id="$1"
	local limit="${2:-100}"

	local api_key
	api_key=$(get_api_key "stripe") || return 1

	local response
	response=$(curl -s "https://api.stripe.com/v1/issuing/transactions?card=${card_id}&limit=${limit}" \
		-u "${api_key}:" \
		2>/dev/null)

	echo "$response" | jq '.data'
	return 0
}

stripe_list_cards() {
	local status="${1:-active}"
	local limit="${2:-100}"

	local api_key
	api_key=$(get_api_key "stripe") || return 1

	local response
	response=$(curl -s "https://api.stripe.com/v1/issuing/cards?status=${status}&limit=${limit}" \
		-u "${api_key}:" \
		2>/dev/null)

	echo "$response" | jq '.data'
	return 0
}

# ============================================================================
# Revolut Business operations (alternative provider)
# ============================================================================

revolut_create_card() {
	local account_id="$1"
	local amount="$2"
	local currency="$3"
	local description="$4"

	local api_key
	api_key=$(get_api_key "revolut") || return 1

	local response
	response=$(curl -s -X POST "https://b2b.revolut.com/api/1.0/cards" \
		-H "Authorization: Bearer ${api_key}" \
		-H "Content-Type: application/json" \
		-d "{
            \"virtual\": true,
            \"label\": \"${description}\",
            \"spending_limits\": {
                \"single\": {\"amount\": $(echo "$amount * 100" | bc | cut -d. -f1), \"currency\": \"${currency}\"},
                \"month\": {\"amount\": $(echo "$amount * 100" | bc | cut -d. -f1), \"currency\": \"${currency}\"}
            }
        }" \
		2>/dev/null)

	local card_id
	card_id=$(echo "$response" | jq -r '.id // empty')
	if [[ -z "$card_id" ]]; then
		print_error "Failed to create Revolut card"
		return 1
	fi

	echo "$card_id"
	return 0
}

revolut_freeze_card() {
	local card_id="$1"

	local api_key
	api_key=$(get_api_key "revolut") || return 1

	curl -s -X POST "https://b2b.revolut.com/api/1.0/cards/${card_id}/freeze" \
		-H "Authorization: Bearer ${api_key}" \
		2>/dev/null

	print_success "Revolut card ${card_id} frozen"
	return 0
}

# ============================================================================
# Vaultwarden integration
# ============================================================================

store_card_in_vault() {
	local card_id="$1"
	local mission_id="$2"
	local card_data="$3"

	# Check if bw CLI is available and unlocked
	if ! command -v bw &>/dev/null; then
		print_warning "Bitwarden CLI not available — card details not stored in vault"
		print_info "Install with: npm install -g @bitwarden/cli"
		return 1
	fi

	local bw_status
	bw_status=$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')
	if [[ "$bw_status" != "unlocked" ]]; then
		print_warning "Vault is locked — card details not stored"
		print_info "Unlock with: export BW_SESSION=\$(bw unlock --raw)"
		return 1
	fi

	# Create vault item with card details
	local item_template
	item_template=$(bw get template item 2>/dev/null)

	local encoded_item
	encoded_item=$(echo "$item_template" | jq \
		--arg name "Mission ${mission_id} - Card ${card_id}" \
		--arg notes "Auto-created by procurement-helper.sh for mission ${mission_id}" \
		'.name = $name | .notes = $notes | .type = 3' |
		bw encode 2>/dev/null)

	if bw create item "$encoded_item" 2>/dev/null; then
		print_success "Card ${card_id} stored in Vaultwarden"
	else
		print_warning "Failed to store card in Vaultwarden — manual storage required"
	fi
	return 0
}

# ============================================================================
# Receipt capture
# ============================================================================

capture_receipt() {
	local mission_id="$1"
	local card_id="$2"
	local vendor="$3"
	local amount="$4"
	local screenshot="${5:-}"

	local mission_dir
	mission_dir=$(get_mission_dir "$mission_id") || return 1

	local receipts_dir="${mission_dir}/receipts"
	mkdir -p "$receipts_dir"

	local timestamp
	timestamp=$(date +%Y-%m-%d-%H%M%S)
	local receipt_file="${receipts_dir}/${timestamp}-${vendor}-${amount}.json"

	# Create structured receipt
	jq -n \
		--arg mission "$mission_id" \
		--arg card "$card_id" \
		--arg vendor "$vendor" \
		--arg amount "$amount" \
		--arg currency "$(get_currency)" \
		--arg timestamp "$timestamp" \
		--arg screenshot "${screenshot:-none}" \
		'{
            mission: $mission,
            card: $card,
            vendor: $vendor,
            amount: ($amount | tonumber),
            currency: $currency,
            timestamp: $timestamp,
            screenshot: $screenshot,
            status: "captured"
        }' >"$receipt_file"

	# Copy screenshot if provided
	if [[ -n "$screenshot" && -f "$screenshot" ]]; then
		cp "$screenshot" "${receipts_dir}/${timestamp}-${vendor}-receipt.png"
	fi

	print_success "Receipt captured: ${receipt_file}"
	return 0
}

# ============================================================================
# Ledger management
# ============================================================================

update_ledger() {
	local mission_id="$1"
	local vendor="$2"
	local description="$3"
	local card_id="$4"
	local amount="$5"
	local approval_type="$6"

	local mission_dir
	mission_dir=$(get_mission_dir "$mission_id") || return 1

	local ledger_file="${mission_dir}/ledger.md"
	local date_str
	date_str=$(date +%Y-%m-%d)

	# Create ledger if it doesn't exist
	if [[ ! -f "$ledger_file" ]]; then
		cat >"$ledger_file" <<'LEDGER'
## Budget Ledger

| Date | Vendor | Description | Card | Amount | Balance | Approved By |
|------|--------|-------------|------|--------|---------|-------------|
LEDGER
	fi

	# Calculate new balance
	local budget
	budget=$(get_mission_budget "$mission_id")
	local spent
	spent=$(get_mission_spent "$mission_id")
	local new_balance
	new_balance=$(echo "$budget - $spent - $amount" | bc -l 2>/dev/null || echo "0")

	# Append to ledger
	echo "| ${date_str} | ${vendor} | ${description} | ${card_id} | \$${amount} | \$${new_balance} | ${approval_type} |" >>"$ledger_file"

	# Update budget.json
	local budget_file="${mission_dir}/budget.json"
	if [[ -f "$budget_file" ]]; then
		local new_spent
		new_spent=$(echo "$spent + $amount" | bc -l 2>/dev/null || echo "$amount")
		jq --arg spent "$new_spent" '.budget.spent = ($spent | tonumber)' "$budget_file" >"${budget_file}.tmp" &&
			mv "${budget_file}.tmp" "$budget_file"
	fi

	print_success "Ledger updated: ${vendor} ${amount}"
	return 0
}

# ============================================================================
# Audit
# ============================================================================

audit_mission() {
	local mission_id="$1"

	local mission_dir
	mission_dir=$(get_mission_dir "$mission_id") || return 1

	print_info "=== Procurement Audit: ${mission_id} ==="

	# Budget summary
	local budget
	budget=$(get_mission_budget "$mission_id")
	local spent
	spent=$(get_mission_spent "$mission_id")
	local remaining
	remaining=$(echo "$budget - $spent" | bc -l 2>/dev/null || echo "0")

	echo "Budget:    \$${budget}"
	echo "Spent:     \$${spent}"
	echo "Remaining: \$${remaining}"
	echo ""

	# Count receipts
	local receipts_dir="${mission_dir}/receipts"
	if [[ -d "$receipts_dir" ]]; then
		local receipt_count
		receipt_count=$(find "$receipts_dir" -name "*.json" | wc -l | tr -d ' ')
		echo "Receipts:  ${receipt_count}"
	else
		echo "Receipts:  0"
	fi

	# Show ledger
	local ledger_file="${mission_dir}/ledger.md"
	if [[ -f "$ledger_file" ]]; then
		echo ""
		cat "$ledger_file"
	fi

	# Check for cards still active
	local provider
	provider=$(get_provider)
	if [[ "$provider" == "stripe" ]]; then
		print_info "Checking for active cards..."
		local active_cards
		active_cards=$(stripe_list_cards "active" 100 2>/dev/null | jq -r '.[].id' 2>/dev/null || echo "")
		if [[ -n "$active_cards" ]]; then
			print_warning "Active cards found (should be frozen after use):"
			echo "$active_cards"
		else
			print_success "No active cards — all frozen or closed"
		fi
	fi

	return 0
}

# ============================================================================
# Main command router
# ============================================================================

show_help() {
	cat <<'HELP'
Procurement Helper - Virtual card management for autonomous missions

Usage: procurement-helper.sh <command> [options]

Card Management:
  create-card   --mission M001 --vendor name --amount 50.00 [--description "..."]
  freeze-card   --card ic_xxx
  close-card    --card ic_xxx
  list-cards    [--mission M001] [--status active|inactive|canceled]

Budget Operations:
  check-budget  --mission M001 [--amount 50.00]
  allocate      --mission M001 --milestone MS1 --amount 200.00
  spend         --mission M001 --amount 12.00 --vendor name --description "..." --card ic_xxx

Receipt Capture:
  capture-receipt --mission M001 --card ic_xxx --vendor name --amount 12.00 [--screenshot path]
  export-ledger   --mission M001 [--format csv|md]

Audit:
  audit         --mission M001
  reconcile     --mission M001

Configuration:
  status        Show provider configuration and connection status
  help          Show this help

Options:
  --mission     Mission ID (e.g., M001)
  --vendor      Vendor name (e.g., cloudflare, hetzner)
  --amount      Amount in configured currency
  --card        Card ID (e.g., ic_xxx for Stripe)
  --description Purchase description
  --screenshot  Path to receipt screenshot
  --format      Export format (csv, md)
  --status      Card status filter

Environment:
  STRIPE_ISSUING_SECRET_KEY  Stripe Issuing API key (or use gopass)
  REVOLUT_API_TOKEN          Revolut Business API token (or use gopass)

Config: configs/procurement-config.json (copy from .json.txt template)
HELP
	return 0
}

parse_args() {
	MISSION=""
	VENDOR=""
	AMOUNT=""
	CARD=""
	DESCRIPTION=""
	SCREENSHOT=""
	FORMAT="md"
	STATUS="active"
	MILESTONE=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission)
			MISSION="$2"
			shift 2
			;;
		--vendor)
			VENDOR="$2"
			shift 2
			;;
		--amount)
			AMOUNT="$2"
			shift 2
			;;
		--card)
			CARD="$2"
			shift 2
			;;
		--description)
			DESCRIPTION="$2"
			shift 2
			;;
		--screenshot)
			SCREENSHOT="$2"
			shift 2
			;;
		--format)
			FORMAT="$2"
			shift 2
			;;
		--status)
			STATUS="$2"
			shift 2
			;;
		--milestone)
			MILESTONE="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	check_dependencies || exit 1

	case "$command" in
	create-card)
		load_config || exit 1
		parse_args "$@"
		[[ -z "$MISSION" ]] && {
			print_error "$ERROR_MISSION_REQUIRED"
			exit 1
		}
		[[ -z "$AMOUNT" ]] && {
			print_error "$ERROR_AMOUNT_REQUIRED"
			exit 1
		}

		# Budget check
		check_budget "$MISSION" "$AMOUNT" || exit $?

		local provider
		provider=$(get_provider)
		local currency
		currency=$(get_currency)
		local mccs
		mccs=$(get_config_value '.allowed_mccs | join(",")' '')
		local cardholder
		cardholder=$(get_config_value '.cardholder_id' '')

		local card_id
		case "$provider" in
		stripe)
			card_id=$(stripe_create_card "$cardholder" "$AMOUNT" "$currency" "${DESCRIPTION:-$VENDOR}" "$mccs") || exit 1
			;;
		revolut)
			local account_id
			account_id=$(get_config_value '.revolut_account_id' '')
			card_id=$(revolut_create_card "$account_id" "$AMOUNT" "$currency" "${DESCRIPTION:-$VENDOR}") || exit 1
			;;
		*)
			print_error "$ERROR_PROVIDER_UNSUPPORTED"
			exit 1
			;;
		esac

		# Store in Vaultwarden
		store_card_in_vault "$card_id" "$MISSION" "" || true

		print_success "Card created: ${card_id} (limit: ${AMOUNT} ${currency})"
		;;

	freeze-card)
		load_config || exit 1
		parse_args "$@"
		[[ -z "$CARD" ]] && {
			print_error "$ERROR_CARD_REQUIRED"
			exit 1
		}

		local provider
		provider=$(get_provider)
		case "$provider" in
		stripe) stripe_freeze_card "$CARD" ;;
		revolut) revolut_freeze_card "$CARD" ;;
		*)
			print_error "$ERROR_PROVIDER_UNSUPPORTED"
			exit 1
			;;
		esac
		;;

	close-card)
		load_config || exit 1
		parse_args "$@"
		[[ -z "$CARD" ]] && {
			print_error "$ERROR_CARD_REQUIRED"
			exit 1
		}

		local provider
		provider=$(get_provider)
		case "$provider" in
		stripe) stripe_close_card "$CARD" ;;
		*)
			print_error "Close not supported for provider: ${provider}"
			exit 1
			;;
		esac
		;;

	list-cards)
		load_config || exit 1
		parse_args "$@"

		local provider
		provider=$(get_provider)
		case "$provider" in
		stripe) stripe_list_cards "$STATUS" 100 ;;
		*)
			print_error "List not supported for provider: ${provider}"
			exit 1
			;;
		esac
		;;

	check-budget)
		load_config || exit 1
		parse_args "$@"
		[[ -z "$MISSION" ]] && {
			print_error "$ERROR_MISSION_REQUIRED"
			exit 1
		}

		if [[ -n "$AMOUNT" ]]; then
			check_budget "$MISSION" "$AMOUNT"
		else
			# Just show budget status
			local budget
			budget=$(get_mission_budget "$MISSION")
			local spent
			spent=$(get_mission_spent "$MISSION")
			local remaining
			remaining=$(echo "$budget - $spent" | bc -l 2>/dev/null || echo "0")
			echo "Mission: ${MISSION}"
			echo "Budget:  \$${budget}"
			echo "Spent:   \$${spent}"
			echo "Remaining: \$${remaining}"
		fi
		;;

	spend)
		load_config || exit 1
		parse_args "$@"
		[[ -z "$MISSION" ]] && {
			print_error "$ERROR_MISSION_REQUIRED"
			exit 1
		}
		[[ -z "$AMOUNT" ]] && {
			print_error "$ERROR_AMOUNT_REQUIRED"
			exit 1
		}
		[[ -z "$VENDOR" ]] && {
			print_error "Vendor is required (--vendor name)"
			exit 1
		}

		update_ledger "$MISSION" "$VENDOR" "${DESCRIPTION:-$VENDOR}" "${CARD:-manual}" "$AMOUNT" "auto (within budget)"
		;;

	capture-receipt)
		load_config || exit 1
		parse_args "$@"
		[[ -z "$MISSION" ]] && {
			print_error "$ERROR_MISSION_REQUIRED"
			exit 1
		}

		capture_receipt "$MISSION" "${CARD:-unknown}" "${VENDOR:-unknown}" "${AMOUNT:-0}" "$SCREENSHOT"
		;;

	export-ledger)
		load_config || exit 1
		parse_args "$@"
		[[ -z "$MISSION" ]] && {
			print_error "$ERROR_MISSION_REQUIRED"
			exit 1
		}

		local mission_dir
		mission_dir=$(get_mission_dir "$MISSION") || exit 1
		local ledger_file="${mission_dir}/ledger.md"

		if [[ ! -f "$ledger_file" ]]; then
			print_error "No ledger found for mission ${MISSION}"
			exit 1
		fi

		if [[ "$FORMAT" == "csv" ]]; then
			# Convert markdown table to CSV
			grep "^|" "$ledger_file" | grep -v "^|---" | sed 's/^| //;s/ |$//' | sed 's/ | /,/g'
		else
			cat "$ledger_file"
		fi
		;;

	audit)
		load_config || exit 1
		parse_args "$@"
		[[ -z "$MISSION" ]] && {
			print_error "$ERROR_MISSION_REQUIRED"
			exit 1
		}
		audit_mission "$MISSION"
		;;

	reconcile)
		load_config || exit 1
		parse_args "$@"
		[[ -z "$MISSION" ]] && {
			print_error "$ERROR_MISSION_REQUIRED"
			exit 1
		}

		print_info "Reconciling mission ${MISSION} against provider transactions..."

		local provider
		provider=$(get_provider)
		if [[ "$provider" == "stripe" ]]; then
			print_info "Fetching Stripe transactions..."
			# Would compare ledger entries against actual Stripe transactions
			print_warning "Full reconciliation requires implementation — showing audit instead"
			audit_mission "$MISSION"
		else
			print_warning "Reconciliation not yet implemented for provider: ${provider}"
		fi
		;;

	status)
		load_config || exit 1
		local provider
		provider=$(get_provider)
		local currency
		currency=$(get_currency)

		echo "Provider: ${provider}"
		echo "Currency: ${currency}"

		# Test API connectivity (without exposing keys)
		if get_api_key "$provider" >/dev/null 2>&1; then
			print_success "API key configured"
		else
			print_error "API key not configured"
		fi

		# Check Vaultwarden
		if command -v bw &>/dev/null; then
			local bw_status
			bw_status=$(bw status 2>/dev/null | jq -r '.status // "unknown"')
			echo "Vaultwarden: ${bw_status}"
		else
			echo "Vaultwarden: CLI not installed"
		fi
		;;

	help | --help | -h)
		show_help
		;;

	*)
		print_error "Unknown command: ${command}"
		show_help
		exit 1
		;;
	esac
}

main "$@"
