#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2155

# Voice Pipeline Helper Script
# Implements the CapCut cleanup + ElevenLabs transformation chain
# for professional voice production in content pipelines.
#
# Pipeline: Extract → Cleanup → Transform → Normalize
#
# Usage: ./voice-pipeline-helper.sh [command] [options]
# Commands:
#   pipeline    - Run full voice pipeline (extract → cleanup → transform → normalize)
#   extract     - Extract audio from video file
#   cleanup     - Clean up audio (noise reduction, normalization, de-essing)
#   transform   - Transform voice via ElevenLabs (speech-to-speech or TTS)
#   normalize   - Normalize audio to target LUFS
#   tts         - Generate speech from text via ElevenLabs
#   voices      - List available ElevenLabs voices
#   clone       - Clone a voice from audio sample
#   status      - Check dependencies and API connectivity
#   help        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

# ─── Constants ─────────────────────────────────────────────────────────

readonly ELEVENLABS_API_BASE="https://api.elevenlabs.io/v1"
readonly DEFAULT_OUTPUT_DIR="${HOME}/.aidevops/.agent-workspace/work/voice-pipeline"
readonly DEFAULT_SAMPLE_RATE=48000
readonly DEFAULT_BIT_DEPTH=24
readonly DEFAULT_TARGET_LUFS=-15
readonly DEFAULT_TRUE_PEAK=-1
readonly DEFAULT_VOICE_ID=""
readonly DEFAULT_MODEL_ID="eleven_multilingual_v2"
readonly SUPPORTED_AUDIO_FORMATS="wav|mp3|flac|ogg|m4a|aac"
readonly SUPPORTED_VIDEO_FORMATS="mp4|mkv|webm|avi|mov|flv|wmv|m4v|ts"

# ─── API Key Management ───────────────────────────────────────────────

# Load ElevenLabs API key from environment, gopass, or credentials file.
# NEVER prints the key value — only sets it in the current shell.
load_elevenlabs_key() {
    # 1. Already in environment
    if [[ -n "${ELEVENLABS_API_KEY:-}" ]]; then
        return 0
    fi

    # 2. Try gopass (encrypted)
    if command -v gopass &>/dev/null; then
        local key
        key=$(gopass show -o "aidevops/ELEVENLABS_API_KEY" 2>/dev/null) || true
        if [[ -n "${key:-}" ]]; then
            export ELEVENLABS_API_KEY="$key"
            return 0
        fi
    fi

    # 3. Try credentials.sh (plaintext fallback)
    local cred_file="${HOME}/.config/aidevops/credentials.sh"
    if [[ -f "$cred_file" ]]; then
        # Source in subshell to avoid polluting environment with other vars
        local key
        key=$(bash -c "source '$cred_file' 2>/dev/null && echo \"\${ELEVENLABS_API_KEY:-}\"") || true
        if [[ -n "${key:-}" ]]; then
            export ELEVENLABS_API_KEY="$key"
            return 0
        fi
    fi

    # 4. Try tenant credentials
    local tenant_file="${HOME}/.config/aidevops/tenants/default/credentials.sh"
    if [[ -f "$tenant_file" ]]; then
        local key
        key=$(bash -c "source '$tenant_file' 2>/dev/null && echo \"\${ELEVENLABS_API_KEY:-}\"") || true
        if [[ -n "${key:-}" ]]; then
            export ELEVENLABS_API_KEY="$key"
            return 0
        fi
    fi

    return 1
}

# Validate that the API key is set and functional
require_elevenlabs_key() {
    if ! load_elevenlabs_key; then
        print_error "ElevenLabs API key not found"
        print_info "Set it with: aidevops secret set ELEVENLABS_API_KEY"
        print_info "Or export ELEVENLABS_API_KEY in your shell"
        return 1
    fi
    return 0
}

# ─── Dependency Checks ────────────────────────────────────────────────

check_ffmpeg() {
    if ! command -v ffmpeg &>/dev/null; then
        print_error "ffmpeg is required but not installed"
        print_info "Install: brew install ffmpeg (macOS) or apt install ffmpeg (Linux)"
        return 1
    fi
    return 0
}

