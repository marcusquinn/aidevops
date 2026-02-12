#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

# Enhancor Helper - REST API client for Enhancor AI
# Part of AI DevOps Framework
# Portrait and image enhancement API with skin refinement, upscaling, and AI generation

set -euo pipefail

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Constants
readonly ENHANCOR_API_BASE="https://apireq.enhancor.ai/api"
readonly DEFAULT_POLL_INTERVAL=5
readonly DEFAULT_TIMEOUT=600
readonly DEFAULT_MODEL_VERSION="enhancorv3"
readonly DEFAULT_ENHANCEMENT_MODE="standard"
readonly DEFAULT_ENHANCEMENT_TYPE="face"

# Print helpers (fallback if shared-constants not loaded)
if ! command -v print_info &>/dev/null; then
	print_info() { echo "[INFO] $*"; }
	print_success() { echo "[OK] $*"; }
	print_error() { echo "[ERROR] $*" >&2; }
	print_warning() { echo "[WARN] $*"; }
fi

# Load API key from credentials
load_api_key() {
	if [[ -n "${ENHANCOR_API_KEY:-}" ]]; then
		return 0
	fi

	local cred_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "${cred_file}" ]]; then
		source "${cred_file}"
	fi

	# Try gopass
	if [[ -z "${ENHANCOR_API_KEY:-}" ]] && command -v gopass &>/dev/null; then
		ENHANCOR_API_KEY="$(gopass show -o "aidevops/ENHANCOR_API_KEY" 2>/dev/null)" || true
	fi

	if [[ -z "${ENHANCOR_API_KEY:-}" ]]; then
		print_error "ENHANCOR_API_KEY not set"
		print_info "Run: aidevops secret set ENHANCOR_API_KEY"
		print_info "Or add to ~/.config/aidevops/credentials.sh"
		return 1
	fi

	export ENHANCOR_API_KEY
	return 0
}

# Make authenticated API request
api_request() {
	local method="$1"
	local endpoint="$2"
	shift 2

	curl -s -X "${method}" \
		"${ENHANCOR_API_BASE}${endpoint}" \
		-H "x-api-key: ${ENHANCOR_API_KEY}" \
		-H "Content-Type: application/json" \
		"$@"
}

# Download result file
download_result() {
	local url="$1"
	local output_file="$2"

	if [[ -z "${output_file}" ]]; then
		print_info "Result URL: ${url}"
		return 0
	fi

	print_info "Downloading result to ${output_file}..."
	if curl -sL -o "${output_file}" "${url}"; then
		print_success "Downloaded: ${output_file}"
		return 0
	else
		print_error "Failed to download result"
		return 1
	fi
}

# Poll for request status
poll_status() {
	local api_path="$1"
	local request_id="$2"
	local poll_interval="${3:-${DEFAULT_POLL_INTERVAL}}"
	local timeout="${4:-${DEFAULT_TIMEOUT}}"
	local output_file="${5:-}"

	local elapsed=0
	local status=""

	print_info "Polling status for request: ${request_id}"

	while [[ ${elapsed} -lt ${timeout} ]]; do
		local response
		response=$(api_request POST "${api_path}/status" -d "{\"request_id\": \"${request_id}\"}")

		status=$(echo "${response}" | jq -r '.status // empty' 2>/dev/null)

		case "${status}" in
		COMPLETED)
			print_success "Request completed"
			local result_url
			result_url=$(echo "${response}" | jq -r '.result // empty' 2>/dev/null)
			if [[ -n "${result_url}" ]]; then
				download_result "${result_url}" "${output_file}"
			fi
			echo "${response}" | jq . 2>/dev/null || echo "${response}"
			return 0
			;;
		FAILED)
			print_error "Request failed"
			echo "${response}" | jq . 2>/dev/null || echo "${response}"
			return 1
			;;
		PENDING | IN_QUEUE | IN_PROGRESS)
			print_info "Status: ${status} (${elapsed}s elapsed)"
			sleep "${poll_interval}"
			elapsed=$((elapsed + poll_interval))
			;;
		*)
			print_error "Unknown status: ${status}"
			echo "${response}" | jq . 2>/dev/null || echo "${response}"
			return 1
			;;
		esac
	done

	print_error "Timeout after ${timeout}s"
	return 1
}

