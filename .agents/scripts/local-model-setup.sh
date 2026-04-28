#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Local Model Setup Library — Hardware Detection & Installation
# =============================================================================
# Platform/GPU/memory detection, llama.cpp release download helpers,
# huggingface-cli installer, and the cmd_setup entry point.
#
# Usage: source "${SCRIPT_DIR}/local-model-setup.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, etc.)
#   - local-model-db.sh (ensure_dirs, write_default_config, init_usage_db)
#   - curl, tar/unzip (for binary downloads)
#   - jq (for parsing GitHub release JSON)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCAL_MODEL_SETUP_LIB_LOADED:-}" ]] && return 0
_LOCAL_MODEL_SETUP_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Hardware Detection
# =============================================================================

# Detect platform and architecture
detect_platform() {
	local os arch platform
	os="$(uname -s)"
	arch="$(uname -m)"

	case "$os" in
	Darwin)
		case "$arch" in
		arm64) platform="macos-arm64" ;;
		x86_64) platform="macos-x64" ;;
		*)
			print_error "Unsupported macOS architecture: ${arch}"
			return 1
			;;
		esac
		;;
	Linux)
		case "$arch" in
		x86_64)
			# Check for GPU acceleration (order: ROCm > Vulkan > NVIDIA-via-Vulkan > CPU)
			if suppress_stderr command -v rocminfo; then
				platform="linux-rocm"
			elif suppress_stderr command -v vulkaninfo; then
				platform="linux-vulkan"
			elif suppress_stderr command -v nvidia-smi; then
				# NVIDIA GPU detected but no Vulkan SDK — use Vulkan binary anyway
				# (NVIDIA drivers include Vulkan support; vulkaninfo just isn't installed)
				platform="linux-vulkan"
			else
				platform="linux-x64"
			fi
			;;
		aarch64)
			print_error "No prebuilt Linux ARM64 binary available. Compile from source:"
			print_error "  git clone https://github.com/ggml-org/llama.cpp.git"
			print_error "  cd llama.cpp && cmake -B build && cmake --build build --config Release -j\$(nproc)"
			return 1
			;;
		*)
			print_error "Unsupported Linux architecture: ${arch}"
			return 1
			;;
		esac
		;;
	*)
		print_error "${ERROR_UNKNOWN_PLATFORM}: ${os}"
		return 1
		;;
	esac

	echo "$platform"
	return 0
}

# Detect number of performance cores (not efficiency cores on Apple Silicon)
detect_threads() {
	local threads
	if [[ "$(uname -s)" == "Darwin" ]]; then
		threads="$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "4")"
	else
		threads="$(nproc 2>/dev/null || echo "4")"
	fi
	echo "$threads"
	return 0
}

# Detect available memory in GB (for model recommendations)
detect_available_memory_gb() {
	local mem_gb
	if [[ "$(uname -s)" == "Darwin" ]]; then
		local mem_bytes
		mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo "0")"
		mem_gb="$((mem_bytes / 1073741824))"
	else
		local mem_kb
		mem_kb="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")"
		mem_gb="$((mem_kb / 1048576))"
	fi
	echo "$mem_gb"
	return 0
}

# Detect GPU type
detect_gpu() {
	local os
	os="$(uname -s)"
	if [[ "$os" == "Darwin" ]]; then
		local chip
		chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")"
		if [[ "$(uname -m)" == "arm64" ]]; then
			echo "Metal (Apple Silicon - ${chip})"
		else
			echo "Metal (Intel Mac - ${chip})"
		fi
	elif suppress_stderr command -v nvidia-smi; then
		nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1
	elif suppress_stderr command -v rocminfo; then
		echo "ROCm (AMD)"
	elif suppress_stderr command -v vulkaninfo; then
		echo "Vulkan"
	else
		echo "CPU only (no GPU detected)"
	fi
	return 0
}

# =============================================================================
# Release Asset Resolution
# =============================================================================

