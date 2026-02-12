#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2129
set -euo pipefail

# REAL Video Enhancer Helper Script
# CLI wrapper for REAL Video Enhancer - AI-powered video upscaling, interpolation, and enhancement
#
# Usage: real-video-enhancer-helper.sh <command> [options]
#
# Commands:
#   install       Install REAL Video Enhancer with auto-detected backend
#   enhance       Full enhancement pipeline (upscale + interpolate + denoise)
#   upscale       Upscale video resolution (2x/4x)
#   interpolate   Increase frame rate (24fps → 48/60fps)
#   denoise       Remove noise from video
#   batch         Process multiple videos
#   models        Manage models (list, download, clear)
#   backends      Show available backends and GPU detection
#   gui           Launch Qt GUI
#   help          Show this help message

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Configuration
# =============================================================================

readonly RVE_REPO="https://github.com/TNTwise/REAL-Video-Enhancer.git"
readonly RVE_DIR="${HOME}/.local/share/real-video-enhancer"
readonly RVE_MODELS_DIR="${HOME}/.cache/real-video-enhancer/models"
readonly RVE_PYTHON_MIN="3.10"
readonly RVE_PYTHON_MAX="3.12"

# Default settings
DEFAULT_SCALE=2
DEFAULT_FPS=60
DEFAULT_INTERPOLATE_MODEL="rife"
DEFAULT_UPSCALE_MODEL="span"
DEFAULT_DENOISE_MODEL="drunet"
DEFAULT_TILE_SIZE=1024
DEFAULT_BACKEND="auto"

# =============================================================================
# Helper Functions
# =============================================================================

print_info() {
	echo -e "\033[0;36m[INFO]\033[0m $*"
}

print_success() {
	echo -e "\033[0;32m[OK]\033[0m $*"
}

print_error() {
	echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
}

print_warning() {
	echo -e "\033[0;33m[WARN]\033[0m $*"
}

# Check if REAL Video Enhancer is installed
check_installation() {
	if [[ ! -d "${RVE_DIR}" ]]; then
		print_error "REAL Video Enhancer not installed"
		print_info "Run: real-video-enhancer-helper.sh install"
		return 1
	fi

	if [[ ! -f "${RVE_DIR}/main.py" ]]; then
		print_error "REAL Video Enhancer installation corrupted"
		print_info "Run: real-video-enhancer-helper.sh install --force"
		return 1
	fi

	return 0
}

