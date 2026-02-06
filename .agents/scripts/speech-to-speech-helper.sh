#!/bin/bash
# shellcheck disable=SC2034,SC2155

# Speech-to-Speech Helper Script
# Manages HuggingFace speech-to-speech pipeline
# Supports local GPU (CUDA/MPS), Docker, and remote server deployment

set -euo pipefail

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Defaults
readonly S2S_REPO="https://github.com/huggingface/speech-to-speech.git"
readonly S2S_DIR="${HOME}/.aidevops/.agent-workspace/work/speech-to-speech"
readonly S2S_PID_FILE="${S2S_DIR}/.s2s.pid"
readonly S2S_LOG_FILE="${S2S_DIR}/.s2s.log"
readonly DEFAULT_RECV_PORT=12345
readonly DEFAULT_SEND_PORT=12346

print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[OK]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARN]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

# ─── Dependency checks ───────────────────────────────────────────────

check_python() {
    if ! command -v python3 &>/dev/null; then
        print_error "python3 is required but not installed"
        return 1
    fi
    local py_version
    py_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    local major="${py_version%%.*}"
    local minor="${py_version##*.}"
    if [[ "$major" -lt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -lt 10 ]]; }; then
        print_error "Python 3.10+ required, found $py_version"
        return 1
    fi
    print_info "Python $py_version"
    return 0
}

check_uv() {
    if ! command -v uv &>/dev/null; then
        print_warning "uv not found. Install: curl -LsSf https://astral.sh/uv/install.sh | sh"
        print_info "Falling back to pip"
        return 1
    fi
    return 0
}

detect_platform() {
    local platform
    platform=$(uname -s)
    case "$platform" in
        Darwin)
            if [[ "$(uname -m)" == "arm64" ]]; then
                echo "mac-arm64"
            else
                echo "mac-x86"
            fi
            ;;
        Linux)
            if command -v nvidia-smi &>/dev/null; then
                echo "linux-cuda"
            else
                echo "linux-cpu"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
    return 0
}

detect_gpu() {
    local platform
    platform=$(detect_platform)
    case "$platform" in
        mac-arm64)
            print_info "Apple Silicon detected (MPS acceleration)"
            echo "mps"
            ;;
        linux-cuda)
            local gpu_info
            gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "unknown")
            print_info "NVIDIA GPU: $gpu_info"
            echo "cuda"
            ;;
        *)
            print_warning "No GPU acceleration detected, using CPU"
            echo "cpu"
            ;;
    esac
    return 0
}

# ─── Setup ────────────────────────────────────────────────────────────

cmd_setup() {
    print_info "Setting up speech-to-speech pipeline..."

    check_python || return 1

    # Clone or update repo
    if [[ -d "$S2S_DIR/.git" ]]; then
        print_info "Updating existing installation..."
        git -C "$S2S_DIR" pull --ff-only 2>/dev/null || {
            print_warning "Could not fast-forward, repo may have local changes"
        }
    else
        print_info "Cloning speech-to-speech..."
        mkdir -p "$(dirname "$S2S_DIR")"
        git clone "$S2S_REPO" "$S2S_DIR"
    fi

    # Install dependencies based on platform
    local platform
    platform=$(detect_platform)
    local req_file="requirements.txt"
    if [[ "$platform" == "mac-arm64" ]] || [[ "$platform" == "mac-x86" ]]; then
        req_file="requirements_mac.txt"
    fi

    print_info "Installing dependencies from $req_file..."
    if check_uv; then
        uv pip install -r "${S2S_DIR}/${req_file}"
    else
        pip install -r "${S2S_DIR}/${req_file}"
    fi

    # Download NLTK data
    print_info "Downloading NLTK data..."
    python3 -c "import nltk; nltk.download('punkt_tab'); nltk.download('averaged_perceptron_tagger_eng')" >/dev/null

    print_success "Setup complete. Run: speech-to-speech-helper.sh start"
    return 0
}

# ─── Start pipeline ──────────────────────────────────────────────────