# Get the release asset name pattern for the current platform
get_release_asset_pattern() {
	local platform="$1"
	# llama.cpp releases use .tar.gz for macOS/Linux (changed from .zip circa b8100+)
	case "$platform" in
	macos-arm64) echo "llama-.*-bin-macos-arm64\\.tar\\.gz" ;;
	macos-x64) echo "llama-.*-bin-macos-x64\\.tar\\.gz" ;;
	linux-x64) echo "llama-.*-bin-ubuntu-x64\\.tar\\.gz" ;;
	linux-vulkan) echo "llama-.*-bin-ubuntu-vulkan-x64\\.tar\\.gz" ;;
	linux-rocm) echo "llama-.*-bin-ubuntu-rocm-.*-x64\\.tar\\.gz" ;;
	*) return 1 ;;
	esac
	return 0
}

# =============================================================================
# Installation Helpers
# =============================================================================

# Resolve download URL for a llama.cpp release asset
_setup_find_asset_url() {
	local platform="$1"
	local release_json="$2"

	local asset_pattern
	asset_pattern="$(get_release_asset_pattern "$platform")" || {
		print_error "No binary available for platform: ${platform}"
		return 1
	}

	local download_url
	download_url="$(echo "$release_json" | jq -r --arg pat "$asset_pattern" \
		'.assets[] | select(.name | test($pat)) | .browser_download_url' | head -1)"

	if [[ -z "$download_url" ]]; then
		print_error "No matching release asset for pattern: ${asset_pattern}"
		print_info "Available assets:"
		echo "$release_json" | jq -r '.assets[].name' 2>/dev/null | head -10
		return 1
	fi

	echo "$download_url"
	return 0
}

# Download and extract a llama.cpp release archive into a temp dir
_setup_extract_archive() {
	local download_url="$1"
	local tmp_dir="$2"

	local asset_name
	asset_name="$(basename "$download_url")"
	local tmp_archive="${tmp_dir}/${asset_name}"

	print_info "Downloading ${asset_name}..."
	if ! curl -sL -o "$tmp_archive" "$download_url"; then
		print_error "Download failed: ${download_url}"
		return 1
	fi

	print_info "Extracting..."
	mkdir -p "${tmp_dir}/extracted"
	if [[ "$asset_name" == *.tar.gz ]] || [[ "$asset_name" == *.tgz ]]; then
		if ! tar -xzf "$tmp_archive" -C "${tmp_dir}/extracted"; then
			print_error "Extraction failed (tar.gz)"
			return 1
		fi
	elif [[ "$asset_name" == *.zip ]]; then
		if ! unzip -qo "$tmp_archive" -d "${tmp_dir}/extracted"; then
			print_error "Extraction failed (zip)"
			return 1
		fi
	else
		print_error "Unknown archive format: ${asset_name}"
		return 1
	fi

	return 0
}

# Install llama-server (and optionally llama-cli) from extracted dir
_setup_install_binaries() {
	local extracted_dir="$1"

	local server_bin
	server_bin="$(find "$extracted_dir" -name "llama-server" -type f | head -1)"
	if [[ -z "$server_bin" ]]; then
		server_bin="$(find "$extracted_dir" -name "llama-server*" -type f ! -name "*.dll" | head -1)"
	fi

	if [[ -z "$server_bin" ]]; then
		print_error "llama-server binary not found in release archive"
		print_info "Archive contents:"
		find "$extracted_dir" -type f | head -20
		return 1
	fi

	cp "$server_bin" "$LLAMA_SERVER_BIN"
	chmod +x "$LLAMA_SERVER_BIN"

	# Also copy llama-cli if present
	local cli_bin
	cli_bin="$(find "$extracted_dir" -name "llama-cli" -type f | head -1)"
	if [[ -n "$cli_bin" ]]; then
		cp "$cli_bin" "$LLAMA_CLI_BIN"
		chmod +x "$LLAMA_CLI_BIN"
	fi

	return 0
}