# Realistic Skin Enhancement
cmd_enhance() {
	local img_url=""
	local webhook_url=""
	local model_version="${DEFAULT_MODEL_VERSION}"
	local enhancement_mode="${DEFAULT_ENHANCEMENT_MODE}"
	local enhancement_type="${DEFAULT_ENHANCEMENT_TYPE}"
	local skin_refinement_level=0
	local skin_realism_level=""
	local portrait_depth=""
	local output_resolution=""
	local mask_image_url=""
	local mask_expand=15
	local sync_mode="false"
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local extra_params=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--img-url | -i)
			img_url="$2"
			shift 2
			;;
		--webhook)
			webhook_url="$2"
			shift 2
			;;
		--model)
			model_version="$2"
			shift 2
			;;
		--mode)
			enhancement_mode="$2"
			shift 2
			;;
		--type)
			enhancement_type="$2"
			shift 2
			;;
		--skin-refinement)
			skin_refinement_level="$2"
			shift 2
			;;
		--skin-realism)
			skin_realism_level="$2"
			shift 2
			;;
		--portrait-depth)
			portrait_depth="$2"
			shift 2
			;;
		--resolution)
			output_resolution="$2"
			shift 2
			;;
		--mask-url)
			mask_image_url="$2"
			shift 2
			;;
		--mask-expand)
			mask_expand="$2"
			shift 2
			;;
		--sync)
			sync_mode="true"
			shift
			;;
		--poll)
			poll_interval="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--output | -o)
			output_file="$2"
			shift 2
			;;
		--area-*)
			local area="${1#--area-}"
			extra_params="${extra_params}, \"${area}\": true"
			shift
			;;
		--*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			print_error "Unexpected argument: $1"
			return 1
			;;
		esac
	done

	if [[ -z "${img_url}" ]]; then
		print_error "Image URL is required"
		print_info "Usage: enhancor-helper.sh enhance --img-url URL [options]"
		return 1
	fi

	load_api_key || return 1

	# Build request body
	local body="{\"img_url\": \"${img_url}\""

	if [[ -n "${webhook_url}" ]]; then
		body="${body}, \"webhookUrl\": \"${webhook_url}\""
	fi

	body="${body}, \"model_version\": \"${model_version}\""
	body="${body}, \"enhancementMode\": \"${enhancement_mode}\""
	body="${body}, \"enhancementType\": \"${enhancement_type}\""
	body="${body}, \"skin_refinement_level\": ${skin_refinement_level}"

	if [[ -n "${skin_realism_level}" ]]; then
		body="${body}, \"skin_realism_Level\": ${skin_realism_level}"
	fi

	if [[ -n "${portrait_depth}" ]]; then
		body="${body}, \"portrait_depth\": ${portrait_depth}"
	fi

	if [[ -n "${output_resolution}" ]]; then
		body="${body}, \"output_resolution\": ${output_resolution}"
	fi

	if [[ -n "${mask_image_url}" ]]; then
		body="${body}, \"mask_image_url\": \"${mask_image_url}\""
	fi

	body="${body}, \"mask_expand\": ${mask_expand}"

	if [[ -n "${extra_params}" ]]; then
		body="${body}${extra_params}"
	fi

	body="${body}}"

	print_info "Submitting skin enhancement request..."

	local response
	response=$(api_request POST "/realistic-skin/v1/queue" -d "${body}")

	# Check for errors
	local error
	error=$(echo "${response}" | jq -r '.error // empty' 2>/dev/null)
	if [[ -n "${error}" ]]; then
		print_error "API error: ${error}"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	local request_id
	request_id=$(echo "${response}" | jq -r '.requestId // empty' 2>/dev/null)

	if [[ -z "${request_id}" ]]; then
		print_error "No request ID returned"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	print_success "Request queued: ${request_id}"

	if [[ "${sync_mode}" == "true" ]]; then
		poll_status "/realistic-skin/v1" "${request_id}" "${poll_interval}" "${timeout}" "${output_file}"
	else
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
	fi
}

