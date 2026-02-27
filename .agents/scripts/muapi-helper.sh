#!/usr/bin/env bash

# MuAPI Helper - REST API client for MuAPI (muapi.ai)
# Part of AI DevOps Framework
# Multimodal AI API for image, video, audio, VFX, workflows, and agents

set -euo pipefail

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Constants
readonly MUAPI_BASE="https://api.muapi.ai/api/v1"
readonly MUAPI_AGENTS_BASE="https://api.muapi.ai/agents"
readonly DEFAULT_POLL_INTERVAL=2
readonly DEFAULT_TIMEOUT=300

# Print helpers (fallback if shared-constants not loaded)
if ! command -v print_info &>/dev/null; then
	print_info() { echo "[INFO] $*"; }
	print_success() { echo "[OK] $*"; }
	print_error() { echo "[ERROR] $*" >&2; }
	print_warning() { echo "[WARN] $*"; }
fi

# Load API key from credentials
load_api_key() {
	if [[ -n "${MUAPI_API_KEY:-}" ]]; then
		return 0
	fi

	local cred_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "${cred_file}" ]]; then
		# shellcheck disable=SC1090  # credentials path resolved at runtime
		source "${cred_file}"
	fi

	# Try gopass
	if [[ -z "${MUAPI_API_KEY:-}" ]] && command -v gopass &>/dev/null; then
		MUAPI_API_KEY="$(gopass show -o "aidevops/MUAPI_API_KEY" 2>/dev/null)" || true
	fi

	if [[ -z "${MUAPI_API_KEY:-}" ]]; then
		print_error "MUAPI_API_KEY not set"
		print_info "Run: aidevops secret set MUAPI_API_KEY"
		print_info "Or add to ~/.config/aidevops/credentials.sh"
		return 1
	fi

	export MUAPI_API_KEY
	return 0
}

# Make authenticated API request to main API
api_request() {
	local method="$1"
	local url="$2"
	shift 2

	curl -s -X "${method}" \
		"${url}" \
		-H "x-api-key: ${MUAPI_API_KEY}" \
		-H "Content-Type: application/json" \
		"$@"
}

# Poll task until completion
poll_task() {
	local request_id="$1"
	local interval="${2:-${DEFAULT_POLL_INTERVAL}}"
	local timeout="${3:-${DEFAULT_TIMEOUT}}"
	local output_file="${4:-}"
	local elapsed=0

	while [[ "${elapsed}" -lt "${timeout}" ]]; do
		local response
		response=$(api_request GET "${MUAPI_BASE}/predictions/${request_id}/result")

		local status
		status=$(echo "${response}" | jq -r '.data.status // .status // "unknown"' 2>/dev/null)

		case "${status}" in
		completed)
			print_success "Task complete (${elapsed}s)"
			# Extract output URLs
			local outputs
			outputs=$(echo "${response}" | jq -r '.data.outputs[]? // .outputs[]? // empty' 2>/dev/null)
			if [[ -n "${outputs}" ]]; then
				echo "${outputs}"
			else
				echo "${response}" | jq . 2>/dev/null || echo "${response}"
			fi
			save_output "${response}" "${output_file}"
			return 0
			;;
		failed)
			print_error "Task failed"
			local error_msg
			error_msg=$(echo "${response}" | jq -r '.data.error // .error // "unknown error"' 2>/dev/null)
			print_error "${error_msg}"
			return 1
			;;
		processing | created | pending)
			printf "\r[INFO] Status: %s (%ds/%ds)" "${status}" "${elapsed}" "${timeout}"
			sleep "${interval}"
			elapsed=$((elapsed + interval))
			;;
		*)
			print_warning "Unknown status: ${status}"
			sleep "${interval}"
			elapsed=$((elapsed + interval))
			;;
		esac
	done

	echo ""
	print_error "Timeout after ${timeout}s. Task ${request_id} still ${status:-unknown}"
	print_info "Check later: muapi-helper.sh status ${request_id}"
	return 1
}

# Save output to file
save_output() {
	local response="$1"
	local output_file="$2"

	if [[ -z "${output_file}" ]]; then
		return 0
	fi

	mkdir -p "$(dirname "${output_file}")"
	echo "${response}" | jq . >"${output_file}"
	print_info "Response saved to: ${output_file}"
	return 0
}