check_ffprobe() {
    if ! command -v ffprobe &>/dev/null; then
        print_error "ffprobe is required but not installed (usually bundled with ffmpeg)"
        return 1
    fi
    return 0
}

check_curl() {
    if ! command -v curl &>/dev/null; then
        print_error "curl is required but not installed"
        return 1
    fi
    return 0
}

check_jq() {
    if ! command -v jq &>/dev/null; then
        print_error "jq is required but not installed"
        print_info "Install: brew install jq (macOS) or apt install jq (Linux)"
        return 1
    fi
    return 0
}

check_sox() {
    if ! command -v sox &>/dev/null; then
        print_warning "sox not found — some advanced cleanup features unavailable"
        print_info "Install: brew install sox (macOS) or apt install sox (Linux)"
        return 1
    fi
    return 0
}

ensure_output_dir() {
    local dir="${1:-$DEFAULT_OUTPUT_DIR}"
    mkdir -p "$dir" 2>/dev/null || true
    echo "$dir"
    return 0
}

# ─── Audio Utilities ───────────────────────────────────────────────────

# Get audio duration in seconds
get_audio_duration() {
    local input_file="$1"
    ffprobe -v quiet -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null
    return $?
}

# Get audio format info
get_audio_info() {
    local input_file="$1"
    ffprobe -v quiet -show_entries stream=codec_name,sample_rate,channels,bit_rate \
        -of json "$input_file" 2>/dev/null
    return $?
}

# Measure integrated LUFS of an audio file
measure_lufs() {
    local input_file="$1"
    local result
    result=$(ffmpeg -i "$input_file" -af loudnorm=print_format=json -f null - 2>&1 | \
        grep -A 20 '"input_i"' | head -25)
    echo "$result"
    return 0
}

# Check if file is a video (has video stream)
is_video_file() {
    local input_file="$1"
    local has_video
    has_video=$(ffprobe -v quiet -select_streams v:0 \
        -show_entries stream=codec_type -of csv=p=0 "$input_file" 2>/dev/null)
    [[ "$has_video" == "video" ]]
    return $?
}

# ─── Pipeline Commands ─────────────────────────────────────────────────

# Extract audio from video file
cmd_extract() {
    local input_file="${1:-}"
    local output_file="${2:-}"
    local sample_rate="${3:-$DEFAULT_SAMPLE_RATE}"

    if [[ -z "$input_file" ]]; then
        print_error "Input file is required"
        echo "Usage: voice-pipeline-helper.sh extract <input-video> [output-audio] [sample-rate]"
        return 1
    fi

    validate_file_exists "$input_file" "Input file" || return 1
    check_ffmpeg || return 1

    # Auto-generate output filename if not provided
    if [[ -z "$output_file" ]]; then
        local base_name
        base_name=$(basename "$input_file")
        base_name="${base_name%.*}"
        local out_dir
        out_dir=$(ensure_output_dir)
        output_file="${out_dir}/${base_name}-extracted.wav"
    fi

    print_info "Extracting audio from: $(basename "$input_file")"
    print_info "Output: $(basename "$output_file")"
    print_info "Sample rate: ${sample_rate}Hz"

    ffmpeg -y -i "$input_file" \
        -vn \
        -acodec pcm_s${DEFAULT_BIT_DEPTH}le \
        -ar "$sample_rate" \
        -ac 1 \
        "$output_file" 2>>"${AIDEVOPS_LOG_FILE:-/dev/null}"

    if [[ -f "$output_file" ]]; then
        local duration
        duration=$(get_audio_duration "$output_file")
        print_success "Audio extracted: $(basename "$output_file") (${duration}s)"
        echo "$output_file"
        return 0
    fi

    print_error "Failed to extract audio"
    return 1
}