# Portrait Upscaler
cmd_upscale() {
	local img_url=""
	local webhook_url=""
	local mode="fast"
	local sync_mode="false"
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--img-url | -i)
			img_url="$2"
			shift 2
			;;
		--webhook)
			webhook_url="$2"
			shift 2
			;;
		--mode)
			mode="$2"
			shift 2
			;;
		--sync)
			sync_mode="true"
			shift
			;;
		--poll)
			poll_interval="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--output | -o)
			output_file="$2"
			shift 2
			;;
		--*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			print_error "Unexpected argument: $1"
			return 1
			;;
		esac
	done

	if [[ -z "${img_url}" ]]; then
		print_error "Image URL is required"
		print_info "Usage: enhancor-helper.sh upscale --img-url URL [--mode fast|professional]"
		return 1
	fi

	load_api_key || return 1

	local body="{\"img_url\": \"${img_url}\", \"mode\": \"${mode}\""

	if [[ -n "${webhook_url}" ]]; then
		body="${body}, \"webhookUrl\": \"${webhook_url}\""
	fi

	body="${body}}"

	print_info "Submitting upscale request (${mode} mode)..."

	local response
	response=$(api_request POST "/upscaler/v1/queue" -d "${body}")

	local error
	error=$(echo "${response}" | jq -r '.error // empty' 2>/dev/null)
	if [[ -n "${error}" ]]; then
		print_error "API error: ${error}"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	local request_id
	request_id=$(echo "${response}" | jq -r '.requestId // empty' 2>/dev/null)

	if [[ -z "${request_id}" ]]; then
		print_error "No request ID returned"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	print_success "Request queued: ${request_id}"

	if [[ "${sync_mode}" == "true" ]]; then
		poll_status "/upscaler/v1" "${request_id}" "${poll_interval}" "${timeout}" "${output_file}"
	else
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
	fi
}

# General Image Upscaler
cmd_upscale_general() {
	local img_url=""
	local webhook_url=""
	local sync_mode="false"
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--img-url | -i)
			img_url="$2"
			shift 2
			;;
		--webhook)
			webhook_url="$2"
			shift 2
			;;
		--sync)
			sync_mode="true"
			shift
			;;
		--poll)
			poll_interval="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--output | -o)
			output_file="$2"
			shift 2
			;;
		--*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			print_error "Unexpected argument: $1"
			return 1
			;;
		esac
	done

	if [[ -z "${img_url}" ]]; then
		print_error "Image URL is required"
		print_info "Usage: enhancor-helper.sh upscale-general --img-url URL"
		return 1
	fi

	load_api_key || return 1

	local body="{\"img_url\": \"${img_url}\""

	if [[ -n "${webhook_url}" ]]; then
		body="${body}, \"webhookUrl\": \"${webhook_url}\""
	fi

	body="${body}}"

	print_info "Submitting general upscale request..."

	local response
	response=$(api_request POST "/general-upscaler/v1/queue" -d "${body}")

	local error
	error=$(echo "${response}" | jq -r '.error // empty' 2>/dev/null)
	if [[ -n "${error}" ]]; then
		print_error "API error: ${error}"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	local request_id
	request_id=$(echo "${response}" | jq -r '.requestId // empty' 2>/dev/null)

	if [[ -z "${request_id}" ]]; then
		print_error "No request ID returned"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	print_success "Request queued: ${request_id}"

	if [[ "${sync_mode}" == "true" ]]; then
		poll_status "/general-upscaler/v1" "${request_id}" "${poll_interval}" "${timeout}" "${output_file}"
	else
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
	fi
}