# Submit and optionally poll a generation task
submit_and_poll() {
	local endpoint="$1"
	local payload="$2"
	local poll_interval="${3:-${DEFAULT_POLL_INTERVAL}}"
	local timeout="${4:-${DEFAULT_TIMEOUT}}"
	local output_file="${5:-}"
	local webhook="${6:-}"

	load_api_key || return 1

	local url="${MUAPI_BASE}/${endpoint}"
	if [[ -n "${webhook}" ]]; then
		url="${url}?webhook=${webhook}"
	fi

	print_info "Submitting to ${endpoint}..."

	local response
	response=$(api_request POST "${url}" -d "${payload}")

	# Check for errors
	local error
	error=$(echo "${response}" | jq -r '.error // empty' 2>/dev/null)
	if [[ -n "${error}" ]]; then
		print_error "API error: ${error}"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	# Extract request_id
	local request_id
	request_id=$(echo "${response}" | jq -r '.data.request_id // .data.id // .id // empty' 2>/dev/null)

	if [[ -z "${request_id}" ]]; then
		# Might be a sync response or immediate result
		local status
		status=$(echo "${response}" | jq -r '.data.status // .status // empty' 2>/dev/null)
		if [[ "${status}" == "completed" ]]; then
			print_success "Task complete"
			echo "${response}" | jq -r '.data.outputs[]? // .outputs[]? // empty' 2>/dev/null
			save_output "${response}" "${output_file}"
			return 0
		fi
		print_error "No request_id in response"
		echo "${response}" | jq . 2>/dev/null || echo "${response}"
		return 1
	fi

	print_info "Request ID: ${request_id}"

	if [[ -n "${webhook}" ]]; then
		print_info "Webhook configured — results will be sent to: ${webhook}"
		echo "${request_id}"
		return 0
	fi

	poll_task "${request_id}" "${poll_interval}" "${timeout}" "${output_file}"
}

# --- Commands ---

# Flux Dev image generation
cmd_flux() {
	local prompt=""
	local image=""
	local mask_image=""
	local size="1024*1024"
	local steps=28
	local seed=-1
	local guidance=3.5
	local num_images=1
	local strength=0.8
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image="$2"
			shift 2
			;;
		--mask)
			mask_image="$2"
			shift 2
			;;
		--size)
			size="$2"
			shift 2
			;;
		--steps)
			steps="$2"
			shift 2
			;;
		--seed)
			seed="$2"
			shift 2
			;;
		--guidance)
			guidance="$2"
			shift 2
			;;
		--num)
			num_images="$2"
			shift 2
			;;
		--strength)
			strength="$2"
			shift 2
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
		--webhook)
			webhook="$2"
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
		print_info "Usage: muapi-helper.sh flux \"your prompt\" [--size 1024*1024] [--steps 28]"
		return 1
	fi

	local payload
	payload=$(jq -n \
		--arg prompt "${prompt}" \
		--arg image "${image}" \
		--arg mask "${mask_image}" \
		--arg size "${size}" \
		--argjson steps "${steps}" \
		--argjson seed "${seed}" \
		--argjson guidance "${guidance}" \
		--argjson num "${num_images}" \
		--argjson strength "${strength}" \
		'{
            prompt: $prompt,
            size: $size,
            num_inference_steps: $steps,
            seed: $seed,
            guidance_scale: $guidance,
            num_images: $num
        }
        + (if $image != "" then {image: $image, strength: $strength} else {} end)
        + (if $mask != "" then {mask_image: $mask} else {} end)')

	submit_and_poll "flux-dev-image" "${payload}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# AI Video Effects / VFX / Motion Controls (shared endpoint)
cmd_effects() {
	local prompt=""
	local image_url=""
	local effect_name=""
	local aspect_ratio="16:9"
	local resolution="480p"
	local quality="medium"
	local duration=5
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image_url="$2"
			shift 2
			;;
		--effect)
			effect_name="$2"
			shift 2
			;;
		--ratio)
			aspect_ratio="$2"
			shift 2
			;;
		--resolution)
			resolution="$2"
			shift 2
			;;
		--quality)
			quality="$2"
			shift 2
			;;
		--duration)
			duration="$2"
			shift 2
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
		--webhook)
			webhook="$2"
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
		print_info "Usage: muapi-helper.sh video-effects \"prompt\" --image URL --effect \"Effect Name\""
		return 1
	fi

	if [[ -z "${image_url}" ]]; then
		print_error "Image URL is required (--image)"
		return 1
	fi

	if [[ -z "${effect_name}" ]]; then
		print_error "Effect name is required (--effect)"
		return 1
	fi

	local payload
	payload=$(jq -n \
		--arg prompt "${prompt}" \
		--arg image_url "${image_url}" \
		--arg name "${effect_name}" \
		--arg aspect_ratio "${aspect_ratio}" \
		--arg resolution "${resolution}" \
		--arg quality "${quality}" \
		--argjson duration "${duration}" \
		'{
            prompt: $prompt,
            image_url: $image_url,
            name: $name,
            aspect_ratio: $aspect_ratio,
            resolution: $resolution,
            quality: $quality,
            duration: $duration
        }')

	submit_and_poll "generate_wan_ai_effects" "${payload}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Music generation (Suno)
