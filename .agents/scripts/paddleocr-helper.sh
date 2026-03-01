#!/usr/bin/env bash

# PaddleOCR Helper - Scene text / screenshot OCR for aidevops
# Manages PaddleOCR installation, image-to-text extraction, and MCP server lifecycle.
# Complements MinerU (document-to-markdown) and Docling (structured extraction) —
# PaddleOCR is the specialist for raw OCR from screenshots, photos, and scene images.
#
# Usage: paddleocr-helper.sh [command] [options]
#
# Commands:
#   install [--update]          Install/update PaddleOCR + PaddlePaddle (alias: setup)
#   ocr <image> [options]       Extract text from image/screenshot
#   serve [--port N]            Start PaddleOCR MCP server (alias: start)
#   stop                        Stop running MCP server
#   status                      Show installation and server status
#   models [--json]             List available/downloaded OCR models
#   help                        Show this help
#
# Options:
#   --lang LANG       OCR language (default: en, multi: en,ch,ja,ko,fr,de,...)
#   --model MODEL     Model name (default: PP-OCRv5)
#   --det-model M     Detection model override
#   --rec-model M     Recognition model override
#   --output FILE     Write OCR text to file instead of stdout
#   --format FMT      Output format: text (default), json, tsv
#   --port N          MCP server port (default: 8868)
#   --json            Output in JSON format (for models/status)
#   --quiet           Suppress informational output
#   --venv PATH       Custom virtualenv path (default: ~/.aidevops/paddleocr/venv)
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Dependency missing (Python, pip)
#   3 - Model not found / image not found
#   4 - Server already running / not running
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# =============================================================================
# Configuration
# =============================================================================

readonly PADDLEOCR_DIR="${HOME}/.aidevops/paddleocr"
readonly PADDLEOCR_VENV_DEFAULT="${PADDLEOCR_DIR}/venv"
readonly PADDLEOCR_PID_FILE="${PADDLEOCR_DIR}/mcp-server.pid"
readonly PADDLEOCR_LOG_FILE="${PADDLEOCR_DIR}/mcp-server.log"
readonly PADDLEOCR_CONFIG_FILE="${PADDLEOCR_DIR}/config.json"
readonly PADDLEOCR_MODELS_DIR="${PADDLEOCR_DIR}/models"

# Defaults
PADDLEOCR_PORT=8868
PADDLEOCR_LANG="en"
PADDLEOCR_MODEL="PP-OCRv5"
PADDLEOCR_VENV="${PADDLEOCR_VENV_DEFAULT}"

# Minimum Python version required
readonly PYTHON_MIN_VERSION="3.8"

# =============================================================================
# Utility Functions
# =============================================================================

# Ensure the paddleocr directory structure exists
ensure_dirs() {
	mkdir -p "$PADDLEOCR_DIR" 2>/dev/null || true
	mkdir -p "$PADDLEOCR_MODELS_DIR" 2>/dev/null || true
	return 0
}

# Find a suitable Python 3 interpreter
find_python() {
	local python_cmd=""
	if command -v python3 &>/dev/null; then
		python_cmd="python3"
	elif command -v python &>/dev/null; then
		# Verify it's Python 3
		local ver
		ver="$(python --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
		if [[ "${ver%%.*}" -ge 3 ]]; then
			python_cmd="python"
		fi
	fi

	if [[ -z "$python_cmd" ]]; then
		print_error "Python 3 not found. Install Python ${PYTHON_MIN_VERSION}+ first."
		return 2
	fi

	echo "$python_cmd"
	return 0
}

# Find pip for the active Python
find_pip() {
	local pip_cmd=""
	# If inside a venv, use its pip
	if [[ -n "${VIRTUAL_ENV:-}" ]]; then
		if command -v pip &>/dev/null; then
			pip_cmd="pip"
		fi
	fi

	if [[ -z "$pip_cmd" ]]; then
		if command -v pip3 &>/dev/null; then
			pip_cmd="pip3"
		elif command -v pip &>/dev/null; then
			pip_cmd="pip"
		fi
	fi

	if [[ -z "$pip_cmd" ]]; then
		print_error "pip not found. Install pip first."
		return 2
	fi

	echo "$pip_cmd"
	return 0
}