# Detailed API (upscaling + detailed enhancement)
cmd_detailed() {
	local img_url=""
	local webhook_url=""
	local sync_mode="false"
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--img-url | -i)
			img_url="$2"
			shift 2
			;;
		--webhook)
			webhook_url="$2"
			shift 2
			;;
		--sync)
			sync_mode="true"
			shift
			;;
		--poll)
			poll_interval="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--output | -o)
			output_file="$2"
			shift 2
			;;
		--*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			print_error "Unexpected argument: $1"
			return 1
			;;
		esac
	done

	if [[ -z "${img_url}" ]]; then
		print_error "Image URL is required"
		print_info "Usage: enhancor-helper.sh detailed --img-url URL"
		return 1
	fi

	load_api_key || return 1

	local body="{\"img_url\": \"${img_url}\""

	if [[ -n "${webhook_url}" ]]; then
		body="${body}, \"webhookUrl\": \"${webhook_url}\""
	fi

	body="${body}}"

	print_info "Submitting detailed enhancement request..."

	local response
	response=$(api_request POST "/detailed/v1/queue" -d "${body}")

	local error
	error=$(echo "${response}" | jq -r '.error // empty' 2>/dev/null)
	if [[ -n "${error}" ]]; then
		print_error "API error: ${error}"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	local request_id
	request_id=$(echo "${response}" | jq -r '.requestId // empty' 2>/dev/null)

	if [[ -z "${request_id}" ]]; then
		print_error "No request ID returned"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	print_success "Request queued: ${request_id}"

	if [[ "${sync_mode}" == "true" ]]; then
		poll_status "/detailed/v1" "${request_id}" "${poll_interval}" "${timeout}" "${output_file}"
	else
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
	fi
}

# Kora Pro AI Image Generation
cmd_generate() {
	local model="kora_pro"
	local prompt=""
	local img_url=""
	local webhook_url=""
	local generation_mode="normal"
	local image_size="portrait_3:4"
	local sync_mode="false"
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			model="$2"
			shift 2
			;;
		--prompt | -p)
			prompt="$2"
			shift 2
			;;
		--img-url | -i)
			img_url="$2"
			shift 2
			;;
		--webhook)
			webhook_url="$2"
			shift 2
			;;
		--generation-mode)
			generation_mode="$2"
			shift 2
			;;
		--size)
			image_size="$2"
			shift 2
			;;
		--sync)
			sync_mode="true"
			shift
			;;
		--poll)
			poll_interval="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--output | -o)
			output_file="$2"
			shift 2
			;;
		--*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "${prompt}" ]]; then
				prompt="$1"
			else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -z "${prompt}" ]]; then
		print_error "Prompt is required"
		print_info "Usage: enhancor-helper.sh generate \"your prompt\" [options]"
		return 1
	fi

	load_api_key || return 1

	local body="{\"model\": \"${model}\", \"prompt\": \"${prompt}\""

	if [[ -n "${img_url}" ]]; then
		body="${body}, \"img_url\": \"${img_url}\""
	fi

	if [[ -n "${webhook_url}" ]]; then
		body="${body}, \"webhookUrl\": \"${webhook_url}\""
	fi

	body="${body}, \"generation_mode\": \"${generation_mode}\""
	body="${body}, \"image_size\": \"${image_size}\""
	body="${body}}"

	print_info "Submitting generation request (${model})..."

	local response
	response=$(api_request POST "/kora/v1/queue" -d "${body}")

	local error
	error=$(echo "${response}" | jq -r '.error // empty' 2>/dev/null)
	if [[ -n "${error}" ]]; then
		print_error "API error: ${error}"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	local request_id
	request_id=$(echo "${response}" | jq -r '.requestId // empty' 2>/dev/null)

	if [[ -z "${request_id}" ]]; then
		print_error "No request ID returned"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	print_success "Request queued: ${request_id}"

	if [[ "${sync_mode}" == "true" ]]; then
		poll_status "/kora/v1" "${request_id}" "${poll_interval}" "${timeout}" "${output_file}"
	else
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
	fi
}

