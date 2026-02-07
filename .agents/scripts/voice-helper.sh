#!/bin/bash
# shellcheck disable=SC2034,SC2155

# Voice Helper Script
# Manages the aidevops voice bridge (talk to OpenCode via speech)
# Swappable STT and TTS engines for speed/quality tuning

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BRIDGE_SCRIPT="${SCRIPT_DIR}/voice-bridge.py"
readonly S2S_DIR="${HOME}/.aidevops/.agent-workspace/work/speech-to-speech"
readonly VENV_DIR="${S2S_DIR}/.venv"
readonly VOICE_PID_FILE="${HOME}/.aidevops/.agent-workspace/tmp/.voice-bridge.pid"

print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} ${msg}"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[OK]${NC} ${msg}"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARN]${NC} ${msg}"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} ${msg}" >&2
    return 0
}

# ─── Dependency checks ───────────────────────────────────────────────

check_venv() {
    if [[ ! -d "${VENV_DIR}" ]]; then
        print_error "Python venv not found at ${VENV_DIR}"
        print_info "Run: speech-to-speech-helper.sh setup"
        return 1
    fi
    return 0
}

check_deps() {
    local missing=()

    # Check core Python deps in venv
    if ! "${VENV_DIR}/bin/python" -c "import sounddevice" 2>/dev/null; then
        missing+=("sounddevice")
    fi
    if ! "${VENV_DIR}/bin/python" -c "import numpy" 2>/dev/null; then
        missing+=("numpy")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing Python packages: ${missing[*]}"
        print_info "Installing..."
        "${VENV_DIR}/bin/python" -m pip install "${missing[@]}" 2>&1 | tail -3
    fi

    return 0
}

check_stt_deps() {
    local stt="$1"

    case "${stt}" in
        whisper-mlx)
            if ! "${VENV_DIR}/bin/python" -c "from lightning_whisper_mlx import LightningWhisperMLX" 2>/dev/null; then
                print_info "Installing whisper-mlx..."
                "${VENV_DIR}/bin/python" -m pip install lightning-whisper-mlx 2>&1 | tail -3
            fi
            ;;
        faster-whisper)
            if ! "${VENV_DIR}/bin/python" -c "from faster_whisper import WhisperModel" 2>/dev/null; then
                print_info "Installing faster-whisper..."
                "${VENV_DIR}/bin/python" -m pip install faster-whisper 2>&1 | tail -3
            fi
            ;;
    esac
    return 0
}

check_tts_deps() {
    local tts="$1"

    case "${tts}" in
        edge-tts)
            if ! "${VENV_DIR}/bin/python" -c "import edge_tts" 2>/dev/null; then
                print_info "Installing edge-tts..."
                "${VENV_DIR}/bin/python" -m pip install edge-tts 2>&1 | tail -3
            fi
            ;;
        facebookMMS)
            if ! "${VENV_DIR}/bin/python" -c "from transformers import VitsModel" 2>/dev/null; then
                print_info "Installing transformers for Facebook MMS..."
                "${VENV_DIR}/bin/python" -m pip install transformers 2>&1 | tail -3
            fi
            ;;
        macos-say)
            if ! command -v say &>/dev/null; then
                print_error "macOS 'say' command not found (not on macOS?)"
                return 1
            fi
            ;;
    esac
    return 0
}

# ─── Commands ─────────────────────────────────────────────────────────

ensure_opencode_server() {
    local port="${1:-4096}"

    if curl -s --max-time 1 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
        print_success "OpenCode server already running on port ${port}"
        return 0
    fi

    print_info "Starting OpenCode server on port ${port}..."
    opencode serve --port "${port}" &>/dev/null &
    local server_pid=$!
    echo "${server_pid}" > "${VOICE_PID_FILE}.server"

    # Wait for server to be ready
    local attempts=0
    while [[ ${attempts} -lt 20 ]]; do
        if curl -s --max-time 1 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
            print_success "OpenCode server started (pid: ${server_pid})"
            return 0
        fi
        sleep 0.5
        attempts=$((attempts + 1))
    done

    print_warning "OpenCode server slow to start, continuing anyway..."
    return 0
}