# Detect Python version
detect_python() {
	local python_cmd=""

	for cmd in python3.12 python3.11 python3.10 python3 python; do
		if command -v "$cmd" &>/dev/null; then
			local version
			version=$("$cmd" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
			local major minor
			major=$(echo "$version" | cut -d. -f1)
			minor=$(echo "$version" | cut -d. -f2)

			if [[ "$major" -eq 3 ]] && [[ "$minor" -ge 10 ]] && [[ "$minor" -le 12 ]]; then
				python_cmd="$cmd"
				break
			fi
		fi
	done

	if [[ -z "$python_cmd" ]]; then
		print_error "Python ${RVE_PYTHON_MIN}-${RVE_PYTHON_MAX} required"
		print_info "Install Python 3.10, 3.11, or 3.12"
		return 1
	fi

	echo "$python_cmd"
	return 0
}

# Detect GPU backend
detect_backend() {
	local backend="ncnn" # Default fallback

	# Check for NVIDIA GPU (CUDA)
	if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
		# Check for TensorRT
		if python3 -c "import tensorrt" &>/dev/null 2>&1; then
			backend="tensorrt"
		else
			backend="pytorch"
		fi
		print_info "Detected NVIDIA GPU - using ${backend} backend"
		echo "$backend"
		return 0
	fi

	# Check for AMD GPU (ROCm)
	if command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null 2>&1; then
		backend="pytorch"
		print_info "Detected AMD GPU - using PyTorch ROCm backend"
		echo "$backend"
		return 0
	fi

	# Check for Apple Silicon
	if [[ "$(uname -s)" == "Darwin" ]] && [[ "$(uname -m)" == "arm64" ]]; then
		backend="ncnn"
		print_info "Detected Apple Silicon - using NCNN Vulkan backend"
		echo "$backend"
		return 0
	fi

	# Fallback to NCNN (CPU/Vulkan)
	print_warning "No GPU detected - using NCNN CPU backend (slower)"
	echo "$backend"
	return 0
}

# =============================================================================
# Installation
# =============================================================================

cmd_install() {
	local backend="${DEFAULT_BACKEND}"
	local force=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--backend | -b)
			backend="$2"
			shift 2
			;;
		--force | -f)
			force=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Check Python version
	local python_cmd
	python_cmd=$(detect_python) || return 1
	print_success "Using Python: $python_cmd"

	# Remove existing installation if --force
	if [[ "$force" == true ]] && [[ -d "${RVE_DIR}" ]]; then
		print_warning "Removing existing installation..."
		rm -rf "${RVE_DIR}"
	fi

	# Clone repository
	if [[ ! -d "${RVE_DIR}" ]]; then
		print_info "Cloning REAL Video Enhancer..."
		mkdir -p "$(dirname "${RVE_DIR}")"
		if ! git clone "${RVE_REPO}" "${RVE_DIR}"; then
			print_error "Failed to clone repository"
			return 1
		fi
	else
		print_info "REAL Video Enhancer already cloned"
	fi

	# Install dependencies
	print_info "Installing Python dependencies..."
	cd "${RVE_DIR}" || return 1

	if [[ ! -f "requirements.txt" ]]; then
		print_error "requirements.txt not found in ${RVE_DIR}"
		return 1
	fi

	if ! "$python_cmd" -m pip install -r requirements.txt; then
		print_error "Failed to install dependencies"
		return 1
	fi

	# Auto-detect backend if set to auto
	if [[ "$backend" == "auto" ]]; then
		backend=$(detect_backend)
	fi

	# Install backend-specific dependencies
	print_info "Installing ${backend} backend..."
	case "$backend" in
	tensorrt)
		if ! "$python_cmd" -m pip install tensorrt; then
			print_warning "TensorRT installation failed, falling back to PyTorch"
			backend="pytorch"
		fi
		;;
	pytorch)
		# Detect CUDA vs ROCm
		if command -v nvidia-smi &>/dev/null; then
			print_info "Installing PyTorch with CUDA support..."
			"$python_cmd" -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu118
		elif command -v rocm-smi &>/dev/null; then
			print_info "Installing PyTorch with ROCm support..."
			"$python_cmd" -m pip install torch torchvision --index-url https://download.pytorch.org/whl/rocm5.7
		else
			print_warning "No GPU detected, installing CPU-only PyTorch"
			"$python_cmd" -m pip install torch torchvision
		fi
		;;
	ncnn)
		if ! "$python_cmd" -m pip install ncnn; then
			print_error "NCNN installation failed"
			return 1
		fi
		;;
	*)
		print_error "Unknown backend: $backend"
		print_info "Valid backends: tensorrt, pytorch, ncnn, auto"
		return 1
		;;
	esac

	# Create models directory
	mkdir -p "${RVE_MODELS_DIR}"

	print_success "REAL Video Enhancer installed successfully"
	print_info "Backend: ${backend}"
	print_info "Installation directory: ${RVE_DIR}"
	print_info "Models directory: ${RVE_MODELS_DIR}"
	print_info ""
	print_info "Next steps:"
	print_info "  1. Upscale video: real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 2"
	print_info "  2. Interpolate: real-video-enhancer-helper.sh interpolate input.mp4 output.mp4 --fps 60"
	print_info "  3. Full enhance: real-video-enhancer-helper.sh enhance input.mp4 output.mp4 --scale 2 --fps 60"

	return 0
}

# =============================================================================
# Enhancement Commands
# =============================================================================