# Check status of any request
cmd_status() {
	local api_path=""
	local request_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--api)
			api_path="$2"
			shift 2
			;;
		--id)
			request_id="$2"
			shift 2
			;;
		--*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "${request_id}" ]]; then
				request_id="$1"
			else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -z "${request_id}" ]]; then
		print_error "Request ID is required"
		print_info "Usage: enhancor-helper.sh status REQUEST_ID [--api /path/to/api]"
		return 1
	fi

	if [[ -z "${api_path}" ]]; then
		print_error "API path is required (e.g., /realistic-skin/v1, /upscaler/v1, /kora/v1)"
		print_info "Usage: enhancor-helper.sh status REQUEST_ID --api /realistic-skin/v1"
		return 1
	fi

	load_api_key || return 1

	local response
	response=$(api_request POST "${api_path}/status" -d "{\"request_id\": \"${request_id}\"}")

	echo "${response}" | jq . 2>/dev/null || echo "${response}"
}

# Batch processing
cmd_batch() {
	local command=""
	local input_file=""
	local output_dir="."
	local extra_args=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--command | -c)
			command="$2"
			shift 2
			;;
		--input | -i)
			input_file="$2"
			shift 2
			;;
		--output-dir)
			output_dir="$2"
			shift 2
			;;
		*)
			extra_args+=("$1")
			shift
			;;
		esac
	done

	if [[ -z "${command}" ]] || [[ -z "${input_file}" ]]; then
		print_error "Command and input file are required"
		print_info "Usage: enhancor-helper.sh batch --command enhance --input urls.txt [options]"
		return 1
	fi

	if [[ ! -f "${input_file}" ]]; then
		print_error "Input file not found: ${input_file}"
		return 1
	fi

	mkdir -p "${output_dir}"

	local line_num=0
	while IFS= read -r url; do
		[[ -z "${url}" ]] && continue
		[[ "${url}" =~ ^# ]] && continue

		line_num=$((line_num + 1))
		local output_file="${output_dir}/result_${line_num}.png"

		print_info "Processing ${line_num}: ${url}"

		if "${BASH_SOURCE[0]}" "${command}" --img-url "${url}" --sync --output "${output_file}" "${extra_args[@]}"; then
			print_success "Completed ${line_num}"
		else
			print_error "Failed ${line_num}"
		fi
	done <"${input_file}"

	print_success "Batch processing complete"
}

# Setup API key
cmd_setup() {
	print_info "Setting up Enhancor API key..."
	print_info "Get your API key from: https://www.enhancor.ai/"
	print_info ""
	print_info "Run: aidevops secret set ENHANCOR_API_KEY"
	print_info "Or add to ~/.config/aidevops/credentials.sh:"
	print_info "  export ENHANCOR_API_KEY='your_key_here'"
}

# Help
cmd_help() {
	cat <<EOF
Enhancor Helper - REST API client for Enhancor AI

USAGE:
    enhancor-helper.sh <command> [options]

COMMANDS:
    enhance             Realistic skin enhancement with granular control
    upscale             Portrait upscaler (fast/professional modes)
    upscale-general     General image upscaler for all image types
    detailed            Detailed API (upscaling + enhancement)
    generate            Kora Pro AI image generation from text prompts
    status              Check request status
    batch               Batch process multiple images
    setup               Setup API key
    help                Show this help message

ENHANCE OPTIONS:
    --img-url, -i URL           Image URL (required)
    --webhook URL               Webhook URL for completion notification
    --model VERSION             Model version: enhancorv1, enhancorv3 (default: enhancorv3)
    --mode MODE                 Enhancement mode: standard, heavy (default: standard)
    --type TYPE                 Enhancement type: face, body (default: face)
    --skin-refinement LEVEL     Skin refinement level 0-100 (default: 0)
    --skin-realism LEVEL        Skin realism level (v1: 0-5, v3: 0-3)
    --portrait-depth DEPTH      Portrait depth 0.2-0.4 (v3 or v1 heavy mode)
    --resolution SIZE           Output resolution 1024-3072 (v3 only)
    --mask-url URL              Mask image URL (v3 only)
    --mask-expand AMOUNT        Mask expansion -20 to 20 (default: 15, v3 only)
    --area-PART                 Keep area unchanged (background, skin, nose, eye_g, etc.)
    --sync                      Wait for completion and download result
    --output, -o FILE           Output file path (requires --sync)

UPSCALE OPTIONS:
    --img-url, -i URL           Image URL (required)
    --webhook URL               Webhook URL for completion notification
    --mode MODE                 Processing mode: fast, professional (default: fast)
    --sync                      Wait for completion and download result
    --output, -o FILE           Output file path (requires --sync)

UPSCALE-GENERAL OPTIONS:
    --img-url, -i URL           Image URL (required)
    --webhook URL               Webhook URL for completion notification
    --sync                      Wait for completion and download result
    --output, -o FILE           Output file path (requires --sync)

DETAILED OPTIONS:
    --img-url, -i URL           Image URL (required)
    --webhook URL               Webhook URL for completion notification
    --sync                      Wait for completion and download result
    --output, -o FILE           Output file path (requires --sync)

GENERATE OPTIONS:
    --prompt, -p TEXT           Text prompt (required)
    --model MODEL               Model: kora_pro, kora_pro_cinema (default: kora_pro)
    --img-url, -i URL           Reference image URL (for image-to-image)
    --webhook URL               Webhook URL for completion notification
    --generation-mode MODE      Quality: normal, 2k_pro, 4k_ultra (default: normal)
    --size SIZE                 Image size: portrait_3:4, portrait_9:16, square,
                                landscape_4:3, landscape_16:9, custom_WIDTH_HEIGHT
    --sync                      Wait for completion and download result
    --output, -o FILE           Output file path (requires --sync)

STATUS OPTIONS:
    --id ID                     Request ID (required)
    --api PATH                  API path (e.g., /realistic-skin/v1, /upscaler/v1)

BATCH OPTIONS:
    --command, -c CMD           Command to run (enhance, upscale, etc.)
    --input, -i FILE            Input file with URLs (one per line)
    --output-dir DIR            Output directory (default: current directory)
    [additional options]        Pass through to command

EXAMPLES:
    # Skin enhancement with v3 model
    enhancor-helper.sh enhance --img-url https://example.com/portrait.jpg \\
        --model enhancorv3 --skin-refinement 50 --resolution 2048 --sync -o result.png

    # Portrait upscale (professional mode)
    enhancor-helper.sh upscale --img-url https://example.com/portrait.jpg \\
        --mode professional --sync -o upscaled.png

    # General image upscale
    enhancor-helper.sh upscale-general --img-url https://example.com/image.jpg \\
        --sync -o upscaled.png

    # AI image generation
    enhancor-helper.sh generate "A serene mountain landscape at sunset" \\
        --model kora_pro_cinema --generation-mode 4k_ultra --size landscape_16:9 \\
        --sync -o generated.png

    # Check status
    enhancor-helper.sh status REQUEST_ID --api /realistic-skin/v1

    # Batch processing
    enhancor-helper.sh batch --command enhance --input urls.txt \\
        --output-dir results/ --model enhancorv3 --skin-refinement 50

ENVIRONMENT:
    ENHANCOR_API_KEY            API key for authentication

For more information, see: https://www.enhancor.ai/
EOF
}

# Main
main() {
	if [[ $# -eq 0 ]]; then
		cmd_help
		return 0
	fi

	local command="$1"
	shift

	case "${command}" in
	enhance) cmd_enhance "$@" ;;
	upscale) cmd_upscale "$@" ;;
	upscale-general) cmd_upscale_general "$@" ;;
	detailed) cmd_detailed "$@" ;;
	generate) cmd_generate "$@" ;;
	status) cmd_status "$@" ;;
	batch) cmd_batch "$@" ;;
	setup) cmd_setup ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		print_info "Run 'enhancor-helper.sh help' for usage"
		return 1
		;;
	esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