cmd_talk() {
    local stt="${1:-whisper-mlx}"
    local tts="${2:-edge-tts}"
    local voice="${3:-}"
    local model="${4:-opencode/claude-sonnet-4}"

    check_venv || return 1
    check_deps || return 1
    check_stt_deps "${stt}" || return 1
    check_tts_deps "${tts}" || return 1

    # Ensure opencode serve is running for low-latency attach mode
    ensure_opencode_server 4096

    local extra_args=()
    if [[ -n "${voice}" ]]; then
        extra_args+=("--tts-voice" "${voice}")
    fi

    print_info "Starting voice bridge..."
    print_info "STT: ${stt} | TTS: ${tts} | Model: ${model}"
    echo ""

    "${VENV_DIR}/bin/python" "${BRIDGE_SCRIPT}" \
        --stt "${stt}" \
        --tts "${tts}" \
        --model "${model}" \
        "${extra_args[@]+"${extra_args[@]}"}"

    return 0
}

cmd_devices() {
    check_venv || return 1
    "${VENV_DIR}/bin/python" "${BRIDGE_SCRIPT}" --list-devices
    return 0
}

cmd_voices() {
    check_venv || return 1
    check_tts_deps "edge-tts" || return 1
    "${VENV_DIR}/bin/python" "${BRIDGE_SCRIPT}" --list-voices
    return 0
}

cmd_status() {
    echo "=== Voice Bridge Status ==="
    echo ""

    # Check venv
    if [[ -d "${VENV_DIR}" ]]; then
        print_success "Python venv: ${VENV_DIR}"
    else
        print_error "Python venv: not found"
        print_info "Run: speech-to-speech-helper.sh setup"
    fi

    # Check bridge script
    if [[ -f "${BRIDGE_SCRIPT}" ]]; then
        print_success "Bridge script: ${BRIDGE_SCRIPT}"
    else
        print_error "Bridge script: not found"
    fi

    # Check opencode
    if command -v opencode &>/dev/null; then
        local oc_version
        oc_version="$(opencode --version 2>/dev/null || echo 'unknown')"
        print_success "OpenCode: ${oc_version}"
    else
        print_error "OpenCode: not found"
    fi

    # Check STT availability
    echo ""
    echo "STT Engines:"
    if "${VENV_DIR}/bin/python" -c "from lightning_whisper_mlx import LightningWhisperMLX" 2>/dev/null; then
        print_success "  whisper-mlx: available"
    else
        print_warning "  whisper-mlx: not installed"
    fi
    if "${VENV_DIR}/bin/python" -c "from faster_whisper import WhisperModel" 2>/dev/null; then
        print_success "  faster-whisper: available"
    else
        print_warning "  faster-whisper: not installed"
    fi

    # Check TTS availability
    echo ""
    echo "TTS Engines:"
    if "${VENV_DIR}/bin/python" -c "import edge_tts" 2>/dev/null; then
        print_success "  edge-tts: available"
    else
        print_warning "  edge-tts: not installed"
    fi
    if command -v say &>/dev/null; then
        print_success "  macos-say: available"
    else
        print_warning "  macos-say: not available"
    fi
    if "${VENV_DIR}/bin/python" -c "from transformers import VitsModel" 2>/dev/null; then
        print_success "  facebookMMS: available"
    else
        print_warning "  facebookMMS: not installed"
    fi

    echo ""
    return 0
}