# Activate the PaddleOCR virtualenv if it exists
activate_venv() {
	local venv_path="$1"
	if [[ -f "${venv_path}/bin/activate" ]]; then
		# shellcheck source=/dev/null
		source "${venv_path}/bin/activate"
		return 0
	fi
	return 1
}

# Create a virtualenv for PaddleOCR
create_venv() {
	local venv_path="$1"
	local python_cmd
	python_cmd="$(find_python)" || return $?

	if [[ -d "$venv_path" ]]; then
		print_info "Virtualenv already exists: ${venv_path}"
		return 0
	fi

	print_info "Creating virtualenv at ${venv_path}..."
	if ! log_stderr "create_venv" "$python_cmd" -m venv "$venv_path"; then
		print_error "Failed to create virtualenv. Ensure python3-venv is installed."
		return 1
	fi

	print_success "Virtualenv created: ${venv_path}"
	return 0
}

# Load config.json defaults if present
load_config() {
	if [[ -f "$PADDLEOCR_CONFIG_FILE" ]] && command -v jq &>/dev/null; then
		PADDLEOCR_PORT="$(jq -r '.port // 8868' "$PADDLEOCR_CONFIG_FILE" 2>/dev/null || echo "8868")"
		PADDLEOCR_LANG="$(jq -r '.lang // "en"' "$PADDLEOCR_CONFIG_FILE" 2>/dev/null || echo "en")"
		PADDLEOCR_MODEL="$(jq -r '.model // "PP-OCRv5"' "$PADDLEOCR_CONFIG_FILE" 2>/dev/null || echo "PP-OCRv5")"
		local venv_cfg
		venv_cfg="$(jq -r '.venv // ""' "$PADDLEOCR_CONFIG_FILE" 2>/dev/null || echo "")"
		if [[ -n "$venv_cfg" ]]; then
			PADDLEOCR_VENV="$venv_cfg"
		fi
	fi
	return 0
}

# Write default config.json if it doesn't exist
write_default_config() {
	if [[ ! -f "$PADDLEOCR_CONFIG_FILE" ]]; then
		cat >"$PADDLEOCR_CONFIG_FILE" <<-CONFIGEOF
			{
			  "port": ${PADDLEOCR_PORT},
			  "lang": "${PADDLEOCR_LANG}",
			  "model": "${PADDLEOCR_MODEL}",
			  "venv": "${PADDLEOCR_VENV}"
			}
		CONFIGEOF
		print_info "Created default config at ${PADDLEOCR_CONFIG_FILE}"
	fi
	return 0
}

# Detect platform for PaddlePaddle package selection
detect_paddle_platform() {
	local os arch
	os="$(uname -s)"
	arch="$(uname -m)"

	case "$os" in
	Darwin)
		case "$arch" in
		arm64) echo "macos-arm64" ;;
		x86_64) echo "macos-x64" ;;
		*)
			print_error "Unsupported macOS architecture: ${arch}"
			return 1
			;;
		esac
		;;
	Linux)
		case "$arch" in
		x86_64)
			if command -v nvidia-smi &>/dev/null; then
				echo "linux-gpu"
			else
				echo "linux-cpu"
			fi
			;;
		aarch64) echo "linux-arm64" ;;
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
	return 0
}

# =============================================================================
# Command: install
# =============================================================================

