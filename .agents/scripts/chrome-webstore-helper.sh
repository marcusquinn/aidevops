#!/usr/bin/env bash
# shellcheck disable=SC2034

# Chrome Web Store Helper Script
# Automate Chrome extension publishing via Chrome Web Store API
# Managed by AI DevOps Framework

# Set strict mode
set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION & CONSTANTS
# ------------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${script_dir}/shared-constants.sh"

readonly SCRIPT_DIR="$script_dir"

repo_root="$(dirname "$SCRIPT_DIR")"
readonly REPO_ROOT="$repo_root"

# API Endpoints
readonly CWS_TOKEN_URL="https://oauth2.googleapis.com/token"
readonly CWS_API_BASE="https://chromewebstore.googleapis.com"

# Error Messages
readonly ERROR_MANIFEST_NOT_FOUND="Manifest file not found"
readonly ERROR_MANIFEST_REQUIRED="Manifest path is required"
readonly ERROR_CREDENTIALS_MISSING="Required credentials are missing"
readonly ERROR_JQ_NOT_INSTALLED="jq is required but not installed"
readonly ERROR_ZIP_NOT_INSTALLED="zip is required but not installed"
readonly ERROR_BUILD_FAILED="Build command failed"
readonly ERROR_ZIP_FAILED="Zip command failed"
readonly ERROR_UPLOAD_FAILED="Upload to Chrome Web Store failed"
readonly ERROR_PUBLISH_FAILED="Publish to Chrome Web Store failed"
readonly ERROR_STATUS_FAILED="Failed to fetch status from Chrome Web Store"
readonly ERROR_TOKEN_EXCHANGE_FAILED="Failed to exchange refresh token for access token"
readonly ERROR_GH_NOT_INSTALLED="GitHub CLI (gh) is required but not installed"
readonly ERROR_GH_NOT_AUTHENTICATED="GitHub CLI is not authenticated"

# Success Messages
readonly SUCCESS_SETUP_COMPLETE="Chrome Web Store credentials configured successfully"
readonly SUCCESS_PUBLISH_COMPLETE="Extension published successfully"
readonly SUCCESS_UPLOAD_COMPLETE="Extension uploaded successfully"
readonly SUCCESS_SECRETS_UPLOADED="Secrets uploaded to GitHub successfully"

# Required credential keys
readonly REQUIRED_CREDENTIALS=(
	"CWS_CLIENT_ID"
	"CWS_CLIENT_SECRET"
	"CWS_REFRESH_TOKEN"
	"CWS_PUBLISHER_ID"
	"CWS_EXTENSION_ID"
)

# ------------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------------------

print_error() {
	local message="$1"
	echo -e "\033[1;31m[ERROR]\033[0m $message" >&2
	return 0
}

print_success() {
	local message="$1"
	echo -e "\033[0;32m[OK]\033[0m $message"
	return 0
}

print_info() {
	local message="$1"
	echo -e "\033[1;33m[INFO]\033[0m $message"
	return 0
}

print_warning() {
	local message="$1"
	echo -e "\033[1;33m[WARN]\033[0m $message"
	return 0
}

# ------------------------------------------------------------------------------
# DEPENDENCY CHECKING
# ------------------------------------------------------------------------------