cmd_benchmark() {
    check_venv || return 1

    echo "=== Voice Bridge Benchmark ==="
    echo ""
    echo "Testing STT engines (2s silence)..."
    echo ""

    "${VENV_DIR}/bin/python" -c "
import time, numpy as np

audio = np.zeros(32000, dtype=np.float32)

# whisper-mlx
try:
    from lightning_whisper_mlx import LightningWhisperMLX
    w = LightningWhisperMLX(model='distil-large-v3', batch_size=6, quant=None)
    start = time.time()
    w.transcribe(audio)
    print(f'  whisper-mlx:     {time.time()-start:.3f}s')
except Exception as e:
    print(f'  whisper-mlx:     FAILED ({e})')

# faster-whisper
try:
    from faster_whisper import WhisperModel
    m = WhisperModel('distil-large-v3', device='cpu', compute_type='int8')
    start = time.time()
    segs, _ = m.transcribe(audio, language='en')
    for s in segs: pass
    print(f'  faster-whisper:  {time.time()-start:.3f}s')
except Exception as e:
    print(f'  faster-whisper:  FAILED ({e})')

print()
print('Testing TTS engines...')
print()

text = 'Hello, I am your AI DevOps assistant.'

# edge-tts
try:
    import asyncio, edge_tts, tempfile
    async def t():
        c = edge_tts.Communicate(text, 'en-US-GuyNeural')
        with tempfile.NamedTemporaryFile(suffix='.mp3', delete=True) as f:
            await c.save(f.name)
    start = time.time()
    asyncio.run(t())
    print(f'  edge-tts:        {time.time()-start:.3f}s')
except Exception as e:
    print(f'  edge-tts:        FAILED ({e})')

# macos say
try:
    import subprocess, tempfile
    with tempfile.NamedTemporaryFile(suffix='.aiff', delete=True) as f:
        start = time.time()
        subprocess.run(['say', '-v', 'Samantha', '-o', f.name, text], check=True, capture_output=True)
        print(f'  macos-say:       {time.time()-start:.3f}s')
except Exception as e:
    print(f'  macos-say:       FAILED ({e})')

# opencode run
try:
    import subprocess
    start = time.time()
    r = subprocess.run(['opencode', 'run', '-m', 'opencode/claude-sonnet-4', 'Say OK'], capture_output=True, text=True, timeout=30)
    print(f'  opencode run:    {time.time()-start:.3f}s (response: {r.stdout.strip()[:50]})')
except Exception as e:
    print(f'  opencode run:    FAILED ({e})')

print()
" 2>&1

    return 0
}

cmd_help() {
    cat <<'EOF'
Voice Helper - Talk to OpenCode via speech

Usage: voice-helper.sh <command> [options]

Commands:
  talk [stt] [tts] [voice] [model]  Start voice conversation (default)
  devices                            List audio input/output devices
  voices                             List available edge-tts voices
  status                             Check component availability
  benchmark                          Benchmark STT/TTS/LLM speed
  help                               Show this help

STT Engines:
  whisper-mlx      MLX-optimized Whisper (fastest on Apple Silicon) [default]
  faster-whisper   CTranslate2 Whisper (CPU, slower on Mac)
  macos-dictation  macOS built-in (not yet implemented)

TTS Engines:
  edge-tts         Microsoft Edge TTS (best quality, needs internet) [default]
  macos-say        macOS say command (instant, offline, decent quality)
  facebookMMS      Facebook MMS VITS (local, robotic quality)

Examples:
  voice-helper.sh talk                                    # defaults (Sonia, British)
  voice-helper.sh talk whisper-mlx edge-tts               # explicit defaults
  voice-helper.sh talk whisper-mlx macos-say              # offline mode
  voice-helper.sh talk whisper-mlx edge-tts en-US-AriaNeural  # US female voice
  voice-helper.sh benchmark                               # test speeds

Popular edge-tts voices:
  en-GB-SoniaNeural        Female, British, friendly (default)
  en-GB-LibbyNeural        Female, British, friendly
  en-GB-MaisieNeural       Female, British, friendly
  en-US-AriaNeural         Female, US, positive, confident
  en-US-JennyNeural        Female, US, friendly
  en-US-AvaNeural          Female, US, expressive, caring
  en-US-GuyNeural          Male, US, passion
  en-US-AndrewNeural       Male, US, warm, confident
  en-US-BrianNeural        Male, US, approachable, casual
EOF
    return 0
}

# ─── Main ─────────────────────────────────────────────────────────────

main() {
    local command="${1:-help}"
    shift || true

    case "${command}" in
        talk|start)
            cmd_talk "$@"
            ;;
        devices|list-devices)
            cmd_devices
            ;;
        voices|list-voices)
            cmd_voices
            ;;
        status)
            cmd_status
            ;;
        benchmark|bench)
            cmd_benchmark
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            print_error "Unknown command: ${command}"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