# Clean up audio: noise reduction, normalization, de-essing, high-pass filter
# This is the local equivalent of CapCut AI Voice Cleanup
cmd_cleanup() {
    local input_file="${1:-}"
    local output_file="${2:-}"
    local target_lufs="${3:-$DEFAULT_TARGET_LUFS}"

    if [[ -z "$input_file" ]]; then
        print_error "Input file is required"
        echo "Usage: voice-pipeline-helper.sh cleanup <input-audio> [output-audio] [target-lufs]"
        return 1
    fi

    validate_file_exists "$input_file" "Input file" || return 1
    check_ffmpeg || return 1

    # Auto-generate output filename
    if [[ -z "$output_file" ]]; then
        local base_name
        base_name=$(basename "$input_file")
        base_name="${base_name%.*}"
        local out_dir
        out_dir=$(ensure_output_dir)
        output_file="${out_dir}/${base_name}-cleaned.wav"
    fi

    print_info "Cleaning audio: $(basename "$input_file")"
    print_info "Target LUFS: ${target_lufs}"

    # Build the ffmpeg filter chain:
    # 1. High-pass filter at 80Hz (remove rumble)
    # 2. Noise gate (reduce background noise)
    # 3. De-esser (reduce sibilance at 5-8kHz)
    # 4. Compressor (even out dynamics)
    # 5. Presence boost (3-5kHz for voice clarity)
    # 6. Loudness normalization to target LUFS
    local filter_chain
    filter_chain="highpass=f=80"
    filter_chain="${filter_chain},agate=threshold=0.01:ratio=2:attack=5:release=50"
    filter_chain="${filter_chain},adeclick=window=55:overlap=75"
    filter_chain="${filter_chain},afftdn=nf=-25"
    filter_chain="${filter_chain},acompressor=threshold=-20dB:ratio=3:attack=5:release=100:makeup=2"
    filter_chain="${filter_chain},equalizer=f=4000:t=q:w=1.5:g=2"
    filter_chain="${filter_chain},loudnorm=I=${target_lufs}:TP=${DEFAULT_TRUE_PEAK}:LRA=11"

    ffmpeg -y -i "$input_file" \
        -af "$filter_chain" \
        -acodec pcm_s${DEFAULT_BIT_DEPTH}le \
        -ar "$DEFAULT_SAMPLE_RATE" \
        "$output_file" 2>>"${AIDEVOPS_LOG_FILE:-/dev/null}"

    if [[ -f "$output_file" ]]; then
        local duration
        duration=$(get_audio_duration "$output_file")
        print_success "Audio cleaned: $(basename "$output_file") (${duration}s)"
        echo "$output_file"
        return 0
    fi

    print_error "Failed to clean audio"
    return 1
}

# Transform voice via ElevenLabs Speech-to-Speech API
cmd_transform() {
    local input_file="${1:-}"
    local voice_id="${2:-$DEFAULT_VOICE_ID}"
    local output_file="${3:-}"
    local model_id="${4:-$DEFAULT_MODEL_ID}"

    if [[ -z "$input_file" ]]; then
        print_error "Input audio file is required"
        echo "Usage: voice-pipeline-helper.sh transform <input-audio> [voice-id] [output-file] [model-id]"
        return 1
    fi

    validate_file_exists "$input_file" "Input file" || return 1
    check_curl || return 1
    check_jq || return 1
    require_elevenlabs_key || return 1

    if [[ -z "$voice_id" ]]; then
        print_error "Voice ID is required for transformation"
        print_info "List voices with: voice-pipeline-helper.sh voices"
        return 1
    fi

    # Auto-generate output filename
    if [[ -z "$output_file" ]]; then
        local base_name
        base_name=$(basename "$input_file")
        base_name="${base_name%.*}"
        local out_dir
        out_dir=$(ensure_output_dir)
        output_file="${out_dir}/${base_name}-transformed.mp3"
    fi

    print_info "Transforming voice: $(basename "$input_file")"
    print_info "Voice ID: ${voice_id}"
    print_info "Model: ${model_id}"

    local http_code
    http_code=$(curl -s -w "%{http_code}" -o "$output_file" \
        -X POST "${ELEVENLABS_API_BASE}/speech-to-speech/${voice_id}" \
        -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
        -F "audio=@${input_file}" \
        -F "model_id=${model_id}" \
        -F "voice_settings={\"stability\": 0.5, \"similarity_boost\": 0.75, \"style\": 0.0, \"use_speaker_boost\": true}")

    if [[ "$http_code" == "200" ]] && [[ -f "$output_file" ]] && [[ -s "$output_file" ]]; then
        local duration
        duration=$(get_audio_duration "$output_file")
        print_success "Voice transformed: $(basename "$output_file") (${duration}s)"
        echo "$output_file"
        return 0
    fi

    # Handle error response
    if [[ -f "$output_file" ]]; then
        local error_msg
        error_msg=$(jq -r '.detail.message // .detail // .message // "Unknown error"' "$output_file" 2>/dev/null || echo "HTTP $http_code")
        rm -f "$output_file"
        print_error "ElevenLabs API error (HTTP ${http_code}): ${error_msg}"
    else
        print_error "ElevenLabs API error: HTTP ${http_code}"
    fi
    return 1
}