cmd_install() {
	local update_mode=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--update)
			update_mode=true
			shift
			;;
		--venv)
			PADDLEOCR_VENV="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	ensure_dirs

	# Detect platform
	local platform
	platform="$(detect_paddle_platform)" || return $?
	print_info "Platform: ${platform}"

	# Find Python
	local python_cmd
	python_cmd="$(find_python)" || return $?
	local python_version
	python_version="$("$python_cmd" --version 2>&1)"
	print_info "Python: ${python_version}"

	# Create/activate virtualenv
	create_venv "$PADDLEOCR_VENV" || return $?
	activate_venv "$PADDLEOCR_VENV" || {
		print_error "Failed to activate virtualenv at ${PADDLEOCR_VENV}"
		return 1
	}
	print_info "Virtualenv: ${PADDLEOCR_VENV}"

	# Find pip inside venv
	local pip_cmd
	pip_cmd="$(find_pip)" || return $?

	# Upgrade pip first
	print_info "Upgrading pip..."
	log_stderr "pip upgrade" "$pip_cmd" install --quiet --upgrade pip 2>&1 || true

	# Install PaddlePaddle
	print_info "Installing PaddlePaddle..."
	local paddle_pkg="paddlepaddle"
	case "$platform" in
	linux-gpu)
		paddle_pkg="paddlepaddle-gpu"
		print_info "GPU detected — installing paddlepaddle-gpu"
		;;
	*)
		print_info "Installing CPU version of PaddlePaddle"
		;;
	esac

	local pip_flags=(install --quiet)
	if [[ "$update_mode" == "true" ]]; then
		pip_flags+=(--upgrade)
	fi

	if ! log_stderr "install paddlepaddle" "$pip_cmd" "${pip_flags[@]}" "$paddle_pkg"; then
		print_error "Failed to install ${paddle_pkg}"
		print_info "Try manually: ${pip_cmd} install ${paddle_pkg}"
		return 1
	fi
	print_success "PaddlePaddle installed"

	# Install PaddleOCR
	print_info "Installing PaddleOCR..."
	if ! log_stderr "install paddleocr" "$pip_cmd" "${pip_flags[@]}" "paddleocr"; then
		print_error "Failed to install paddleocr"
		print_info "Try manually: ${pip_cmd} install paddleocr"
		return 1
	fi
	print_success "PaddleOCR installed"

	# Verify installation
	print_info "Verifying installation..."
	local verify_script='import paddleocr; print(f"PaddleOCR {paddleocr.__version__}")'
	local version_str
	if version_str="$(python3 -c "$verify_script" 2>/dev/null)"; then
		print_success "Verified: ${version_str}"
	else
		print_warning "PaddleOCR installed but version check failed — may work on first use"
	fi

	# Write default config
	write_default_config

	print_success "Installation complete"
	print_info "Next steps:"
	print_info "  paddleocr-helper.sh ocr <image>    Extract text from an image"
	print_info "  paddleocr-helper.sh models          List available models"
	print_info "  paddleocr-helper.sh serve            Start MCP server"
	return 0
}

# =============================================================================
# Command: ocr
# =============================================================================

cmd_ocr() {
	local image_path=""
	local lang="$PADDLEOCR_LANG"
	local output_file=""
	local output_format="text"
	local det_model=""
	local rec_model=""
	local quiet=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--lang)
			lang="$2"
			shift 2
			;;
		--output)
			output_file="$2"
			shift 2
			;;
		--format)
			output_format="$2"
			shift 2
			;;
		--det-model)
			det_model="$2"
			shift 2
			;;
		--rec-model)
			rec_model="$2"
			shift 2
			;;
		--quiet)
			quiet=true
			shift
			;;
		--venv)
			PADDLEOCR_VENV="$2"
			shift 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$image_path" ]]; then
				image_path="$1"
			fi
			shift
			;;
		esac
	done

	# Validate image path
	if [[ -z "$image_path" ]]; then
		print_error "Image path is required"
		print_info "Usage: paddleocr-helper.sh ocr <image> [--lang en] [--format text|json|tsv]"
		return 1
	fi

	if [[ ! -f "$image_path" ]]; then
		print_error "Image not found: ${image_path}"
		return 3
	fi

	# Activate venv if available
	if [[ -f "${PADDLEOCR_VENV}/bin/activate" ]]; then
		activate_venv "$PADDLEOCR_VENV" || true
	fi

	# Verify paddleocr is importable
	if ! python3 -c "import paddleocr" 2>/dev/null; then
		print_error "PaddleOCR not installed. Run: paddleocr-helper.sh install"
		return 2
	fi

	if [[ "$quiet" == "false" ]]; then
		print_info "Processing: ${image_path} (lang=${lang})" >&2
	fi

	# Build the Python OCR script
	local python_script
	python_script="$(
		cat <<'PYEOF'
import sys
import json