cmd_music() {
	local prompt=""
	local action="create"
	local audio_url=""
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remix)
			action="remix"
			shift
			;;
		--extend)
			action="extend"
			shift
			;;
		--audio)
			audio_url="$2"
			shift 2
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
		--webhook)
			webhook="$2"
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
		print_info "Usage: muapi-helper.sh music \"upbeat electronic track\" [--remix|--extend] [--audio URL]"
		return 1
	fi

	local endpoint
	case "${action}" in
	create) endpoint="suno-create-music" ;;
	remix) endpoint="suno-remix-music" ;;
	extend) endpoint="suno-extend-music" ;;
	*)
		print_error "Unknown action: ${action}"
		return 1
		;;
	esac

	local payload
	if [[ -n "${audio_url}" ]]; then
		payload=$(jq -n --arg prompt "${prompt}" --arg audio "${audio_url}" \
			'{prompt: $prompt, audio_url: $audio}')
	else
		payload=$(jq -n --arg prompt "${prompt}" '{prompt: $prompt}')
	fi

	submit_and_poll "${endpoint}" "${payload}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Lip-sync
cmd_lipsync() {
	local video_url=""
	local audio_url=""
	local model="sync-lipsync"
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--video)
			video_url="$2"
			shift 2
			;;
		--audio)
			audio_url="$2"
			shift 2
			;;
		--model)
			model="$2"
			shift 2
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
		--webhook)
			webhook="$2"
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

	if [[ -z "${video_url}" ]] || [[ -z "${audio_url}" ]]; then
		print_error "Both --video and --audio are required"
		print_info "Usage: muapi-helper.sh lipsync --video URL --audio URL [--model sync-lipsync]"
		return 1
	fi

	local endpoint
	case "${model}" in
	sync-lipsync | sync) endpoint="sync-lipsync" ;;
	latentsync | latent) endpoint="latentsync-video" ;;
	creatify) endpoint="creatify-lipsync" ;;
	veed) endpoint="veed-lipsync" ;;
	*)
		print_error "Unknown lipsync model: ${model}"
		return 1
		;;
	esac

	local payload
	payload=$(jq -n --arg video "${video_url}" --arg audio "${audio_url}" \
		'{video_url: $video, audio_url: $audio}')

	submit_and_poll "${endpoint}" "${payload}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Agent operations
cmd_agent_create() {
	local prompt="${1:-}"

	if [[ -z "${prompt}" ]]; then
		print_error "Prompt is required"
		print_info "Usage: muapi-helper.sh agent-create \"I want an agent that...\""
		return 1
	fi

	load_api_key || return 1

	local payload
	payload=$(jq -n --arg prompt "${prompt}" '{prompt: $prompt}')

	local response
	response=$(api_request POST "${MUAPI_AGENTS_BASE}/quick-create" -d "${payload}")

	echo "${response}" | jq . 2>/dev/null || echo "${response}"
	return 0
}

cmd_agent_chat() {
	local agent_id="${1:-}"
	local message="${2:-}"
	local conversation_id="${3:-}"

	if [[ -z "${agent_id}" ]] || [[ -z "${message}" ]]; then
		print_error "Agent ID and message are required"
		print_info "Usage: muapi-helper.sh agent-chat <agent-id> \"message\" [conversation-id]"
		return 1
	fi

	load_api_key || return 1

	local payload
	if [[ -n "${conversation_id}" ]]; then
		payload=$(jq -n --arg msg "${message}" --arg cid "${conversation_id}" \
			'{message: $msg, conversation_id: $cid}')
	else
		payload=$(jq -n --arg msg "${message}" '{message: $msg}')
	fi

	local response
	response=$(api_request POST "${MUAPI_AGENTS_BASE}/${agent_id}/chat" -d "${payload}")

	echo "${response}" | jq . 2>/dev/null || echo "${response}"
	return 0
}