cmd_start() {
    local mode=""
    local language="en"
    local extra_args=()
    local background=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-mac)    mode="local-mac"; shift ;;
            --cuda)         mode="cuda"; shift ;;
            --server)       mode="server"; shift ;;
            --docker)       mode="docker"; shift ;;
            --language)     language="$2"; shift 2 ;;
            --background)   background=true; shift ;;
            *)              extra_args+=("$1"); shift ;;
        esac
    done

    if [[ -z "$mode" ]]; then
        local gpu
        gpu=$(detect_gpu)
        case "$gpu" in
            mps)  mode="local-mac" ;;
            cuda) mode="cuda" ;;
            *)    mode="cuda" ;;
        esac
        print_info "Auto-detected mode: $mode"
    fi

    # Check if already running
    if [[ -f "$S2S_PID_FILE" ]]; then
        local pid
        pid=$(cat "$S2S_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            print_warning "Pipeline already running (PID $pid). Use 'stop' first."
            return 1
        fi
        rm -f "$S2S_PID_FILE"
    fi

    if [[ ! -d "$S2S_DIR/.git" ]]; then
        print_error "Not installed. Run: speech-to-speech-helper.sh setup"
        return 1
    fi

    local cmd_args=()

    case "$mode" in
        local-mac)
            cmd_args=(
                python3 s2s_pipeline.py
                --local_mac_optimal_settings
                --device mps
                --language "$language"
            )
            if [[ "$language" == "auto" ]]; then
                cmd_args+=(--stt_model_name large-v3)
                cmd_args+=(--mlx_lm_model_name mlx-community/Meta-Llama-3.1-8B-Instruct-4bit)
            fi
            ;;
        cuda)
            cmd_args=(
                python3 s2s_pipeline.py
                --recv_host 0.0.0.0
                --send_host 0.0.0.0
                --lm_model_name microsoft/Phi-3-mini-4k-instruct
                --stt_compile_mode reduce-overhead
                --tts_compile_mode default
                --language "$language"
            )
            ;;
        server)
            cmd_args=(
                python3 s2s_pipeline.py
                --recv_host 0.0.0.0
                --send_host 0.0.0.0
                --language "$language"
            )
            ;;
        docker)
            cmd_docker_start "${extra_args[@]}"
            return $?
            ;;
    esac

    # Append any extra args
    cmd_args+=("${extra_args[@]}")

    print_info "Starting pipeline (mode: $mode, language: $language)..."
    print_info "Command: ${cmd_args[*]}"

    if [[ "$background" == true ]]; then
        (cd "$S2S_DIR" && "${cmd_args[@]}" > "$S2S_LOG_FILE" 2>&1 &
         echo $! > "$S2S_PID_FILE")
        local pid
        pid=$(cat "$S2S_PID_FILE")
        print_success "Pipeline started in background (PID $pid)"
        print_info "Logs: tail -f $S2S_LOG_FILE"
    else
        (cd "$S2S_DIR" && exec "${cmd_args[@]}")
    fi

    return 0
}

cmd_docker_start() {
    if ! command -v docker &>/dev/null; then
        print_error "Docker is not installed"
        return 1
    fi

    if [[ ! -f "${S2S_DIR}/docker-compose.yml" ]]; then
        print_error "docker-compose.yml not found. Run setup first."
        return 1
    fi

    print_info "Starting with Docker..."
    (cd "$S2S_DIR" && docker compose up -d)
    print_success "Docker containers started"
    print_info "Ports: ${DEFAULT_RECV_PORT} (recv), ${DEFAULT_SEND_PORT} (send)"
    return 0
}

# ─── Client ───────────────────────────────────────────────────────────

cmd_client() {
    local host=""
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host) host="$2"; shift 2 ;;
            *)      extra_args+=("$1"); shift ;;
        esac
    done

    if [[ -z "$host" ]]; then
        print_error "Server host required: --host <ip>"
        return 1
    fi

    if [[ ! -f "${S2S_DIR}/listen_and_play.py" ]]; then
        print_error "Not installed. Run: speech-to-speech-helper.sh setup"
        return 1
    fi

    print_info "Connecting to server at $host..."
    (cd "$S2S_DIR" && python3 listen_and_play.py --host "$host" "${extra_args[@]}")
    return 0
}

# ─── Stop ─────────────────────────────────────────────────────────────