# Suppress PaddlePaddle warnings
import os
os.environ["GLOG_minloglevel"] = "2"

from paddleocr import PaddleOCR

image_path = sys.argv[1]
lang = sys.argv[2]
output_format = sys.argv[3]
det_model = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
rec_model = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None

kwargs = {
    "use_angle_cls": True,
    "lang": lang,
    "show_log": False,
}
if det_model:
    kwargs["det_model_dir"] = det_model
if rec_model:
    kwargs["rec_model_dir"] = rec_model

ocr = PaddleOCR(**kwargs)
result = ocr.ocr(image_path, cls=True)

if result is None or len(result) == 0:
    if output_format == "json":
        print("[]")
    sys.exit(0)

if output_format == "json":
    entries = []
    for page in result:
        if page is None:
            continue
        for line in page:
            box = line[0]
            text = line[1][0]
            confidence = line[1][1]
            entries.append({
                "text": text,
                "confidence": round(confidence, 4),
                "box": box,
            })
    print(json.dumps(entries, ensure_ascii=False, indent=2))

elif output_format == "tsv":
    print("text\tconfidence\tx1\ty1\tx2\ty2\tx3\ty3\tx4\ty4")
    for page in result:
        if page is None:
            continue
        for line in page:
            box = line[0]
            text = line[1][0]
            confidence = line[1][1]
            coords = "\t".join(f"{p[0]:.0f}\t{p[1]:.0f}" for p in box)
            print(f"{text}\t{confidence:.4f}\t{coords}")

else:
    # Plain text output
    for page in result:
        if page is None:
            continue
        for line in page:
            text = line[1][0]
            print(text)
PYEOF
	)"

	# Run OCR
	local ocr_output
	if ! ocr_output="$(python3 -c "$python_script" "$image_path" "$lang" "$output_format" "$det_model" "$rec_model" 2>/dev/null)"; then
		print_error "OCR processing failed for: ${image_path}"
		print_info "Try running with verbose output:"
		print_info "  python3 -c 'from paddleocr import PaddleOCR; ocr = PaddleOCR(lang=\"${lang}\"); print(ocr.ocr(\"${image_path}\"))'"
		return 1
	fi

	# Output results
	if [[ -n "$output_file" ]]; then
		echo "$ocr_output" >"$output_file"
		if [[ "$quiet" == "false" ]]; then
			local line_count
			line_count="$(echo "$ocr_output" | wc -l | tr -d ' ')"
			print_success "OCR output written to ${output_file} (${line_count} lines)" >&2
		fi
	else
		echo "$ocr_output"
	fi

	return 0
}

# =============================================================================
# Command: serve
# =============================================================================

cmd_serve() {
	local port="$PADDLEOCR_PORT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--port)
			port="$2"
			shift 2
			;;
		--venv)
			PADDLEOCR_VENV="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Activate venv if available
	if [[ -f "${PADDLEOCR_VENV}/bin/activate" ]]; then
		activate_venv "$PADDLEOCR_VENV" || true
	fi

	# Verify paddleocr is importable
	if ! python3 -c "import paddleocr" 2>/dev/null; then
		print_error "PaddleOCR not installed. Run: paddleocr-helper.sh install"
		return 2
	fi

	# Check if already running
	if [[ -f "$PADDLEOCR_PID_FILE" ]]; then
		local existing_pid
		existing_pid="$(cat "$PADDLEOCR_PID_FILE")"
		if kill -0 "$existing_pid" 2>/dev/null; then
			print_error "MCP server already running (PID ${existing_pid}). Stop it first: paddleocr-helper.sh stop"
			return 4
		else
			# Stale PID file
			rm -f "$PADDLEOCR_PID_FILE"
		fi
	fi

	ensure_dirs

	# Build the MCP server launch script
	# PaddleOCR 3.1.0+ ships a native MCP server via paddleocr.tools.mcp
	local server_script
	server_script="$(
		cat <<'PYEOF'
import sys
import os

os.environ["GLOG_minloglevel"] = "2"

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8868

try:
    # PaddleOCR 3.1.0+ native MCP server
    from paddleocr.tools.mcp import main as mcp_main
    mcp_main(port=port)