check_dependencies() {
	local missing_deps=()

	if ! command -v jq &>/dev/null; then
		missing_deps+=("jq")
	fi

	if ! command -v zip &>/dev/null; then
		missing_deps+=("zip")
	fi

	if [[ ${#missing_deps[@]} -gt 0 ]]; then
		print_error "Missing required dependencies: ${missing_deps[*]}"
		print_info "Install missing dependencies:"
		for dep in "${missing_deps[@]}"; do
			case "$dep" in
			jq)
				print_info "  macOS: brew install jq"
				print_info "  Ubuntu: sudo apt install jq"
				;;
			zip)
				print_info "  macOS: brew install zip"
				print_info "  Ubuntu: sudo apt install zip"
				;;
			esac
		done
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------------------
# CREDENTIAL MANAGEMENT
# ------------------------------------------------------------------------------

load_credentials() {
	local env_file="${1:-.env}"

	# Try to load from env file if it exists
	if [[ -f "$env_file" ]]; then
		# shellcheck disable=SC1090
		source "$env_file"
	fi

	# Try to load from aidevops secret storage
	if command -v aidevops &>/dev/null; then
		for key in "${REQUIRED_CREDENTIALS[@]}"; do
			if [[ -z "${!key:-}" ]]; then
				local value
				value=$(aidevops secret get "$key" 2>/dev/null || echo "")
				if [[ -n "$value" ]]; then
					export "$key=$value"
				fi
			fi
		done
	fi

	# Validate all required credentials are present
	local missing_creds=()
	for key in "${REQUIRED_CREDENTIALS[@]}"; do
		if [[ -z "${!key:-}" ]]; then
			missing_creds+=("$key")
		fi
	done

	if [[ ${#missing_creds[@]} -gt 0 ]]; then
		print_error "$ERROR_CREDENTIALS_MISSING"
		print_info "Missing credentials: ${missing_creds[*]}"
		print_info "Run 'chrome-webstore-helper.sh setup' to configure credentials"
		return 1
	fi

	return 0
}

validate_credentials() {
	local missing_creds=()

	for key in "${REQUIRED_CREDENTIALS[@]}"; do
		if [[ -z "${!key:-}" ]]; then
			missing_creds+=("$key")
		fi
	done

	if [[ ${#missing_creds[@]} -gt 0 ]]; then
		print_error "$ERROR_CREDENTIALS_MISSING"
		print_info "Missing credentials: ${missing_creds[*]}"
		return 1
	fi

	return 0
}

# ------------------------------------------------------------------------------
# SETUP COMMAND
# ------------------------------------------------------------------------------

cmd_setup() {
	print_info "Chrome Web Store Credential Setup"
	print_info "===================================="
	echo ""

	print_info "This wizard will guide you through setting up Chrome Web Store API credentials."
	print_info "You will need to complete several manual steps in Google Cloud Console."
	echo ""

	# Step 1: Enable API
	print_info "Step 1: Enable Chrome Web Store API"
	print_info "1. Open: https://console.cloud.google.com/apis/library/chromewebstore.googleapis.com"
	print_info "2. Select your Google Cloud project"
	print_info "3. Click 'Enable' for Chrome Web Store API"
	echo ""
	read -rp "Press Enter when Chrome Web Store API is enabled..."
	echo ""

	# Step 2: OAuth Consent Screen
	print_info "Step 2: Configure OAuth Consent Screen"
	print_info "1. Open: https://console.cloud.google.com/apis/credentials/consent"
	print_info "2. Choose 'External' user type"
	print_info "3. Fill in app name, support email, developer contact email"
	print_info "4. Save and continue through scopes"
	print_info "5. Add your Google account as a test user if in Testing mode"
	echo ""
	read -rp "Press Enter when OAuth consent screen is configured..."
	echo ""

	# Step 3: Create OAuth Client
	print_info "Step 3: Create OAuth Client"
	print_info "1. Open: https://console.cloud.google.com/apis/credentials"
	print_info "2. Click 'Create Credentials' -> 'OAuth client ID'"
	print_info "3. Choose 'Web application'"
	print_info "4. Add authorized redirect URI: https://developers.google.com/oauthplayground"
	print_info "5. Create client and copy credentials"
	echo ""

	read -rp "Enter CWS_CLIENT_ID: " CWS_CLIENT_ID
	read -rsp "Enter CWS_CLIENT_SECRET: " CWS_CLIENT_SECRET
	echo ""
	echo ""

	# Step 4: Generate Refresh Token
	print_info "Step 4: Generate Refresh Token"
	print_info "1. Open: https://developers.google.com/oauthplayground/"
	print_info "2. Click settings gear icon"
	print_info "3. Enable 'Use your own OAuth credentials'"
	print_info "4. Paste your Client ID and Client Secret"
	print_info "5. In Step 1, enter scope: https://www.googleapis.com/auth/chromewebstore"
	print_info "6. Click 'Authorize APIs' and sign in"
	print_info "7. Click 'Exchange authorization code for tokens'"
	print_info "8. Copy the refresh token"
	echo ""

	read -rsp "Enter CWS_REFRESH_TOKEN: " CWS_REFRESH_TOKEN
	echo ""
	echo ""

	# Step 5: Capture Store IDs
	print_info "Step 5: Capture Store IDs"
	print_info "1. Open Chrome Web Store Developer Dashboard"
	print_info "2. Copy extension item ID from URL or item details"
	print_info "3. Copy publisher ID from account details or URL"
	echo ""

	read -rp "Enter CWS_EXTENSION_ID: " CWS_EXTENSION_ID
	read -rp "Enter CWS_PUBLISHER_ID: " CWS_PUBLISHER_ID
	echo ""

	# Save credentials
	print_info "Saving credentials..."

	if command -v aidevops &>/dev/null; then
		print_info "Using aidevops secret storage (encrypted)"
		echo "$CWS_CLIENT_ID" | aidevops secret set CWS_CLIENT_ID
		echo "$CWS_CLIENT_SECRET" | aidevops secret set CWS_CLIENT_SECRET
		echo "$CWS_REFRESH_TOKEN" | aidevops secret set CWS_REFRESH_TOKEN
		echo "$CWS_EXTENSION_ID" | aidevops secret set CWS_EXTENSION_ID
		echo "$CWS_PUBLISHER_ID" | aidevops secret set CWS_PUBLISHER_ID
	else
		print_warning "aidevops not found, saving to .env file (plaintext)"
		local env_file=".env.cws"
		{
			echo "CWS_CLIENT_ID=$CWS_CLIENT_ID"
			echo "CWS_CLIENT_SECRET=$CWS_CLIENT_SECRET"
			echo "CWS_REFRESH_TOKEN=$CWS_REFRESH_TOKEN"
			echo "CWS_EXTENSION_ID=$CWS_EXTENSION_ID"
			echo "CWS_PUBLISHER_ID=$CWS_PUBLISHER_ID"
		} >"$env_file"
		chmod 600 "$env_file"
		print_info "Credentials saved to $env_file (600 permissions)"
		print_warning "Add $env_file to .gitignore to prevent committing secrets"
	fi

	print_success "$SUCCESS_SETUP_COMPLETE"
	return 0
}

# ------------------------------------------------------------------------------
# TOKEN EXCHANGE
# ------------------------------------------------------------------------------

exchange_token() {
	local client_id="$1"
	local client_secret="$2"
	local refresh_token="$3"

	local response
	response=$(curl -s -X POST "$CWS_TOKEN_URL" \
		-d "client_id=$client_id" \
		-d "client_secret=$client_secret" \
		-d "refresh_token=$refresh_token" \
		-d "grant_type=refresh_token")

	local access_token
	access_token=$(echo "$response" | jq -r '.access_token // empty')

	if [[ -z "$access_token" ]]; then
		print_error "$ERROR_TOKEN_EXCHANGE_FAILED"
		print_error "Response: $response"
		return 1
	fi

	echo "$access_token"
	return 0
}

# ------------------------------------------------------------------------------
# STATUS COMMAND
# ------------------------------------------------------------------------------

cmd_status() {
	local manifest_path=""
	local json_output=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--manifest)
			manifest_path="$2"
			shift 2
			;;
		--json)
			json_output=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	check_dependencies || return 1
	load_credentials || return 1

	# Exchange refresh token for access token
	local access_token
	access_token=$(exchange_token "$CWS_CLIENT_ID" "$CWS_CLIENT_SECRET" "$CWS_REFRESH_TOKEN") || return 1

	# Fetch status
	local status_url="${CWS_API_BASE}/v2/publishers/${CWS_PUBLISHER_ID}/items/${CWS_EXTENSION_ID}:fetchStatus"
	local response
	response=$(curl -s -X GET "$status_url" \
		-H "Authorization: Bearer $access_token")

	if [[ -z "$response" ]]; then
		print_error "$ERROR_STATUS_FAILED"
		return 1
	fi

	# Extract published version
	local published_version
	published_version=$(echo "$response" | jq -r '.publishedItemRevisionStatus.distributionChannels[0].crxVersion // "unknown"')

	local published_state
	published_state=$(echo "$response" | jq -r '.publishedItemRevisionStatus.distributionChannels[0].state // "unknown"')

	# Extract local version if manifest provided
	local local_version="unknown"
	if [[ -n "$manifest_path" && -f "$manifest_path" ]]; then
		local_version=$(jq -r '.version // "unknown"' "$manifest_path")
	fi

	# Determine if up to date
	local up_to_date=false
	if [[ "$local_version" == "$published_version" ]]; then
		up_to_date=true
	fi

	# Output
	if [[ "$json_output" == true ]]; then
		jq -n \
			--arg item_id "$CWS_EXTENSION_ID" \
			--arg local_version "$local_version" \
			--arg published_version "$published_version" \
			--arg published_state "$published_state" \
			--argjson up_to_date "$up_to_date" \
			'{
                itemId: $item_id,
                localVersion: $local_version,
                publishedVersion: $published_version,
                publishedState: $published_state,
                upToDate: $up_to_date
            }'
	else
		print_info "Chrome Web Store Status"
		print_info "======================="
		echo "Extension ID: $CWS_EXTENSION_ID"
		echo "Local Version: $local_version"
		echo "Published Version: $published_version"
		echo "Published State: $published_state"
		echo "Up to Date: $up_to_date"
	fi

	return 0
}

# ------------------------------------------------------------------------------
# PUBLISH COMMAND
# ------------------------------------------------------------------------------

cmd_publish() {
	local manifest_path=""
	local build_cmd=""
	local zip_cmd=""
	local output_path=""
	local dry_run=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--manifest)
			manifest_path="$2"
			shift 2
			;;
		--build)
			build_cmd="$2"
			shift 2
			;;
		--zip)
			zip_cmd="$2"
			shift 2
			;;
		--output)
			output_path="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$manifest_path" ]]; then
		print_error "$ERROR_MANIFEST_REQUIRED"
		return 1
	fi

	if [[ ! -f "$manifest_path" ]]; then
		print_error "$ERROR_MANIFEST_NOT_FOUND: $manifest_path"
		return 1
	fi

	check_dependencies || return 1
	load_credentials || return 1

	# Read local version
	local local_version
	local_version=$(jq -r '.version // empty' "$manifest_path")

	if [[ -z "$local_version" ]]; then
		print_error "Failed to read version from manifest"
		return 1
	fi

	print_info "Local version: $local_version"

	# Exchange refresh token for access token
	local access_token
	access_token=$(exchange_token "$CWS_CLIENT_ID" "$CWS_CLIENT_SECRET" "$CWS_REFRESH_TOKEN") || return 1

	# Fetch current published version
	local status_url="${CWS_API_BASE}/v2/publishers/${CWS_PUBLISHER_ID}/items/${CWS_EXTENSION_ID}:fetchStatus"
	local response
	response=$(curl -s -X GET "$status_url" \
		-H "Authorization: Bearer $access_token")

	local published_version
	published_version=$(echo "$response" | jq -r '.publishedItemRevisionStatus.distributionChannels[0].crxVersion // "unknown"')

	print_info "Published version: $published_version"

	# Compare versions
	if [[ "$local_version" == "$published_version" ]]; then
		print_info "Local version matches published version. Skipping publish (no-op)."
		return 0
	fi

	print_info "Version changed. Proceeding with publish..."

	if [[ "$dry_run" == true ]]; then
		print_info "[DRY RUN] Would publish version $local_version"
		return 0
	fi

	# Build extension if build command provided
	if [[ -n "$build_cmd" ]]; then
		print_info "Running build command: $build_cmd"
		if ! bash -c "$build_cmd"; then
			print_error "$ERROR_BUILD_FAILED"
			return 1
		fi
	fi

	# Zip extension
	local zip_file="${output_path:-extension.zip}"

	if [[ -n "$zip_cmd" ]]; then
		print_info "Running zip command: $zip_cmd"
		if ! bash -c "$zip_cmd"; then
			print_error "$ERROR_ZIP_FAILED"
			return 1
		fi
	else
		# Default zip command (assumes dist/ directory)
		local manifest_dir
		manifest_dir=$(dirname "$manifest_path")
		print_info "Creating zip from $manifest_dir"
		if ! (cd "$manifest_dir" && zip -r "$zip_file" .); then
			print_error "$ERROR_ZIP_FAILED"
			return 1
		fi
	fi

	if [[ ! -f "$zip_file" ]]; then
		print_error "Zip file not found: $zip_file"
		return 1
	fi

	print_info "Uploading extension..."

	# Upload extension
	local upload_url="${CWS_API_BASE}/upload/v2/publishers/${CWS_PUBLISHER_ID}/items/${CWS_EXTENSION_ID}:upload"
	local upload_response
	upload_response=$(curl -s -X POST "$upload_url" \
		-H "Authorization: Bearer $access_token" \
		-H "Content-Type: application/zip" \
		--data-binary "@$zip_file")

	local upload_state
	upload_state=$(echo "$upload_response" | jq -r '.uploadState // empty')

	if [[ "$upload_state" != "SUCCESS" ]]; then
		print_error "$ERROR_UPLOAD_FAILED"
		print_error "Response: $upload_response"
		return 1
	fi

	print_success "$SUCCESS_UPLOAD_COMPLETE"

	# Publish extension
	print_info "Publishing extension..."

	local publish_url="${CWS_API_BASE}/v2/publishers/${CWS_PUBLISHER_ID}/items/${CWS_EXTENSION_ID}:publish"
	local publish_response
	publish_response=$(curl -s -X POST "$publish_url" \
		-H "Authorization: Bearer $access_token")

	local publish_state
	publish_state=$(echo "$publish_response" | jq -r '.status // empty')

	# Successful states
	case "$publish_state" in
	PENDING_REVIEW | PUBLISHED | PUBLISHED_TO_TESTERS | STAGED)
		print_success "$SUCCESS_PUBLISH_COMPLETE"
		print_info "Status: $publish_state"
		return 0
		;;
	*)
		print_error "$ERROR_PUBLISH_FAILED"
		print_error "Response: $publish_response"
		return 1
		;;
	esac
}