cmd_stop() {
    # Stop background process
    if [[ -f "$S2S_PID_FILE" ]]; then
        local pid
        pid=$(cat "$S2S_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            print_info "Stopping pipeline (PID $pid)..."
            kill "$pid"
            sleep 2
            if kill -0 "$pid" 2>/dev/null; then
                print_warning "Force killing..."
                kill -9 "$pid" 2>/dev/null || true
            fi
            print_success "Pipeline stopped"
        else
            print_info "Process not running"
        fi
        rm -f "$S2S_PID_FILE"
    else
        print_info "No PID file found"
    fi

    # Stop Docker if running
    if [[ -f "${S2S_DIR}/docker-compose.yml" ]]; then
        if docker compose -f "${S2S_DIR}/docker-compose.yml" ps --quiet 2>/dev/null | grep -q .; then
            print_info "Stopping Docker containers..."
            (cd "$S2S_DIR" && docker compose down)
            print_success "Docker containers stopped"
        fi
    fi

    return 0
}

# ─── Status ───────────────────────────────────────────────────────────

cmd_status() {
    echo "=== Speech-to-Speech Status ==="
    echo ""

    # Installation
    if [[ -d "$S2S_DIR/.git" ]]; then
        local commit
        commit=$(git -C "$S2S_DIR" log -1 --format='%h %s' 2>/dev/null || echo "unknown")
        print_success "Installed: $S2S_DIR"
        print_info "Commit: $commit"
    else
        print_warning "Not installed. Run: speech-to-speech-helper.sh setup"
        return 0
    fi

    # Platform
    local platform
    platform=$(detect_platform)
    local gpu
    gpu=$(detect_gpu)
    print_info "Platform: $platform (accelerator: $gpu)"

    # Process
    if [[ -f "$S2S_PID_FILE" ]]; then
        local pid
        pid=$(cat "$S2S_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            print_success "Running (PID $pid)"
        else
            print_warning "Stale PID file (process not running)"
            rm -f "$S2S_PID_FILE"
        fi
    else
        print_info "Not running"
    fi

    # Docker
    if command -v docker &>/dev/null && [[ -f "${S2S_DIR}/docker-compose.yml" ]]; then
        local docker_status
        docker_status=$(docker compose -f "${S2S_DIR}/docker-compose.yml" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || echo "not running")
        if echo "$docker_status" | grep -qi "up"; then
            print_success "Docker: running"
            echo "$docker_status"
        else
            print_info "Docker: not running"
        fi
    fi

    echo ""
    return 0
}

# ─── Config presets ───────────────────────────────────────────────────

cmd_config() {
    local preset="${1:-}"

    case "$preset" in
        low-latency)
            echo "--stt faster-whisper --llm open_api --tts parler --stt_compile_mode reduce-overhead --tts_compile_mode default"
            ;;
        low-vram)
            echo "--stt moonshine --llm open_api --tts pocket"
            ;;
        quality)
            echo "--stt whisper --stt_model_name openai/whisper-large-v3 --llm transformers --lm_model_name microsoft/Phi-3-mini-4k-instruct --tts parler"
            ;;
        mac)
            echo "--local_mac_optimal_settings --device mps --mlx_lm_model_name mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"
            ;;
        multilingual)
            echo "--stt_model_name large-v3 --language auto --tts melo"
            ;;
        *)
            echo "Available presets:"
            echo "  low-latency   - Fastest response (CUDA + OpenAI API)"
            echo "  low-vram      - Minimal GPU memory (~4GB)"
            echo "  quality       - Best quality (24GB+ VRAM)"
            echo "  mac           - Optimal macOS Apple Silicon"
            echo "  multilingual  - Auto language detection (6 languages)"
            echo ""
            echo "Usage: speech-to-speech-helper.sh start \$(speech-to-speech-helper.sh config low-latency)"
            ;;
    esac
    return 0
}

# ─── Benchmark ────────────────────────────────────────────────────────

cmd_benchmark() {
    if [[ ! -d "$S2S_DIR/.git" ]]; then
        print_error "Not installed. Run: speech-to-speech-helper.sh setup"
        return 1
    fi

    if [[ ! -f "${S2S_DIR}/benchmark_stt.py" ]]; then
        print_error "Benchmark script not found in repo"
        return 1
    fi

    print_info "Running STT benchmark..."
    (cd "$S2S_DIR" && python3 benchmark_stt.py "$@")
    return 0
}

# ─── Help ─────────────────────────────────────────────────────────────

cmd_help() {
    echo "Speech-to-Speech Helper"
    echo "Manages HuggingFace speech-to-speech pipeline"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  setup                Install/update the pipeline"
    echo "  start [options]      Start the pipeline"
    echo "  stop                 Stop running pipeline"
    echo "  status               Show installation and runtime status"
    echo "  client --host <ip>   Connect to remote server"
    echo "  config [preset]      Show configuration presets"
    echo "  benchmark            Run STT benchmark"
    echo "  help                 Show this help"
    echo ""
    echo "Start options:"
    echo "  --local-mac          macOS Apple Silicon (auto-detected)"
    echo "  --cuda               NVIDIA GPU with torch compile"
    echo "  --server             Server mode (remote clients connect)"
    echo "  --docker             Docker with NVIDIA GPU"
    echo "  --language <code>    Language: en, fr, es, zh, ja, ko, auto"
    echo "  --background         Run in background"
    echo ""
    echo "Examples:"
    echo "  $0 setup"
    echo "  $0 start --local-mac"
    echo "  $0 start --cuda --language auto --background"
    echo "  $0 start --server"
    echo "  $0 client --host 192.168.1.100"
    echo "  $0 start \$($0 config low-latency)"
    echo "  $0 stop"
    echo ""
    echo "Install dir: $S2S_DIR"
    return 0
}

# ─── Main ─────────────────────────────────────────────────────────────

main() {
    local command="${1:-help}"
    if [[ $# -gt 0 ]]; then
        shift
    fi

    case "$command" in
        setup)      cmd_setup "$@" ;;
        start)      cmd_start "$@" ;;
        stop)       cmd_stop "$@" ;;
        status)     cmd_status "$@" ;;
        client)     cmd_client "$@" ;;
        config)     cmd_config "$@" ;;
        benchmark)  cmd_benchmark "$@" ;;
        help|--help|-h) cmd_help ;;
        *)
            print_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