# Normalize audio to target LUFS
cmd_normalize() {
    local input_file="${1:-}"
    local output_file="${2:-}"
    local target_lufs="${3:-$DEFAULT_TARGET_LUFS}"

    if [[ -z "$input_file" ]]; then
        print_error "Input file is required"
        echo "Usage: voice-pipeline-helper.sh normalize <input-audio> [output-audio] [target-lufs]"
        return 1
    fi

    validate_file_exists "$input_file" "Input file" || return 1
    check_ffmpeg || return 1

    # Auto-generate output filename
    if [[ -z "$output_file" ]]; then
        local base_name
        base_name=$(basename "$input_file")
        base_name="${base_name%.*}"
        local ext="${input_file##*.}"
        local out_dir
        out_dir=$(ensure_output_dir)
        output_file="${out_dir}/${base_name}-normalized.${ext}"
    fi

    print_info "Normalizing audio: $(basename "$input_file")"
    print_info "Target LUFS: ${target_lufs}"

    # Two-pass loudness normalization for accuracy
    # Pass 1: Measure current loudness
    local measure_json
    measure_json=$(ffmpeg -i "$input_file" \
        -af "loudnorm=I=${target_lufs}:TP=${DEFAULT_TRUE_PEAK}:LRA=11:print_format=json" \
        -f null - 2>&1 | grep -A 20 '"input_i"' | head -25)

    local measured_i measured_tp measured_lra measured_thresh
    measured_i=$(echo "$measure_json" | grep '"input_i"' | grep -o '[-0-9.]*' | head -1)
    measured_tp=$(echo "$measure_json" | grep '"input_tp"' | grep -o '[-0-9.]*' | head -1)
    measured_lra=$(echo "$measure_json" | grep '"input_lra"' | grep -o '[-0-9.]*' | head -1)
    measured_thresh=$(echo "$measure_json" | grep '"input_thresh"' | grep -o '[-0-9.]*' | head -1)

    if [[ -z "${measured_i:-}" ]]; then
        print_warning "Could not measure loudness, using single-pass normalization"
        ffmpeg -y -i "$input_file" \
            -af "loudnorm=I=${target_lufs}:TP=${DEFAULT_TRUE_PEAK}:LRA=11" \
            "$output_file" 2>>"${AIDEVOPS_LOG_FILE:-/dev/null}"
    else
        # Pass 2: Apply measured values for precise normalization
        ffmpeg -y -i "$input_file" \
            -af "loudnorm=I=${target_lufs}:TP=${DEFAULT_TRUE_PEAK}:LRA=11:measured_I=${measured_i}:measured_TP=${measured_tp}:measured_LRA=${measured_lra}:measured_thresh=${measured_thresh}:linear=true" \
            "$output_file" 2>>"${AIDEVOPS_LOG_FILE:-/dev/null}"
    fi

    if [[ -f "$output_file" ]]; then
        local duration
        duration=$(get_audio_duration "$output_file")
        print_success "Audio normalized: $(basename "$output_file") (${duration}s)"
        echo "$output_file"
        return 0
    fi

    print_error "Failed to normalize audio"
    return 1
}