cmd_upscale() {
	check_installation || return 1

	local input=""
	local output=""
	local scale="${DEFAULT_SCALE}"
	local model="${DEFAULT_UPSCALE_MODEL}"
	local backend="${DEFAULT_BACKEND}"
	local tile_size="${DEFAULT_TILE_SIZE}"
	local verbose=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--scale | -s)
			scale="$2"
			shift 2
			;;
		--model | -m)
			model="$2"
			shift 2
			;;
		--backend | -b)
			backend="$2"
			shift 2
			;;
		--tile-size | -t)
			tile_size="$2"
			shift 2
			;;
		--verbose | -v)
			verbose=true
			shift
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$input" ]]; then
				input="$1"
			elif [[ -z "$output" ]]; then
				output="$1"
			else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -z "$input" ]] || [[ -z "$output" ]]; then
		print_error "Usage: real-video-enhancer-helper.sh upscale <input> <output> [options]"
		print_info "Options:"
		print_info "  --scale, -s <2|4>          Upscale factor (default: ${DEFAULT_SCALE})"
		print_info "  --model, -m <model>        Upscaling model (default: ${DEFAULT_UPSCALE_MODEL})"
		print_info "  --backend, -b <backend>    Backend (tensorrt|pytorch|ncnn|auto)"
		print_info "  --tile-size, -t <size>     Tile size for processing (default: ${DEFAULT_TILE_SIZE})"
		print_info "  --verbose, -v              Enable verbose logging"
		return 1
	fi

	if [[ ! -f "$input" ]]; then
		print_error "Input file not found: $input"
		return 1
	fi

	# Auto-detect backend if needed
	if [[ "$backend" == "auto" ]]; then
		backend=$(detect_backend)
	fi

	print_info "Upscaling video: $input → $output"
	print_info "Scale: ${scale}x, Model: $model, Backend: $backend"

	local python_cmd
	python_cmd=$(detect_python) || return 1

	local cmd_args=(
		"${RVE_DIR}/main.py"
		"--input" "$input"
		"--output" "$output"
		"--mode" "upscale"
		"--scale" "$scale"
		"--model" "$model"
		"--backend" "$backend"
		"--tile-size" "$tile_size"
	)

	if [[ "$verbose" == true ]]; then
		cmd_args+=("--verbose")
	fi

	if ! "$python_cmd" "${cmd_args[@]}"; then
		print_error "Upscaling failed"
		return 1
	fi

	print_success "Upscaling complete: $output"
	return 0
}

cmd_interpolate() {
	check_installation || return 1

	local input=""
	local output=""
	local fps="${DEFAULT_FPS}"
	local model="${DEFAULT_INTERPOLATE_MODEL}"
	local backend="${DEFAULT_BACKEND}"
	local verbose=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--fps | -f)
			fps="$2"
			shift 2
			;;
		--model | -m)
			model="$2"
			shift 2
			;;
		--backend | -b)
			backend="$2"
			shift 2
			;;
		--verbose | -v)
			verbose=true
			shift
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$input" ]]; then
				input="$1"
			elif [[ -z "$output" ]]; then
				output="$1"
			else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -z "$input" ]] || [[ -z "$output" ]]; then
		print_error "Usage: real-video-enhancer-helper.sh interpolate <input> <output> [options]"
		print_info "Options:"
		print_info "  --fps, -f <fps>            Target frame rate (default: ${DEFAULT_FPS})"
		print_info "  --model, -m <model>        Interpolation model (default: ${DEFAULT_INTERPOLATE_MODEL})"
		print_info "  --backend, -b <backend>    Backend (tensorrt|pytorch|ncnn|auto)"
		print_info "  --verbose, -v              Enable verbose logging"
		return 1
	fi

	if [[ ! -f "$input" ]]; then
		print_error "Input file not found: $input"
		return 1
	fi

	# Auto-detect backend if needed
	if [[ "$backend" == "auto" ]]; then
		backend=$(detect_backend)
	fi

	print_info "Interpolating video: $input → $output"
	print_info "Target FPS: $fps, Model: $model, Backend: $backend"

	local python_cmd
	python_cmd=$(detect_python) || return 1

	local cmd_args=(
		"${RVE_DIR}/main.py"
		"--input" "$input"
		"--output" "$output"
		"--mode" "interpolate"
		"--fps" "$fps"
		"--model" "$model"
		"--backend" "$backend"
	)

	if [[ "$verbose" == true ]]; then
		cmd_args+=("--verbose")
	fi

	if ! "$python_cmd" "${cmd_args[@]}"; then
		print_error "Interpolation failed"
		return 1
	fi

	print_success "Interpolation complete: $output"
	return 0
}