# ------------------------------------------------------------------------------
# UPLOAD SECRETS COMMAND
# ------------------------------------------------------------------------------

cmd_upload_secrets() {
	local dry_run=false
	local repo=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--repo)
			repo="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Check gh CLI
	if ! command -v gh &>/dev/null; then
		print_error "$ERROR_GH_NOT_INSTALLED"
		print_info "Install GitHub CLI: https://cli.github.com/"
		return 1
	fi

	if ! gh auth status &>/dev/null; then
		print_error "$ERROR_GH_NOT_AUTHENTICATED"
		print_info "Authenticate with: gh auth login"
		return 1
	fi

	load_credentials || return 1

	# Determine repo
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
		if [[ -z "$repo" ]]; then
			print_error "Failed to determine repository. Use --repo owner/repo"
			return 1
		fi
	fi

	print_info "Uploading secrets to repository: $repo"

	if [[ "$dry_run" == true ]]; then
		print_info "[DRY RUN] Would upload the following secrets:"
		for key in "${REQUIRED_CREDENTIALS[@]}"; do
			print_info "  $key: ***MASKED***"
		done
		return 0
	fi

	# Upload secrets
	for key in "${REQUIRED_CREDENTIALS[@]}"; do
		local value="${!key}"
		print_info "Uploading $key..."
		if ! echo "$value" | gh secret set "$key" --repo "$repo"; then
			print_error "Failed to upload $key"
			return 1
		fi
	done

	print_success "$SUCCESS_SECRETS_UPLOADED"
	return 0
}