cmd_agent_list() {
	load_api_key || return 1

	local response
	response=$(api_request GET "${MUAPI_AGENTS_BASE}/user/agents")

	echo "${response}" | jq . 2>/dev/null || echo "${response}"
	return 0
}

cmd_agent_skills() {
	load_api_key || return 1

	local response
	response=$(api_request GET "${MUAPI_AGENTS_BASE}/skills")

	echo "${response}" | jq . 2>/dev/null || echo "${response}"
	return 0
}

# --- Specialized Apps ---

# Generic specialized app submission (shared logic)
submit_specialized() {
	local endpoint="$1"
	local image_url="$2"
	shift 2
	local extra_payload="${1:-{}}"
	local poll_interval="${2:-${DEFAULT_POLL_INTERVAL}}"
	local timeout="${3:-${DEFAULT_TIMEOUT}}"
	local output_file="${4:-}"
	local webhook="${5:-}"

	if [[ -z "${image_url}" ]]; then
		print_error "Image URL is required (--image)"
		return 1
	fi

	local payload
	payload=$(echo "${extra_payload}" | jq --arg url "${image_url}" '. + {image_url: $url}')

	submit_and_poll "${endpoint}" "${payload}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Face swap (image or video)
cmd_face_swap() {
	local image_url=""
	local face_url=""
	local mode="image"
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image_url="$2"
			shift 2
			;;
		--face)
			face_url="$2"
			shift 2
			;;
		--video)
			image_url="$2"
			mode="video"
			shift 2
			;;
		--mode)
			mode="$2"
			shift 2
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
		--webhook)
			webhook="$2"
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

	if [[ -z "${image_url}" ]]; then
		print_error "Source URL is required (--image or --video)"
		print_info "Usage: muapi-helper.sh face-swap --image URL --face URL [--mode image|video]"
		return 1
	fi

	if [[ -z "${face_url}" ]]; then
		print_error "Face reference URL is required (--face)"
		return 1
	fi

	local endpoint
	case "${mode}" in
	image) endpoint="ai-image-face-swap" ;;
	video) endpoint="ai-video-face-swap" ;;
	*)
		print_error "Unknown mode: ${mode} (use image or video)"
		return 1
		;;
	esac

	local extra
	extra=$(jq -n --arg face "${face_url}" '{face_image: $face}')

	submit_specialized "${endpoint}" "${image_url}" "${extra}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Image upscaling
cmd_upscale() {
	local image_url=""
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image_url="$2"
			shift 2
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
		--webhook)
			webhook="$2"
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

	submit_specialized "ai-image-upscale" "${image_url}" "{}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Background removal
cmd_bg_remove() {
	local image_url=""
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image_url="$2"
			shift 2
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
		--webhook)
			webhook="$2"
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

	submit_specialized "ai-background-remover" "${image_url}" "{}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Dress change
cmd_dress_change() {
	local image_url=""
	local prompt=""
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image_url="$2"
			shift 2
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
		--webhook)
			webhook="$2"
			shift 2
			;;
		--*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "${prompt}" ]]; then prompt="$1"; else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	local extra
	if [[ -n "${prompt}" ]]; then
		extra=$(jq -n --arg p "${prompt}" '{prompt: $p}')
	else
		extra="{}"
	fi

	submit_specialized "ai-dress-change" "${image_url}" "${extra}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Stylization (Ghibli/Anime)
cmd_stylize() {
	local image_url=""
	local style="ghibli"
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image_url="$2"
			shift 2
			;;
		--style)
			style="$2"
			shift 2
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
		--webhook)
			webhook="$2"
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

	local endpoint
	case "${style}" in
	ghibli) endpoint="ai-ghibli-style" ;;
	anime) endpoint="ai-anime-generator" ;;
	*)
		print_error "Unknown style: ${style} (use ghibli or anime)"
		return 1
		;;
	esac

	submit_specialized "${endpoint}" "${image_url}" "{}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Product shot
cmd_product_shot() {
	local image_url=""
	local prompt=""
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image_url="$2"
			shift 2
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
		--webhook)
			webhook="$2"
			shift 2
			;;
		--*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "${prompt}" ]]; then prompt="$1"; else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	local extra
	if [[ -n "${prompt}" ]]; then
		extra=$(jq -n --arg p "${prompt}" '{prompt: $p}')
	else
		extra="{}"
	fi

	submit_specialized "ai-product-shot" "${image_url}" "${extra}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Object eraser