# Download and extract llama.cpp release
_setup_download_llama() {
	local platform="$1"
	local release_json="$2"

	if ! suppress_stderr command -v curl; then
		print_error "curl is required but not found"
		return 2
	fi

	if ! suppress_stderr command -v tar && ! suppress_stderr command -v unzip; then
		print_error "tar or unzip is required but neither found"
		return 2
	fi

	local tag_name
	tag_name="$(echo "$release_json" | jq -r '.tag_name // empty')"
	if [[ -z "$tag_name" ]]; then
		print_error "Could not determine latest release tag (jq required)"
		return 1
	fi
	print_info "Latest release: ${tag_name}"

	local download_url
	download_url="$(_setup_find_asset_url "$platform" "$release_json")" || return $?

	local tmp_dir
	tmp_dir="$(mktemp -d)"

	if ! _setup_extract_archive "$download_url" "$tmp_dir"; then
		rm -rf "$tmp_dir"
		return 1
	fi

	if ! _setup_install_binaries "${tmp_dir}/extracted"; then
		rm -rf "$tmp_dir"
		return 1
	fi

	rm -rf "$tmp_dir"

	local installed_version
	installed_version="$("$LLAMA_SERVER_BIN" --version 2>/dev/null | head -1 || echo "${tag_name}")"
	print_success "llama-server installed: ${installed_version}"
	return 0
}

# Install huggingface-cli
_setup_install_hf_cli() {
	if ! suppress_stderr command -v huggingface-cli; then
		print_info "Installing huggingface-cli..."
		if suppress_stderr command -v pip3; then
			log_stderr "pip install" pip3 install --quiet "huggingface_hub[cli]" || {
				print_warning "Failed to install huggingface-cli via pip3"
				print_info "Install manually: pip3 install 'huggingface_hub[cli]'"
			}
		elif suppress_stderr command -v pip; then
			log_stderr "pip install" pip install --quiet "huggingface_hub[cli]" || {
				print_warning "Failed to install huggingface-cli via pip"
				print_info "Install manually: pip install 'huggingface_hub[cli]'"
			}
		else
			print_warning "pip not found — install huggingface-cli manually"
			print_info "Install: pip3 install 'huggingface_hub[cli]'"
		fi
	else
		print_info "huggingface-cli: already installed"
	fi
	return 0
}

# =============================================================================
# Command: setup / install
# =============================================================================

cmd_setup() {
	local update_mode=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--update)
			update_mode=true
			shift
			;;
		*) shift ;;
		esac
	done

	ensure_dirs

	print_info "Detecting platform..."
	local platform
	platform="$(detect_platform)" || return 1
	print_info "Platform: ${platform}"

	local gpu
	gpu="$(detect_gpu)"
	print_info "GPU: ${gpu}"

	local mem_gb
	mem_gb="$(detect_available_memory_gb)"
	print_info "Total RAM: ${mem_gb} GB"

	# Check if llama-server already exists
	if [[ -f "$LLAMA_SERVER_BIN" ]] && [[ "$update_mode" == "false" ]]; then
		local current_version
		current_version="$("$LLAMA_SERVER_BIN" --version 2>/dev/null | head -1 || echo "unknown")"
		print_info "llama-server already installed: ${current_version}"
		print_info "Use 'local-model-helper.sh setup --update' to update"
	else
		# Download llama.cpp release
		print_info "Fetching latest llama.cpp release..."

		local release_json
		release_json="$(curl -sL "$LLAMA_CPP_API")" || {
			print_error "Failed to fetch llama.cpp release info"
			return 1
		}

		_setup_download_llama "$platform" "$release_json" || return $?
	fi

	# Install huggingface-cli if not present
	_setup_install_hf_cli

	# Write default config
	write_default_config

	# Initialize usage database
	init_usage_db

	print_success "Setup complete. Directory: ${LOCAL_MODELS_DIR}"
	print_info "Next: local-model-helper.sh recommend  (see model suggestions)"
	print_info "      local-model-helper.sh search \"qwen3 8b\"  (find models)"
	return 0
}