cmd_denoise() {
	check_installation || return 1

	local input=""
	local output=""
	local model="${DEFAULT_DENOISE_MODEL}"
	local backend="${DEFAULT_BACKEND}"
	local verbose=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model | -m)
			model="$2"
			shift 2
			;;
		--backend | -b)
			backend="$2"
			shift 2
			;;
		--verbose | -v)
			verbose=true
			shift
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$input" ]]; then
				input="$1"
			elif [[ -z "$output" ]]; then
				output="$1"
			else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -z "$input" ]] || [[ -z "$output" ]]; then
		print_error "Usage: real-video-enhancer-helper.sh denoise <input> <output> [options]"
		print_info "Options:"
		print_info "  --model, -m <model>        Denoising model (default: ${DEFAULT_DENOISE_MODEL})"
		print_info "  --backend, -b <backend>    Backend (tensorrt|pytorch|ncnn|auto)"
		print_info "  --verbose, -v              Enable verbose logging"
		return 1
	fi

	if [[ ! -f "$input" ]]; then
		print_error "Input file not found: $input"
		return 1
	fi

	# Auto-detect backend if needed
	if [[ "$backend" == "auto" ]]; then
		backend=$(detect_backend)
	fi

	print_info "Denoising video: $input → $output"
	print_info "Model: $model, Backend: $backend"

	local python_cmd
	python_cmd=$(detect_python) || return 1

	local cmd_args=(
		"${RVE_DIR}/main.py"
		"--input" "$input"
		"--output" "$output"
		"--mode" "denoise"
		"--model" "$model"
		"--backend" "$backend"
	)

	if [[ "$verbose" == true ]]; then
		cmd_args+=("--verbose")
	fi

	if ! "$python_cmd" "${cmd_args[@]}"; then
		print_error "Denoising failed"
		return 1
	fi

	print_success "Denoising complete: $output"
	return 0
}