except ImportError:
    # Fallback: simple HTTP OCR endpoint for older versions
    import json
    from http.server import HTTPServer, BaseHTTPRequestHandler
    from paddleocr import PaddleOCR

    ocr_engine = PaddleOCR(use_angle_cls=True, lang="en", show_log=False)

    class OCRHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            try:
                data = json.loads(body)
                image_path = data.get("image", "")
                lang = data.get("lang", "en")
                if not image_path or not os.path.isfile(image_path):
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(json.dumps({"error": "Invalid image path"}).encode())
                    return
                result = ocr_engine.ocr(image_path, cls=True)
                entries = []
                if result:
                    for page in result:
                        if page is None:
                            continue
                        for line in page:
                            entries.append({
                                "text": line[1][0],
                                "confidence": round(line[1][1], 4),
                                "box": line[0],
                            })
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(entries, ensure_ascii=False).encode())
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())

        def log_message(self, format, *args):
            pass  # Suppress request logging

    server = HTTPServer(("127.0.0.1", port), OCRHandler)
    print(f"PaddleOCR HTTP server listening on http://127.0.0.1:{port}", flush=True)
    print("POST /ocr with JSON body: {\"image\": \"/path/to/image.png\", \"lang\": \"en\"}", flush=True)
    server.serve_forever()
PYEOF
	)"

	print_info "Starting PaddleOCR server on port ${port}..."

	# Start server in background
	nohup python3 -c "$server_script" "$port" >"$PADDLEOCR_LOG_FILE" 2>&1 &
	local server_pid=$!
	echo "$server_pid" >"$PADDLEOCR_PID_FILE"

	# Wait briefly and verify it started
	sleep 3
	if ! kill -0 "$server_pid" 2>/dev/null; then
		print_error "Server failed to start. Check log: ${PADDLEOCR_LOG_FILE}"
		rm -f "$PADDLEOCR_PID_FILE"
		tail -20 "$PADDLEOCR_LOG_FILE" 2>/dev/null
		return 1
	fi

	print_success "PaddleOCR server running (PID ${server_pid})"
	print_info "Port: ${port}"
	print_info "Log:  ${PADDLEOCR_LOG_FILE}"
	return 0
}

# =============================================================================
# Command: stop
# =============================================================================

cmd_stop() {
	if [[ ! -f "$PADDLEOCR_PID_FILE" ]]; then
		print_info "No server PID file found — server may not be running"
		# Try to find and kill any paddleocr server process
		local pids
		pids="$(pgrep -f "paddleocr.*mcp\|paddleocr.*server\|OCRHandler" 2>/dev/null || true)"
		if [[ -n "$pids" ]]; then
			print_info "Found PaddleOCR server process(es): ${pids}"
			echo "$pids" | while read -r pid; do
				kill "$pid" 2>/dev/null || true
			done
			print_success "Sent SIGTERM to PaddleOCR server process(es)"
		else
			print_info "No PaddleOCR server processes found"
		fi
		return 0
	fi

	local pid
	pid="$(cat "$PADDLEOCR_PID_FILE")"
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
		# Wait for graceful shutdown
		local retries=0
		while [[ $retries -lt 10 ]] && kill -0 "$pid" 2>/dev/null; do
			sleep 1
			retries=$((retries + 1))
		done
		if kill -0 "$pid" 2>/dev/null; then
			print_warning "Server did not stop gracefully, sending SIGKILL"
			kill -9 "$pid" 2>/dev/null || true
		fi
		print_success "PaddleOCR server stopped (PID ${pid})"
	else
		print_info "Server was not running (stale PID file)"
	fi

	rm -f "$PADDLEOCR_PID_FILE"
	return 0
}

# =============================================================================
# Command: status
# =============================================================================