# ------------------------------------------------------------------------------
# HELP COMMAND
# ------------------------------------------------------------------------------

cmd_help() {
	cat <<EOF
Chrome Web Store Helper Script

Usage: chrome-webstore-helper.sh [command] [options]

Commands:
  setup              Interactive credential setup wizard
  publish            Build, zip, upload, and publish extension
  status             Fetch submission status
  upload-secrets     Upload secrets to GitHub via gh CLI
  help               Show this help message

Options (publish):
  --manifest PATH    Path to manifest.json (required)
  --build CMD        Build command to run before packaging
  --zip CMD          Zip command to create package
  --output PATH      Output path for zip file (default: extension.zip)
  --dry-run          Preview actions without executing

Options (status):
  --manifest PATH    Path to manifest.json for version comparison
  --json             Output in JSON format

Options (upload-secrets):
  --repo OWNER/REPO  Target repository (default: current repo)
  --dry-run          Preview actions without uploading

Examples:
  # Interactive setup
  chrome-webstore-helper.sh setup

  # Publish extension
  chrome-webstore-helper.sh publish --manifest src/manifest.json --build "npm run build"

  # Check status
  chrome-webstore-helper.sh status --manifest src/manifest.json

  # Upload secrets to GitHub
  chrome-webstore-helper.sh upload-secrets --repo owner/repo

Environment Variables:
  CWS_CLIENT_ID       OAuth client ID
  CWS_CLIENT_SECRET   OAuth client secret
  CWS_REFRESH_TOKEN   OAuth refresh token
  CWS_PUBLISHER_ID    Chrome Web Store publisher ID
  CWS_EXTENSION_ID    Chrome Web Store extension ID

Credentials can be stored via:
  - aidevops secret storage (encrypted, recommended)
  - .env file (plaintext, ensure gitignored)

For more information, see:
  .agents/tools/browser/chrome-webstore-release.md
EOF
	return 0
}

# ------------------------------------------------------------------------------
# MAIN COMMAND DISPATCHER
# ------------------------------------------------------------------------------

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	setup)
		cmd_setup "$@"
		;;
	publish)
		cmd_publish "$@"
		;;
	status)
		cmd_status "$@"
		;;
	upload-secrets)
		cmd_upload_secrets "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