cmd_object_erase() {
	local image_url=""
	local mask_url=""
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image_url="$2"
			shift 2
			;;
		--mask)
			mask_url="$2"
			shift 2
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
		--webhook)
			webhook="$2"
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

	local extra
	if [[ -n "${mask_url}" ]]; then
		extra=$(jq -n --arg m "${mask_url}" '{mask_url: $m}')
	else
		extra="{}"
	fi

	submit_specialized "ai-object-eraser" "${image_url}" "${extra}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Image extension (outpainting)
cmd_image_extend() {
	local image_url=""
	local prompt=""
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image_url="$2"
			shift 2
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
		--webhook)
			webhook="$2"
			shift 2
			;;
		--*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "${prompt}" ]]; then prompt="$1"; else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	local extra
	if [[ -n "${prompt}" ]]; then
		extra=$(jq -n --arg p "${prompt}" '{prompt: $p}')
	else
		extra="{}"
	fi

	submit_specialized "ai-image-extension" "${image_url}" "${extra}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# Skin enhancer
cmd_skin_enhance() {
	local image_url=""
	local poll_interval="${DEFAULT_POLL_INTERVAL}"
	local timeout="${DEFAULT_TIMEOUT}"
	local output_file=""
	local webhook=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--image)
			image_url="$2"
			shift 2
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
		--webhook)
			webhook="$2"
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

	submit_specialized "ai-skin-enhancer" "${image_url}" "{}" "${poll_interval}" "${timeout}" "${output_file}" "${webhook}"
}

# --- Credits & Usage ---

# Check credit balance
cmd_balance() {
	load_api_key || return 1

	local response
	response=$(api_request GET "${MUAPI_BASE}/payments/credits")

	echo "${response}" | jq . 2>/dev/null || echo "${response}"
	return 0
}

# Check usage history
cmd_usage() {
	load_api_key || return 1

	local response
	response=$(api_request GET "${MUAPI_BASE}/payments/usage")

	echo "${response}" | jq . 2>/dev/null || echo "${response}"
	return 0
}

# Check task status
cmd_status() {
	local request_id="${1:-}"

	if [[ -z "${request_id}" ]]; then
		print_error "Request ID is required"
		print_info "Usage: muapi-helper.sh status <request-id>"
		return 1
	fi

	load_api_key || return 1

	local response
	response=$(api_request GET "${MUAPI_BASE}/predictions/${request_id}/result")

	echo "${response}" | jq . 2>/dev/null || echo "${response}"
	return 0
}