cmd_enhance() {
	check_installation || return 1

	local input=""
	local output=""
	local scale="${DEFAULT_SCALE}"
	local fps="${DEFAULT_FPS}"
	local denoise=false
	local upscale_model="${DEFAULT_UPSCALE_MODEL}"
	local interpolate_model="${DEFAULT_INTERPOLATE_MODEL}"
	local denoise_model="${DEFAULT_DENOISE_MODEL}"
	local backend="${DEFAULT_BACKEND}"
	local tile_size="${DEFAULT_TILE_SIZE}"
	local verbose=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--scale | -s)
			scale="$2"
			shift 2
			;;
		--fps | -f)
			fps="$2"
			shift 2
			;;
		--denoise | -d)
			denoise=true
			shift
			;;
		--upscale-model)
			upscale_model="$2"
			shift 2
			;;
		--interpolate-model)
			interpolate_model="$2"
			shift 2
			;;
		--denoise-model)
			denoise_model="$2"
			shift 2
			;;
		--backend | -b)
			backend="$2"
			shift 2
			;;
		--tile-size | -t)
			tile_size="$2"
			shift 2
			;;
		--verbose | -v)
			verbose=true
			shift
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$input" ]]; then
				input="$1"
			elif [[ -z "$output" ]]; then
				output="$1"
			else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -z "$input" ]] || [[ -z "$output" ]]; then
		print_error "Usage: real-video-enhancer-helper.sh enhance <input> <output> [options]"
		print_info "Options:"
		print_info "  --scale, -s <2|4>              Upscale factor (default: ${DEFAULT_SCALE})"
		print_info "  --fps, -f <fps>                Target frame rate (default: ${DEFAULT_FPS})"
		print_info "  --denoise, -d                  Enable denoising"
		print_info "  --upscale-model <model>        Upscaling model (default: ${DEFAULT_UPSCALE_MODEL})"
		print_info "  --interpolate-model <model>    Interpolation model (default: ${DEFAULT_INTERPOLATE_MODEL})"
		print_info "  --denoise-model <model>        Denoising model (default: ${DEFAULT_DENOISE_MODEL})"
		print_info "  --backend, -b <backend>        Backend (tensorrt|pytorch|ncnn|auto)"
		print_info "  --tile-size, -t <size>         Tile size (default: ${DEFAULT_TILE_SIZE})"
		print_info "  --verbose, -v                  Enable verbose logging"
		return 1
	fi

	if [[ ! -f "$input" ]]; then
		print_error "Input file not found: $input"
		return 1
	fi

	# Auto-detect backend if needed
	if [[ "$backend" == "auto" ]]; then
		backend=$(detect_backend)
	fi

	print_info "Full enhancement pipeline: $input → $output"
	print_info "Scale: ${scale}x, FPS: $fps, Denoise: $denoise"
	print_info "Backend: $backend"

	# Create temporary files for pipeline
	local temp_dir
	temp_dir=$(mktemp -d)
	local temp_upscaled="${temp_dir}/upscaled.mp4"
	local temp_interpolated="${temp_dir}/interpolated.mp4"

	# Step 1: Upscale
	print_info "[1/3] Upscaling..."
	local upscale_args=(
		"$input"
		"$temp_upscaled"
		--scale "$scale"
		--model "$upscale_model"
		--backend "$backend"
		--tile-size "$tile_size"
	)
	if [[ "$verbose" == true ]]; then
		upscale_args+=(--verbose)
	fi

	if ! cmd_upscale "${upscale_args[@]}"; then
		rm -rf "$temp_dir"
		return 1
	fi

	# Step 2: Interpolate
	print_info "[2/3] Interpolating..."
	local interpolate_args=(
		"$temp_upscaled"
		"$temp_interpolated"
		--fps "$fps"
		--model "$interpolate_model"
		--backend "$backend"
	)
	if [[ "$verbose" == true ]]; then
		interpolate_args+=(--verbose)
	fi

	if ! cmd_interpolate "${interpolate_args[@]}"; then
		rm -rf "$temp_dir"
		return 1
	fi

	# Step 3: Denoise (optional)
	if [[ "$denoise" == true ]]; then
		print_info "[3/3] Denoising..."
		local denoise_args=(
			"$temp_interpolated"
			"$output"
			--model "$denoise_model"
			--backend "$backend"
		)
		if [[ "$verbose" == true ]]; then
			denoise_args+=(--verbose)
		fi

		if ! cmd_denoise "${denoise_args[@]}"; then
			rm -rf "$temp_dir"
			return 1
		fi
	else
		print_info "[3/3] Skipping denoising"
		mv "$temp_interpolated" "$output"
	fi

	# Cleanup
	rm -rf "$temp_dir"

	print_success "Enhancement complete: $output"
	return 0
}