cmd_status() {
	local json_output=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		*) shift ;;
		esac
	done

	local installed=false
	local version_str=""
	local server_running=false
	local server_pid=""
	local venv_exists=false

	# Check virtualenv
	if [[ -d "$PADDLEOCR_VENV" ]]; then
		venv_exists=true
	fi

	# Check installation
	if [[ -f "${PADDLEOCR_VENV}/bin/activate" ]]; then
		activate_venv "$PADDLEOCR_VENV" || true
	fi
	if python3 -c "import paddleocr" 2>/dev/null; then
		installed=true
		version_str="$(python3 -c 'import paddleocr; print(paddleocr.__version__)' 2>/dev/null || echo "unknown")"
	fi

	# Check server
	if [[ -f "$PADDLEOCR_PID_FILE" ]]; then
		server_pid="$(cat "$PADDLEOCR_PID_FILE")"
		if kill -0 "$server_pid" 2>/dev/null; then
			server_running=true
		else
			rm -f "$PADDLEOCR_PID_FILE"
			server_pid=""
		fi
	fi

	if [[ "$json_output" == "true" ]]; then
		cat <<-JSONEOF
			{
			  "installed": ${installed},
			  "version": "${version_str}",
			  "venv": "${PADDLEOCR_VENV}",
			  "venv_exists": ${venv_exists},
			  "server_running": ${server_running},
			  "server_pid": "${server_pid}",
			  "port": ${PADDLEOCR_PORT}
			}
		JSONEOF
		return 0
	fi

	echo "PaddleOCR Status"
	echo "================"

	if [[ "$installed" == "true" ]]; then
		echo -e "Installed: ${GREEN}yes${NC} (v${version_str})"
	else
		echo -e "Installed: ${YELLOW}no${NC}"
		echo "  Install: paddleocr-helper.sh install"
	fi

	if [[ "$venv_exists" == "true" ]]; then
		local venv_size
		venv_size="$(du -sh "$PADDLEOCR_VENV" 2>/dev/null | awk '{print $1}' || echo "unknown")"
		echo "Venv:      ${PADDLEOCR_VENV} (${venv_size})"
	else
		echo "Venv:      not created"
	fi

	if [[ "$server_running" == "true" ]]; then
		echo -e "Server:    ${GREEN}running${NC} (PID ${server_pid}, port ${PADDLEOCR_PORT})"
	else
		echo -e "Server:    ${YELLOW}not running${NC}"
	fi

	# Show model cache info
	local model_cache_dir="${HOME}/.paddleocr"
	if [[ -d "$model_cache_dir" ]]; then
		local cache_size
		cache_size="$(du -sh "$model_cache_dir" 2>/dev/null | awk '{print $1}' || echo "unknown")"
		echo "Models:    ${model_cache_dir} (${cache_size})"
	else
		echo "Models:    no models cached yet (downloaded on first use)"
	fi

	return 0
}

# =============================================================================
# Command: models
# =============================================================================

cmd_models() {
	local json_output=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		*) shift ;;
		esac
	done

	# Available model families
	local -a model_names=(
		"PP-OCRv5"
		"PP-OCRv4"
		"PP-OCRv3"
		"PP-OCRv2"
		"PP-OCR"
		"PP-StructureV2"
		"PaddleOCR-VL-0.9B"
	)
	local -a model_descriptions=(
		"Latest: text detection + recognition, 100+ languages (recommended)"
		"Stable: text detection + recognition, 80+ languages"
		"Legacy: text detection + recognition, 80+ languages"
		"Legacy: text detection + recognition"
		"Original: text detection + recognition"
		"Table/layout recognition and document structure parsing"
		"Vision-language model for document understanding (0.9B params)"
	)
	local -a model_sizes=(
		"~15 MB (det) + ~12 MB (rec)"
		"~4.7 MB (det) + ~10 MB (rec)"
		"~3.8 MB (det) + ~12 MB (rec)"
		"~3 MB (det) + ~8 MB (rec)"
		"~3 MB (det) + ~5 MB (rec)"
		"~110 MB (table + layout)"
		"~1.8 GB"
	)

	# Check which models are cached locally
	local model_cache_dir="${HOME}/.paddleocr"

	if [[ "$json_output" == "true" ]]; then
		echo "["
		local first=true
		local idx=0
		for name in "${model_names[@]}"; do
			local cached=false
			# Check if model directory exists in cache
			local cache_pattern
			cache_pattern="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
			if [[ -d "$model_cache_dir" ]] && find "$model_cache_dir" -maxdepth 2 -type d -name "*${cache_pattern}*" 2>/dev/null | grep -q .; then
				cached=true
			fi
			[[ "$first" == "true" ]] || echo ","
			first=false
			printf '  {"name": "%s", "description": "%s", "size": "%s", "cached": %s}' \
				"$name" "${model_descriptions[$idx]}" "${model_sizes[$idx]}" "$cached"
			idx=$((idx + 1))
		done
		echo ""
		echo "]"
		return 0
	fi

	printf "%-25s %-60s %s\n" "MODEL" "DESCRIPTION" "SIZE"
	printf "%-25s %-60s %s\n" "-----" "-----------" "----"

	local idx=0
	for name in "${model_names[@]}"; do
		local cached_marker=""
		local cache_pattern
		cache_pattern="$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
		if [[ -d "$model_cache_dir" ]] && find "$model_cache_dir" -maxdepth 2 -type d -name "*${cache_pattern}*" 2>/dev/null | grep -q .; then
			cached_marker=" [cached]"
		fi
		printf "%-25s %-60s %s\n" "${name}${cached_marker}" "${model_descriptions[$idx]}" "${model_sizes[$idx]}"
		idx=$((idx + 1))
	done

	echo ""
	print_info "Models are auto-downloaded on first use. No manual download needed."
	print_info "Default model: PP-OCRv5 (recommended for most use cases)"
	print_info "Cache location: ${model_cache_dir}"
	return 0
}