# Show help
show_help() {
	cat <<'EOF'
MuAPI Helper - REST API client for MuAPI (muapi.ai)

Usage: muapi-helper.sh <command> [arguments] [options]

Commands:
  flux <prompt>           Generate image with Flux Dev
  video-effects <prompt>  Apply AI video effects to an image
  vfx <prompt>            Apply VFX (explosions, etc.) to an image
  motion <prompt>         Apply motion controls to an image
  music <prompt>          Generate music with Suno
  lipsync                 Lip-sync video with audio
  face-swap               Swap faces in images or videos
  upscale                 Upscale image resolution
  bg-remove               Remove image background
  dress-change [prompt]   Change outfit on a subject
  stylize                 Apply Ghibli or anime style
  product-shot [prompt]   Generate product photography background
  object-erase            Remove objects with inpainting
  image-extend [prompt]   Outpaint beyond image borders
  skin-enhance            Professional skin retouching
  balance                 Check credit balance
  usage                   Check usage history
  agent-create <prompt>   Create an AI agent from a goal
  agent-chat <id> <msg>   Chat with an agent
  agent-list              List your agents
  agent-skills            List available agent skills
  status <request-id>     Check task status
  help                    Show this help

Common Options:
  --poll <seconds>        Poll interval (default: 2)
  --timeout <seconds>     Timeout (default: 300)
  --output, -o <file>     Save full response JSON to file
  --webhook <url>         Receive results via webhook instead of polling

Flux Options:
  --image <url>           Reference image for img2img
  --mask <url>            Mask image for inpainting
  --size <WxH>            Output size (default: 1024*1024)
  --steps <n>             Inference steps (default: 28)
  --seed <n>              Seed for reproducibility (-1 = random)
  --guidance <n>          CFG scale (default: 3.5)
  --num <n>               Number of images (1-4, default: 1)
  --strength <n>          Img2img strength (0.0-1.0, default: 0.8)

Effects/VFX/Motion Options:
  --image <url>           Source image URL (required)
  --effect <name>         Effect name (required, e.g., "Cakeify", "Car Explosion", "360 Orbit")
  --ratio <ratio>         Aspect ratio (1:1, 9:16, 16:9, default: 16:9)
  --resolution <res>      Resolution (480p, 720p, default: 480p)
  --quality <q>           Quality (medium, high, default: medium)
  --duration <s>          Duration in seconds (5-10, default: 5)

Music Options:
  --remix                 Remix mode (requires --audio)
  --extend                Extend mode (requires --audio)
  --audio <url>           Source audio URL for remix/extend

Lipsync Options:
  --video <url>           Video URL (required)
  --audio <url>           Audio URL (required)
  --model <name>          Model: sync-lipsync, latentsync, creatify, veed (default: sync-lipsync)

Face Swap Options:
  --image <url>           Source image URL (required for image mode)
  --video <url>           Source video URL (sets mode to video)
  --face <url>            Face reference image URL (required)
  --mode <image|video>    Swap mode (default: image)

Stylize Options:
  --image <url>           Source image URL (required)
  --style <name>          Style: ghibli, anime (default: ghibli)

Object Erase Options:
  --image <url>           Source image URL (required)
  --mask <url>            Mask image URL (white=erase area)

Examples:
  # Generate an image
  muapi-helper.sh flux "A cyberpunk city at night" --size 1024*1024

  # Apply video effect
  muapi-helper.sh video-effects "a cute kitten" --image https://example.com/cat.jpg --effect "Cakeify"

  # Apply VFX
  muapi-helper.sh vfx "a car scene" --image https://example.com/car.jpg --effect "Car Explosion"

  # Apply motion
  muapi-helper.sh motion "a portrait" --image https://example.com/person.jpg --effect "360 Orbit"

  # Generate music
  muapi-helper.sh music "upbeat electronic track with synths and bass"

  # Lip-sync
  muapi-helper.sh lipsync --video https://example.com/video.mp4 --audio https://example.com/audio.mp3

  # Face swap
  muapi-helper.sh face-swap --image https://example.com/photo.jpg --face https://example.com/face.jpg

  # Upscale image
  muapi-helper.sh upscale --image https://example.com/lowres.jpg

  # Remove background
  muapi-helper.sh bg-remove --image https://example.com/product.jpg

  # Ghibli stylization
  muapi-helper.sh stylize --image https://example.com/photo.jpg --style ghibli

  # Product photography
  muapi-helper.sh product-shot --image https://example.com/product.jpg "white studio"

  # Check credit balance
  muapi-helper.sh balance

  # Create an agent
  muapi-helper.sh agent-create "I want an agent that creates minimalist brand assets"

  # Chat with an agent
  muapi-helper.sh agent-chat agent_abc123 "Design a logo for Vapor"

  # Check task status
  muapi-helper.sh status abc123-def456

Environment:
  MUAPI_API_KEY  API key (get from https://muapi.ai/access-keys)
                 Store via: aidevops secret set MUAPI_API_KEY
EOF
}

# Main
main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "${command}" in
	flux) cmd_flux "$@" ;;
	video-effects) cmd_effects "$@" ;;
	vfx) cmd_effects "$@" ;;
	motion) cmd_effects "$@" ;;
	music) cmd_music "$@" ;;
	lipsync) cmd_lipsync "$@" ;;
	face-swap) cmd_face_swap "$@" ;;
	upscale) cmd_upscale "$@" ;;
	bg-remove) cmd_bg_remove "$@" ;;
	dress-change) cmd_dress_change "$@" ;;
	stylize) cmd_stylize "$@" ;;
	product-shot) cmd_product_shot "$@" ;;
	object-erase) cmd_object_erase "$@" ;;
	image-extend) cmd_image_extend "$@" ;;
	skin-enhance) cmd_skin_enhance "$@" ;;
	balance) cmd_balance "$@" ;;
	usage) cmd_usage "$@" ;;
	agent-create) cmd_agent_create "$@" ;;
	agent-chat) cmd_agent_chat "$@" ;;
	agent-list) cmd_agent_list "$@" ;;
	agent-skills) cmd_agent_skills "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: ${command}"
		show_help
		return 1
		;;
	esac
}

main "$@"