cmd_batch() {
	check_installation || return 1

	local input_dir=""
	local output_dir=""
	local scale="${DEFAULT_SCALE}"
	local fps="${DEFAULT_FPS}"
	local denoise=false
	local backend="${DEFAULT_BACKEND}"
	local parallel=1
	local verbose=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--scale | -s)
			scale="$2"
			shift 2
			;;
		--fps | -f)
			fps="$2"
			shift 2
			;;
		--denoise | -d)
			denoise=true
			shift
			;;
		--backend | -b)
			backend="$2"
			shift 2
			;;
		--parallel | -p)
			parallel="$2"
			shift 2
			;;
		--verbose | -v)
			verbose=true
			shift
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$input_dir" ]]; then
				input_dir="$1"
			elif [[ -z "$output_dir" ]]; then
				output_dir="$1"
			else
				print_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -z "$input_dir" ]] || [[ -z "$output_dir" ]]; then
		print_error "Usage: real-video-enhancer-helper.sh batch <input_dir> <output_dir> [options]"
		print_info "Options:"
		print_info "  --scale, -s <2|4>      Upscale factor (default: ${DEFAULT_SCALE})"
		print_info "  --fps, -f <fps>        Target frame rate (default: ${DEFAULT_FPS})"
		print_info "  --denoise, -d          Enable denoising"
		print_info "  --backend, -b <backend> Backend (tensorrt|pytorch|ncnn|auto)"
		print_info "  --parallel, -p <n>     Process N videos simultaneously (default: 1)"
		print_info "  --verbose, -v          Enable verbose logging"
		return 1
	fi

	if [[ ! -d "$input_dir" ]]; then
		print_error "Input directory not found: $input_dir"
		return 1
	fi

	mkdir -p "$output_dir"

	# Find all video files
	local video_files=()
	while IFS= read -r -d '' file; do
		video_files+=("$file")
	done < <(find "$input_dir" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" \) -print0)

	if [[ ${#video_files[@]} -eq 0 ]]; then
		print_warning "No video files found in $input_dir"
		return 0
	fi

	print_info "Found ${#video_files[@]} video(s) to process"
	print_info "Parallel jobs: $parallel"

	local count=0
	local total=${#video_files[@]}

	for input_file in "${video_files[@]}"; do
		count=$((count + 1))
		local basename
		basename=$(basename "$input_file")
		local output_file="${output_dir}/${basename}"

		print_info "[$count/$total] Processing: $basename"

		local enhance_args=(
			"$input_file"
			"$output_file"
			--scale "$scale"
			--fps "$fps"
			--backend "$backend"
		)

		if [[ "$denoise" == true ]]; then
			enhance_args+=(--denoise)
		fi

		if [[ "$verbose" == true ]]; then
			enhance_args+=(--verbose)
		fi

		if [[ "$parallel" -gt 1 ]]; then
			# Background processing
			cmd_enhance "${enhance_args[@]}" &

			# Wait if we've reached parallel limit
			local running
			running=$(jobs -r | wc -l)
			if [[ "$running" -ge "$parallel" ]]; then
				wait -n
			fi
		else
			# Sequential processing
			if ! cmd_enhance "${enhance_args[@]}"; then
				print_error "Failed to process: $basename"
			fi
		fi
	done

	# Wait for remaining background jobs
	if [[ "$parallel" -gt 1 ]]; then
		wait
	fi

	print_success "Batch processing complete: $output_dir"
	return 0
}

# =============================================================================
# Utility Commands
# =============================================================================

cmd_models() {
	local subcommand="${1:-list}"

	case "$subcommand" in
	list)
		print_info "Available models:"
		print_info ""
		print_info "Interpolation:"
		print_info "  rife        - RIFE (fast, high quality)"
		print_info "  gmfss       - GMFSS (slow, very high quality)"
		print_info "  ifrnet      - IFRNet (very fast, medium quality)"
		print_info ""
		print_info "Upscaling:"
		print_info "  span        - SPAN (fast, high quality)"
		print_info "  realesrgan  - Real-ESRGAN (medium, very high quality)"
		print_info "  animejanai  - AnimeJaNai (medium, anime-optimized)"
		print_info ""
		print_info "Denoising:"
		print_info "  drunet      - DRUnet (medium, high quality)"
		print_info "  dncnn       - DnCNN (fast, medium quality)"
		print_info ""
		print_info "Decompression:"
		print_info "  deh264      - DeH264 (fast, H.264 artifact removal)"
		;;
	download)
		print_error "Model download not yet implemented"
		print_info "Models are downloaded automatically on first use"
		return 1
		;;
	clear)
		if [[ -d "${RVE_MODELS_DIR}" ]]; then
			print_warning "Clearing model cache: ${RVE_MODELS_DIR}"
			rm -rf "${RVE_MODELS_DIR}"
			mkdir -p "${RVE_MODELS_DIR}"
			print_success "Model cache cleared"
		else
			print_info "Model cache already empty"
		fi
		;;
	*)
		print_error "Unknown subcommand: $subcommand"
		print_info "Usage: real-video-enhancer-helper.sh models [list|download|clear]"
		return 1
		;;
	esac

	return 0
}