# =============================================================================
# Command: help
# =============================================================================

cmd_help() {
	cat <<-'HELPEOF'
		PaddleOCR Helper - Scene text / screenshot OCR for aidevops

		Usage: paddleocr-helper.sh <command> [options]

		Commands:
		  install [--update]          Install/update PaddleOCR + PaddlePaddle
		  ocr <image> [options]       Extract text from image/screenshot
		  serve [--port N]            Start PaddleOCR MCP/HTTP server
		  stop                        Stop running server
		  status [--json]             Show installation and server status
		  models [--json]             List available OCR models
		  help                        Show this help

		OCR Options:
		  --lang LANG                 Language (default: en). Multi: en,ch,ja,ko,fr,de,...
		  --format FMT                Output: text (default), json, tsv
		  --output FILE               Write output to file instead of stdout
		  --det-model DIR             Custom detection model directory
		  --rec-model DIR             Custom recognition model directory
		  --quiet                     Suppress informational output

		General Options:
		  --venv PATH                 Custom virtualenv path
		  --port N                    Server port (default: 8868)
		  --json                      JSON output for status/models

		Examples:
		  paddleocr-helper.sh install
		  paddleocr-helper.sh ocr screenshot.png
		  paddleocr-helper.sh ocr photo.jpg --lang ch --format json
		  paddleocr-helper.sh ocr receipt.png --output receipt.txt
		  paddleocr-helper.sh serve --port 9000
		  paddleocr-helper.sh status
		  paddleocr-helper.sh models --json

		Supported Languages (common):
		  en (English), ch (Chinese), ja (Japanese), ko (Korean),
		  fr (French), de (German), es (Spanish), pt (Portuguese),
		  it (Italian), ru (Russian), ar (Arabic), hi (Hindi),
		  and 90+ more. Full list: https://paddlepaddle.github.io/PaddleOCR/

		Architecture:
		  PaddleOCR is the scene text / screenshot OCR specialist.
		  For document parsing, use MinerU (mineru-helper.sh).
		  For structured extraction, use Docling + ExtractThinker.
		  See: tools/ocr/overview.md for the full tool selection guide.
	HELPEOF
	return 0
}

# =============================================================================
# Main Dispatcher
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	# Load config
	load_config

	case "$command" in
	install | setup)
		cmd_install "$@"
		;;
	ocr)
		cmd_ocr "$@"
		;;
	serve | start)
		cmd_serve "$@"
		;;
	stop)
		cmd_stop "$@"
		;;
	status)
		cmd_status "$@"
		;;
	models)
		cmd_models "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		print_info "Run 'paddleocr-helper.sh help' for usage information"
		return 1
		;;
	esac
}

main "$@"