# Generate speech from text via ElevenLabs TTS
cmd_tts() {
    local text="${1:-}"
    local voice_id="${2:-$DEFAULT_VOICE_ID}"
    local output_file="${3:-}"
    local model_id="${4:-$DEFAULT_MODEL_ID}"

    if [[ -z "$text" ]]; then
        print_error "Text is required"
        echo "Usage: voice-pipeline-helper.sh tts <text> [voice-id] [output-file] [model-id]"
        return 1
    fi

    check_curl || return 1
    check_jq || return 1
    require_elevenlabs_key || return 1

    if [[ -z "$voice_id" ]]; then
        print_error "Voice ID is required for TTS"
        print_info "List voices with: voice-pipeline-helper.sh voices"
        return 1
    fi

    # Auto-generate output filename
    if [[ -z "$output_file" ]]; then
        local slug
        slug=$(echo "$text" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | head -c 40 | sed 's/-$//')
        local out_dir
        out_dir=$(ensure_output_dir)
        output_file="${out_dir}/tts-${slug}.mp3"
    fi

    print_info "Generating speech from text"
    print_info "Voice ID: ${voice_id}"
    print_info "Model: ${model_id}"

    # Build JSON payload
    local payload
    payload=$(jq -n \
        --arg text "$text" \
        --arg model_id "$model_id" \
        '{
            text: $text,
            model_id: $model_id,
            voice_settings: {
                stability: 0.5,
                similarity_boost: 0.75,
                style: 0.0,
                use_speaker_boost: true
            }
        }')

    local http_code
    http_code=$(curl -s -w "%{http_code}" -o "$output_file" \
        -X POST "${ELEVENLABS_API_BASE}/text-to-speech/${voice_id}" \
        -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if [[ "$http_code" == "200" ]] && [[ -f "$output_file" ]] && [[ -s "$output_file" ]]; then
        local duration
        duration=$(get_audio_duration "$output_file")
        print_success "Speech generated: $(basename "$output_file") (${duration}s)"
        echo "$output_file"
        return 0
    fi

    # Handle error
    if [[ -f "$output_file" ]]; then
        local error_msg
        error_msg=$(jq -r '.detail.message // .detail // .message // "Unknown error"' "$output_file" 2>/dev/null || echo "HTTP $http_code")
        rm -f "$output_file"
        print_error "ElevenLabs TTS error (HTTP ${http_code}): ${error_msg}"
    else
        print_error "ElevenLabs TTS error: HTTP ${http_code}"
    fi
    return 1
}

# List available ElevenLabs voices
cmd_voices() {
    local filter="${1:-}"

    check_curl || return 1
    check_jq || return 1
    require_elevenlabs_key || return 1

    print_info "Fetching ElevenLabs voices..."

    local response
    response=$(curl -s \
        -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
        "${ELEVENLABS_API_BASE}/voices")

    if ! echo "$response" | jq -e '.voices' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.detail.message // .detail // .message // "Unknown error"' 2>/dev/null || echo "API error")
        print_error "Failed to fetch voices: ${error_msg}"
        return 1
    fi

    local voice_count
    voice_count=$(echo "$response" | jq '.voices | length')
    echo ""
    echo "=== ElevenLabs Voices (${voice_count} total) ==="
    echo ""

    if [[ -n "$filter" ]]; then
        echo "$response" | jq -r --arg f "$filter" '
            .voices[]
            | select(
                (.name | ascii_downcase | contains($f | ascii_downcase)) or
                (.labels | to_entries[] | .value | ascii_downcase | contains($f | ascii_downcase))
              )
            | "  \(.voice_id)  \(.name)  [\(.labels | to_entries | map(.value) | join(", "))]"
        '
    else
        echo "$response" | jq -r '
            .voices[]
            | "  \(.voice_id)  \(.name)  [\(.labels | to_entries | map(.value) | join(", "))]"
        '
    fi

    echo ""
    return 0
}

# Clone a voice from audio sample
cmd_clone() {
    local name="${1:-}"
    local sample_file="${2:-}"
    local description="${3:-Cloned voice for content production}"

    if [[ -z "$name" ]] || [[ -z "$sample_file" ]]; then
        print_error "Name and sample file are required"
        echo "Usage: voice-pipeline-helper.sh clone <name> <sample-audio> [description]"
        echo ""
        echo "Requirements:"
        echo "  - Audio sample: 1-5 minutes of clean speech"
        echo "  - Format: WAV, MP3, or M4A"
        echo "  - Quality: Clear voice, minimal background noise"
        return 1
    fi

    validate_file_exists "$sample_file" "Sample file" || return 1
    check_curl || return 1
    check_jq || return 1
    require_elevenlabs_key || return 1

    print_info "Cloning voice: ${name}"
    print_info "Sample: $(basename "$sample_file")"

    local response
    response=$(curl -s \
        -X POST "${ELEVENLABS_API_BASE}/voices/add" \
        -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
        -F "name=${name}" \
        -F "description=${description}" \
        -F "files=@${sample_file}")

    local voice_id
    voice_id=$(echo "$response" | jq -r '.voice_id // empty' 2>/dev/null)

    if [[ -n "$voice_id" ]]; then
        print_success "Voice cloned successfully"
        echo "  Voice ID: ${voice_id}"
        echo "  Name: ${name}"
        echo ""
        echo "Use this voice ID with:"
        echo "  voice-pipeline-helper.sh transform <audio> ${voice_id}"
        echo "  voice-pipeline-helper.sh tts \"text\" ${voice_id}"
        return 0
    fi

    local error_msg
    error_msg=$(echo "$response" | jq -r '.detail.message // .detail // .message // "Unknown error"' 2>/dev/null || echo "API error")
    print_error "Failed to clone voice: ${error_msg}"
    return 1
}

# Run the full pipeline: extract → cleanup → transform → normalize
cmd_pipeline() {
    local input_file="${1:-}"
    local voice_id="${2:-$DEFAULT_VOICE_ID}"
    local output_file="${3:-}"
    local target_lufs="${4:-$DEFAULT_TARGET_LUFS}"

    if [[ -z "$input_file" ]]; then
        print_error "Input file is required"
        echo "Usage: voice-pipeline-helper.sh pipeline <input-file> [voice-id] [output-file] [target-lufs]"
        echo ""
        echo "Pipeline stages:"
        echo "  1. Extract  - Extract audio from video (skipped for audio input)"
        echo "  2. Cleanup  - Noise reduction, normalization, de-essing"
        echo "  3. Transform - ElevenLabs speech-to-speech (skipped if no voice-id)"
        echo "  4. Normalize - Final LUFS normalization"
        return 1
    fi

    validate_file_exists "$input_file" "Input file" || return 1
    check_ffmpeg || return 1

    local out_dir
    out_dir=$(ensure_output_dir)
    local base_name
    base_name=$(basename "$input_file")
    base_name="${base_name%.*}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local pipeline_dir="${out_dir}/${base_name}-${timestamp}"
    mkdir -p "$pipeline_dir"

    echo ""
    echo "=== Voice Pipeline ==="
    echo "Input: $(basename "$input_file")"
    echo "Output dir: ${pipeline_dir}"
    echo ""

    local current_file="$input_file"
    local stage_num=1

    # Stage 1: Extract (if video)
    if is_video_file "$input_file"; then
        echo "--- Stage ${stage_num}: Extract Audio ---"
        local extracted
        extracted=$(cmd_extract "$current_file" "${pipeline_dir}/${base_name}-01-extracted.wav") || {
            print_error "Pipeline failed at extraction stage"
            return 1
        }
        current_file="$extracted"
        stage_num=$((stage_num + 1))
        echo ""
    else
        print_info "Input is audio — skipping extraction"
        echo ""
    fi

    # Stage 2: Cleanup (CapCut-equivalent)
    echo "--- Stage ${stage_num}: Cleanup (CapCut-equivalent) ---"
    local cleaned
    cleaned=$(cmd_cleanup "$current_file" "${pipeline_dir}/${base_name}-02-cleaned.wav" "$target_lufs") || {
        print_error "Pipeline failed at cleanup stage"
        return 1
    }
    current_file="$cleaned"
    stage_num=$((stage_num + 1))
    echo ""

    # Stage 3: Transform (ElevenLabs — optional)
    if [[ -n "$voice_id" ]]; then
        echo "--- Stage ${stage_num}: Transform (ElevenLabs) ---"
        local transformed
        transformed=$(cmd_transform "$current_file" "$voice_id" "${pipeline_dir}/${base_name}-03-transformed.mp3") || {
            print_error "Pipeline failed at transformation stage"
            print_info "Continuing with cleaned audio (no transformation applied)"
            stage_num=$((stage_num + 1))
            echo ""
        }
        if [[ -n "${transformed:-}" ]]; then
            current_file="$transformed"
            stage_num=$((stage_num + 1))
            echo ""
        fi
    else
        print_info "No voice ID provided — skipping ElevenLabs transformation"
        print_info "Provide a voice ID to enable: voice-pipeline-helper.sh pipeline <file> <voice-id>"
        echo ""
    fi

    # Stage 4: Normalize
    echo "--- Stage ${stage_num}: Final Normalization ---"
    # Determine final output format
    local final_ext="wav"
    if [[ -n "$output_file" ]]; then
        final_ext="${output_file##*.}"
    fi
    local final_output="${output_file:-${pipeline_dir}/${base_name}-final.${final_ext}}"
    local normalized
    normalized=$(cmd_normalize "$current_file" "$final_output" "$target_lufs") || {
        print_error "Pipeline failed at normalization stage"
        return 1
    }
    echo ""

    # Summary
    echo "=== Pipeline Complete ==="
    echo ""
    echo "  Input:  $(basename "$input_file")"
    echo "  Output: ${normalized}"
    echo ""
    echo "  Stages completed: ${stage_num}"
    if [[ -n "$voice_id" ]]; then
        echo "  Voice: ${voice_id}"
    fi
    echo "  Target LUFS: ${target_lufs}"
    echo ""

    # List all intermediate files
    echo "  Intermediate files:"
    local f
    for f in "${pipeline_dir}"/*; do
        if [[ -f "$f" ]]; then
            local dur
            dur=$(get_audio_duration "$f" 2>/dev/null || echo "?")
            echo "    $(basename "$f") (${dur}s)"
        fi
    done
    echo ""

    return 0
}

# Check dependencies and API connectivity
cmd_status() {
    echo "=== Voice Pipeline Status ==="
    echo ""

    # Check ffmpeg
    if command -v ffmpeg &>/dev/null; then
        local ffmpeg_version
        ffmpeg_version=$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')
        print_success "ffmpeg: ${ffmpeg_version}"
    else
        print_error "ffmpeg: not installed"
    fi

    # Check ffprobe
    if command -v ffprobe &>/dev/null; then
        print_success "ffprobe: available"
    else
        print_error "ffprobe: not installed"
    fi

    # Check sox
    if command -v sox &>/dev/null; then
        local sox_version
        sox_version=$(sox --version 2>/dev/null | head -1 | awk '{print $NF}')
        print_success "sox: ${sox_version}"
    else
        print_warning "sox: not installed (optional)"
    fi

    # Check curl
    if command -v curl &>/dev/null; then
        print_success "curl: available"
    else
        print_error "curl: not installed"
    fi

    # Check jq
    if command -v jq &>/dev/null; then
        print_success "jq: available"
    else
        print_error "jq: not installed"
    fi

    echo ""

    # Check ElevenLabs API
    echo "--- ElevenLabs API ---"
    if load_elevenlabs_key; then
        print_success "API key: configured"

        # Test connectivity
        local response
        response=$(curl -s -w "\n%{http_code}" \
            -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
            "${ELEVENLABS_API_BASE}/user" 2>/dev/null)
        local http_code
        http_code=$(echo "$response" | tail -1)
        local body
        body=$(echo "$response" | head -n -1)

        if [[ "$http_code" == "200" ]]; then
            local char_count char_limit tier
            char_count=$(echo "$body" | jq -r '.subscription.character_count // "?"' 2>/dev/null)
            char_limit=$(echo "$body" | jq -r '.subscription.character_limit // "?"' 2>/dev/null)
            tier=$(echo "$body" | jq -r '.subscription.tier // "?"' 2>/dev/null)
            print_success "API connectivity: OK"
            echo "  Tier: ${tier}"
            echo "  Characters used: ${char_count} / ${char_limit}"
        else
            print_error "API connectivity: HTTP ${http_code}"
        fi
    else
        print_warning "API key: not configured"
        print_info "Set with: aidevops secret set ELEVENLABS_API_KEY"
    fi

    echo ""

    # Check output directory
    echo "--- Output Directory ---"
    if [[ -d "$DEFAULT_OUTPUT_DIR" ]]; then
        local file_count
        file_count=$(find "$DEFAULT_OUTPUT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
        print_success "Output dir: ${DEFAULT_OUTPUT_DIR} (${file_count} files)"
    else
        print_info "Output dir: ${DEFAULT_OUTPUT_DIR} (will be created on first use)"
    fi

    echo ""
    return 0
}

# ─── Help ──────────────────────────────────────────────────────────────

cmd_help() {
    cat <<'EOF'
Voice Pipeline Helper - CapCut cleanup + ElevenLabs transformation chain

Usage: voice-pipeline-helper.sh <command> [options]

Commands:
  pipeline <file> [voice-id] [output] [lufs]  Run full pipeline
  extract <video> [output] [sample-rate]       Extract audio from video
  cleanup <audio> [output] [target-lufs]       Clean audio (noise, EQ, compress)
  transform <audio> <voice-id> [output]        ElevenLabs speech-to-speech
  normalize <audio> [output] [target-lufs]     Normalize to target LUFS
  tts <text> <voice-id> [output] [model]       Text-to-speech via ElevenLabs
  voices [filter]                              List ElevenLabs voices
  clone <name> <sample-audio> [description]    Clone voice from sample
  status                                       Check dependencies and API
  help                                         Show this help

Pipeline Stages:
  1. Extract   - Pull audio from video (skipped for audio input)
  2. Cleanup   - Noise reduction, EQ, compression, de-essing (CapCut equivalent)
  3. Transform - ElevenLabs speech-to-speech voice transformation
  4. Normalize - Final loudness normalization to target LUFS

Critical Rule:
  ALWAYS clean audio BEFORE sending to ElevenLabs. Raw AI video audio
  contains artifacts that get amplified during voice transformation.

Examples:
  # Full pipeline with voice transformation
  voice-pipeline-helper.sh pipeline video.mp4 voice_abc123

  # Cleanup only (no ElevenLabs)
  voice-pipeline-helper.sh pipeline raw-audio.wav

  # Extract + cleanup from video
  voice-pipeline-helper.sh extract video.mp4 output.wav
  voice-pipeline-helper.sh cleanup output.wav cleaned.wav

  # Generate speech from text
  voice-pipeline-helper.sh tts "Hello world" voice_abc123

  # Clone a voice
  voice-pipeline-helper.sh clone "My Voice" sample.wav

  # List voices matching a filter
  voice-pipeline-helper.sh voices british

  # Normalize to YouTube standard (-14 LUFS)
  voice-pipeline-helper.sh normalize audio.wav output.wav -14

Target LUFS by Platform:
  YouTube:     -14 to -16
  Podcast:     -16 to -19
  TikTok:      -10 to -12
  Broadcast:   -23 to -24
  Dialogue:    -15 (default)

Dependencies:
  Required: ffmpeg, curl, jq
  Optional: sox (advanced cleanup)
  API key:  ELEVENLABS_API_KEY (via aidevops secret set)

See also:
  content/production/audio.md     - Audio production guide
  tools/voice/speech-to-speech.md - Advanced voice pipeline
  voice-helper.sh                 - Interactive voice bridge
EOF
    return 0
}

# ─── Main ──────────────────────────────────────────────────────────────

main() {
    local command="${1:-help}"
    shift || true

    case "${command}" in
        pipeline|pipe|full)
            cmd_pipeline "$@"
            ;;
        extract|ext)
            cmd_extract "$@"
            ;;
        cleanup|clean)
            cmd_cleanup "$@"
            ;;
        transform|trans|s2s)
            cmd_transform "$@"
            ;;
        normalize|norm|lufs)
            cmd_normalize "$@"
            ;;
        tts|speak|say)
            cmd_tts "$@"
            ;;
        voices|list-voices)
            cmd_voices "$@"
            ;;
        clone|clone-voice)
            cmd_clone "$@"
            ;;
        status|check)
            cmd_status
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