cmd_backends() {
	local verbose=false

	if [[ "${1:-}" == "--verbose" ]] || [[ "${1:-}" == "-v" ]]; then
		verbose=true
	fi

	print_info "Backend detection:"
	print_info ""

	# Check NVIDIA
	if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
		print_success "NVIDIA GPU detected"
		if [[ "$verbose" == true ]]; then
			nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
		fi

		# Check TensorRT
		if python3 -c "import tensorrt" &>/dev/null 2>&1; then
			print_success "  TensorRT: available (recommended)"
		else
			print_warning "  TensorRT: not installed"
			print_info "    Install: pip install tensorrt"
		fi

		# Check PyTorch CUDA
		if python3 -c "import torch; assert torch.cuda.is_available()" &>/dev/null 2>&1; then
			print_success "  PyTorch CUDA: available"
		else
			print_warning "  PyTorch CUDA: not available"
		fi
	else
		print_warning "NVIDIA GPU: not detected"
	fi

	print_info ""

	# Check AMD
	if command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null 2>&1; then
		print_success "AMD GPU detected"
		if [[ "$verbose" == true ]]; then
			rocm-smi --showproductname
		fi

		if python3 -c "import torch; assert torch.cuda.is_available()" &>/dev/null 2>&1; then
			print_success "  PyTorch ROCm: available"
		else
			print_warning "  PyTorch ROCm: not available"
		fi
	else
		print_warning "AMD GPU: not detected"
	fi

	print_info ""

	# Check NCNN
	if python3 -c "import ncnn" &>/dev/null 2>&1; then
		print_success "NCNN: available (CPU/Vulkan fallback)"
	else
		print_warning "NCNN: not installed"
		print_info "  Install: pip install ncnn"
	fi

	print_info ""

	# Recommended backend
	local recommended
	recommended=$(detect_backend)
	print_info "Recommended backend: $recommended"

	return 0
}

cmd_gui() {
	check_installation || return 1

	print_info "Launching REAL Video Enhancer GUI..."

	local python_cmd
	python_cmd=$(detect_python) || return 1

	cd "${RVE_DIR}" || return 1

	if ! "$python_cmd" -m real_video_enhancer; then
		print_error "Failed to launch GUI"
		print_info "Try running directly: cd ${RVE_DIR} && python3 main.py --gui"
		return 1
	fi

	return 0
}

cmd_help() {
	cat <<EOF
REAL Video Enhancer Helper Script
AI-powered video upscaling, interpolation, and enhancement

Usage: real-video-enhancer-helper.sh <command> [options]

Commands:
  install       Install REAL Video Enhancer with auto-detected backend
  enhance       Full enhancement pipeline (upscale + interpolate + denoise)
  upscale       Upscale video resolution (2x/4x)
  interpolate   Increase frame rate (24fps → 48/60fps)
  denoise       Remove noise from video
  batch         Process multiple videos
  models        Manage models (list, download, clear)
  backends      Show available backends and GPU detection
  gui           Launch Qt GUI
  help          Show this help message

Examples:
  # Install with auto-detected backend
  real-video-enhancer-helper.sh install

  # Upscale video 2x
  real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 2

  # Interpolate to 60fps
  real-video-enhancer-helper.sh interpolate input.mp4 output.mp4 --fps 60

  # Full enhancement pipeline
  real-video-enhancer-helper.sh enhance input.mp4 output.mp4 \\
    --scale 2 --fps 60 --denoise

  # Batch process directory
  real-video-enhancer-helper.sh batch ~/Videos/raw/ ~/Videos/enhanced/ \\
    --scale 2 --fps 48 --parallel 2

  # Check available backends
  real-video-enhancer-helper.sh backends

  # List available models
  real-video-enhancer-helper.sh models list

For more information, see: .agents/tools/video/real-video-enhancer.md
EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"

	case "$command" in
	install)
		shift
		cmd_install "$@"
		;;
	enhance)
		shift
		cmd_enhance "$@"
		;;
	upscale)
		shift
		cmd_upscale "$@"
		;;
	interpolate)
		shift
		cmd_interpolate "$@"
		;;
	denoise)
		shift
		cmd_denoise "$@"
		;;
	batch)
		shift
		cmd_batch "$@"
		;;
	models)
		shift
		cmd_models "$@"
		;;
	backends)
		shift
		cmd_backends "$@"
		;;
	gui)
		shift
		cmd_gui "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		print_info "Run 'real-video-enhancer-helper.sh help' for usage"
		exit 1
		;;
	esac
}

main "$@"
