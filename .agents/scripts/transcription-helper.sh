#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2155

# Transcription Helper Script
# Transcribe audio/video from YouTube, URLs, or local files
# Supports local models (faster-whisper, whisper.cpp, Buzz) and cloud APIs (Groq, OpenAI)
#
# Usage: ./transcription-helper.sh [command] [options]
# Commands:
#   transcribe  - Transcribe audio/video file or URL
#   models      - List available transcription models
#   configure   - Set default model and output format
#   install     - Install transcription dependencies
#   status      - Check installation status
#   help        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

# Constants
readonly DEFAULT_OUTPUT_DIR="$HOME/Downloads"
readonly CONFIG_DIR="$HOME/.config/aidevops/transcription"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly CACHE_DIR="$HOME/.cache/aidevops/transcription"
readonly VENV_DIR="$HOME/.aidevops/.agent-workspace/work/speech-to-speech/.venv"

# Supported audio/video extensions
readonly AUDIO_EXTENSIONS="wav|mp3|flac|ogg|m4a|wma|aac"
readonly VIDEO_EXTENSIONS="mp4|mkv|webm|avi|mov|flv|wmv|m4v|ts"

# Default settings
readonly DEFAULT_MODEL="large-v3-turbo"
readonly DEFAULT_OUTPUT_FORMAT="txt"
readonly DEFAULT_LANGUAGE="auto"

# ─── Utility Functions ────────────────────────────────────────────────

print_header() {
    local message="$1"
    echo -e "${PURPLE}=== $message ===${NC}"
    return 0
}

# Load configuration or return defaults
load_config() {
    local key="$1"
    local default="$2"

    if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
        local value
        value=$(jq -r ".$key // empty" "$CONFIG_FILE" 2>/dev/null)
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    fi
    echo "$default"
    return 0
}

# Detect input source type
detect_source() {
    local input="$1"

    if [[ "$input" =~ youtu\.be/ ]] || [[ "$input" =~ youtube\.com/watch ]]; then
        echo "youtube"
    elif [[ "$input" =~ ^https?:// ]]; then
        echo "url"
    elif [[ -f "$input" ]]; then
        local ext="${input##*.}"
        ext="${ext,,}"
        if [[ "$ext" =~ ^($AUDIO_EXTENSIONS)$ ]]; then
            echo "audio"
        elif [[ "$ext" =~ ^($VIDEO_EXTENSIONS)$ ]]; then
            echo "video"
        else
            echo "unknown"
        fi
    else
        echo "not_found"
    fi
    return 0
}

# Find the best available Python with transcription deps
find_python() {
    # Prefer the speech-to-speech venv if it exists
    if [[ -x "${VENV_DIR}/bin/python" ]]; then
        echo "${VENV_DIR}/bin/python"
        return 0
    fi
    # Fall back to system python
    if command -v python3 &>/dev/null; then
        echo "python3"
        return 0
    fi
    print_error "Python 3 not found. Install Python 3.10+ or run: speech-to-speech-helper.sh setup"
    return 1
}

# Check if faster-whisper is available
has_faster_whisper() {
    local python_bin
    python_bin=$(find_python 2>/dev/null) || return 1
    "$python_bin" -c "from faster_whisper import WhisperModel" 2>/dev/null
    return $?
}

# Check if whisper.cpp CLI is available
has_whisper_cpp() {
    command -v whisper-cli &>/dev/null || command -v whisper.cpp &>/dev/null
    return $?
}

# Check if Buzz CLI is available
has_buzz() {
    command -v buzz &>/dev/null
    return $?
}

# ─── Audio Extraction ─────────────────────────────────────────────────

# Extract audio from video file to WAV for transcription
extract_audio() {
    local input="$1"
    local output="$2"

    if ! command -v ffmpeg &>/dev/null; then
        print_error "ffmpeg is required for audio extraction."
        print_info "Install: brew install ffmpeg (macOS) or apt install ffmpeg (Linux)"
        return 1
    fi

    print_info "Extracting audio from: $(basename "$input")"
    ffmpeg -i "$input" -vn -acodec pcm_s16le -ar 16000 -ac 1 -y "$output" 2>/dev/null
    return $?
}

# Download YouTube audio via yt-dlp
download_youtube_audio() {
    local url="$1"
    local output="$2"

    if ! command -v yt-dlp &>/dev/null; then
        print_error "yt-dlp is required for YouTube downloads."
        print_info "Install: brew install yt-dlp (macOS) or pip install yt-dlp"
        return 1
    fi

    print_info "Downloading audio from YouTube..."
    yt-dlp -x --audio-format wav --audio-quality 0 \
        -o "$output" --no-playlist "$url" 2>&1 | tail -5
    return $?
}

# Download audio from a direct URL
download_url_audio() {
    local url="$1"
    local output="$2"

    print_info "Downloading from URL..."
    if ! curl -sL -o "${output}.tmp" "$url"; then
        print_error "Failed to download: $url"
        return 1
    fi

    # Check if it's a video that needs audio extraction
    local mime_type
    mime_type=$(file -b --mime-type "${output}.tmp" 2>/dev/null || echo "unknown")

    if [[ "$mime_type" == video/* ]]; then
        extract_audio "${output}.tmp" "$output"
        rm -f "${output}.tmp"
    else
        mv "${output}.tmp" "$output"
    fi
    return 0
}

# ─── Transcription Backends ──────────────────────────────────────────

# Transcribe using faster-whisper (local, recommended)
transcribe_faster_whisper() {
    local audio_file="$1"
    local model="$2"
    local language="$3"
    local output_format="$4"
    local output_file="$5"

    local python_bin
    python_bin=$(find_python) || return 1

    print_info "Transcribing with faster-whisper (model: $model)..."

    local lang_arg=""
    if [[ "$language" != "auto" ]]; then
        lang_arg="language=\"$language\","
    fi

    "$python_bin" -c "
import sys
from faster_whisper import WhisperModel

model = WhisperModel('$model', device='auto', compute_type='auto')
segments, info = model.transcribe('$audio_file', ${lang_arg} beam_size=5)

detected_lang = info.language
print(f'Detected language: {detected_lang} (probability: {info.language_probability:.2f})', file=sys.stderr)

output_format = '$output_format'
output_file = '$output_file'

if output_format == 'json':
    import json
    result = {
        'language': detected_lang,
        'language_probability': info.language_probability,
        'segments': []
    }
    for segment in segments:
        result['segments'].append({
            'start': segment.start,
            'end': segment.end,
            'text': segment.text.strip()
        })
    with open(output_file, 'w') as f:
        json.dump(result, f, indent=2, ensure_ascii=False)

elif output_format == 'srt':
    with open(output_file, 'w') as f:
        for i, segment in enumerate(segments, 1):
            start_h = int(segment.start // 3600)
            start_m = int((segment.start % 3600) // 60)
            start_s = int(segment.start % 60)
            start_ms = int((segment.start % 1) * 1000)
            end_h = int(segment.end // 3600)
            end_m = int((segment.end % 3600) // 60)
            end_s = int(segment.end % 60)
            end_ms = int((segment.end % 1) * 1000)
            f.write(f'{i}\n')
            f.write(f'{start_h:02d}:{start_m:02d}:{start_s:02d},{start_ms:03d} --> {end_h:02d}:{end_m:02d}:{end_s:02d},{end_ms:03d}\n')
            f.write(f'{segment.text.strip()}\n\n')

elif output_format == 'vtt':
    with open(output_file, 'w') as f:
        f.write('WEBVTT\n\n')
        for i, segment in enumerate(segments, 1):
            start_h = int(segment.start // 3600)
            start_m = int((segment.start % 3600) // 60)
            start_s = int(segment.start % 60)
            start_ms = int((segment.start % 1) * 1000)
            end_h = int(segment.end // 3600)
            end_m = int((segment.end % 3600) // 60)
            end_s = int(segment.end % 60)
            end_ms = int((segment.end % 1) * 1000)
            f.write(f'{start_h:02d}:{start_m:02d}:{start_s:02d}.{start_ms:03d} --> {end_h:02d}:{end_m:02d}:{end_s:02d}.{end_ms:03d}\n')
            f.write(f'{segment.text.strip()}\n\n')

else:
    with open(output_file, 'w') as f:
        for segment in segments:
            f.write(segment.text.strip() + '\n')

print(f'Transcription complete: {output_file}', file=sys.stderr)
"
    return $?
}

# Transcribe using whisper.cpp CLI
transcribe_whisper_cpp() {
    local audio_file="$1"
    local model="$2"
    local language="$3"
    local output_format="$4"
    local output_file="$5"

    local whisper_bin=""
    if command -v whisper-cli &>/dev/null; then
        whisper_bin="whisper-cli"
    elif command -v whisper.cpp &>/dev/null; then
        whisper_bin="whisper.cpp"
    else
        print_error "whisper.cpp CLI not found."
        return 1
    fi

    # Resolve model file path
    local model_dir="$HOME/.cache/whisper.cpp/models"
    local model_file="$model_dir/ggml-${model}.bin"

    if [[ ! -f "$model_file" ]]; then
        print_warning "Model file not found: $model_file"
        print_info "Download models from: https://huggingface.co/ggerganov/whisper.cpp/tree/main"
        return 1
    fi

    print_info "Transcribing with whisper.cpp (model: $model)..."

    local lang_args=()
    if [[ "$language" != "auto" ]]; then
        lang_args=(-l "$language")
    fi

    local format_args=()
    case "$output_format" in
        txt) format_args=(-otxt) ;;
        srt) format_args=(-osrt) ;;
        vtt) format_args=(-ovtt) ;;
        json) format_args=(-ojson) ;;
        *) format_args=(-otxt) ;;
    esac

    local output_base="${output_file%.*}"

    "$whisper_bin" -m "$model_file" -f "$audio_file" \
        "${lang_args[@]}" "${format_args[@]}" \
        -of "$output_base" 2>&1 | tail -5

    return $?
}

# Transcribe using Groq cloud API
transcribe_groq() {
    local audio_file="$1"
    local language="$3"
    local output_format="$4"
    local output_file="$5"

    local api_key="${GROQ_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
        print_error "GROQ_API_KEY not set."
        print_info "Set via: aidevops secret set GROQ_API_KEY"
        return 1
    fi

    print_info "Transcribing with Groq API (model: whisper-large-v3-turbo)..."

    local lang_args=()
    if [[ "$language" != "auto" ]]; then
        lang_args=(-F "language=$language")
    fi

    local response_format="verbose_json"
    if [[ "$output_format" == "txt" ]]; then
        response_format="text"
    fi

    local response
    response=$(curl -s -X POST "https://api.groq.com/openai/v1/audio/transcriptions" \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: multipart/form-data" \
        -F "file=@${audio_file}" \
        -F "model=whisper-large-v3-turbo" \
        -F "response_format=${response_format}" \
        "${lang_args[@]}")

    if [[ -z "$response" ]]; then
        print_error "Empty response from Groq API"
        return 1
    fi

    # Check for API errors
    if echo "$response" | jq -e '.error' &>/dev/null 2>&1; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.error.message // .error // "Unknown error"')
        print_error "Groq API error: $error_msg"
        return 1
    fi

    # Write output based on format
    case "$output_format" in
        txt)
            echo "$response" > "$output_file"
            ;;
        json)
            echo "$response" | jq '.' > "$output_file"
            ;;
        srt)
            # Convert verbose_json segments to SRT
            local python_bin
            python_bin=$(find_python 2>/dev/null || echo "python3")
            echo "$response" | "$python_bin" -c "
import json, sys
data = json.load(sys.stdin)
segments = data.get('segments', [])
for i, seg in enumerate(segments, 1):
    start = seg.get('start', 0)
    end = seg.get('end', 0)
    text = seg.get('text', '').strip()
    sh, sm, ss, sms = int(start//3600), int((start%3600)//60), int(start%60), int((start%1)*1000)
    eh, em, es, ems = int(end//3600), int((end%3600)//60), int(end%60), int((end%1)*1000)
    print(f'{i}')
    print(f'{sh:02d}:{sm:02d}:{ss:02d},{sms:03d} --> {eh:02d}:{em:02d}:{es:02d},{ems:03d}')
    print(f'{text}')
    print()
" > "$output_file"
            ;;
        vtt)
            local python_bin
            python_bin=$(find_python 2>/dev/null || echo "python3")
            echo "$response" | "$python_bin" -c "
import json, sys
data = json.load(sys.stdin)
segments = data.get('segments', [])
print('WEBVTT')
print()
for seg in segments:
    start = seg.get('start', 0)
    end = seg.get('end', 0)
    text = seg.get('text', '').strip()
    sh, sm, ss, sms = int(start//3600), int((start%3600)//60), int(start%60), int((start%1)*1000)
    eh, em, es, ems = int(end//3600), int((end%3600)//60), int(end%60), int((end%1)*1000)
    print(f'{sh:02d}:{sm:02d}:{ss:02d}.{sms:03d} --> {eh:02d}:{em:02d}:{es:02d}.{ems:03d}')
    print(f'{text}')
    print()
" > "$output_file"
            ;;
    esac

    return 0
}

# Transcribe using OpenAI Whisper API
transcribe_openai() {
    local audio_file="$1"
    local language="$3"
    local output_format="$4"
    local output_file="$5"

    local api_key="${OPENAI_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
        print_error "OPENAI_API_KEY not set."
        print_info "Set via: aidevops secret set OPENAI_API_KEY"
        return 1
    fi

    print_info "Transcribing with OpenAI Whisper API..."

    local lang_args=()
    if [[ "$language" != "auto" ]]; then
        lang_args=(-F "language=$language")
    fi

    local response_format="verbose_json"
    if [[ "$output_format" == "txt" ]]; then
        response_format="text"
    elif [[ "$output_format" == "srt" ]]; then
        response_format="srt"
    elif [[ "$output_format" == "vtt" ]]; then
        response_format="vtt"
    fi

    local response
    response=$(curl -s -X POST "https://api.openai.com/v1/audio/transcriptions" \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: multipart/form-data" \
        -F "file=@${audio_file}" \
        -F "model=whisper-1" \
        -F "response_format=${response_format}" \
        "${lang_args[@]}")

    if [[ -z "$response" ]]; then
        print_error "Empty response from OpenAI API"
        return 1
    fi

    # Check for API errors
    if echo "$response" | jq -e '.error' &>/dev/null 2>&1; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.error.message // .error // "Unknown error"')
        print_error "OpenAI API error: $error_msg"
        return 1
    fi

    # Write output
    if [[ "$output_format" == "json" ]]; then
        echo "$response" | jq '.' > "$output_file"
    else
        echo "$response" > "$output_file"
    fi

    return 0
}

# ─── Backend Selection ───────────────────────────────────────────────

# Auto-select the best available backend
select_backend() {
    local preferred="$1"

    # If user specified a backend, validate it
    if [[ -n "$preferred" ]]; then
        case "$preferred" in
            faster-whisper)
                if has_faster_whisper; then echo "faster-whisper"; return 0; fi
                print_error "faster-whisper not available. Install: pip install faster-whisper"
                return 1
                ;;
            whisper-cpp|whisper.cpp)
                if has_whisper_cpp; then echo "whisper-cpp"; return 0; fi
                print_error "whisper.cpp not available. Build from: https://github.com/ggml-org/whisper.cpp"
                return 1
                ;;
            groq)
                if [[ -n "${GROQ_API_KEY:-}" ]]; then echo "groq"; return 0; fi
                print_error "GROQ_API_KEY not set. Run: aidevops secret set GROQ_API_KEY"
                return 1
                ;;
            openai)
                if [[ -n "${OPENAI_API_KEY:-}" ]]; then echo "openai"; return 0; fi
                print_error "OPENAI_API_KEY not set. Run: aidevops secret set OPENAI_API_KEY"
                return 1
                ;;
            buzz)
                if has_buzz; then echo "buzz"; return 0; fi
                print_error "Buzz not available. Install: brew install --cask buzz"
                return 1
                ;;
            *)
                print_error "Unknown backend: $preferred"
                print_info "Available: faster-whisper, whisper-cpp, groq, openai, buzz"
                return 1
                ;;
        esac
    fi

    # Auto-select: local first (free, private), then cloud
    if has_faster_whisper; then
        echo "faster-whisper"
        return 0
    fi
    if has_whisper_cpp; then
        echo "whisper-cpp"
        return 0
    fi
    if has_buzz; then
        echo "buzz"
        return 0
    fi
    if [[ -n "${GROQ_API_KEY:-}" ]]; then
        echo "groq"
        return 0
    fi
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        echo "openai"
        return 0
    fi

    print_error "No transcription backend available."
    print_info "Install one of:"
    print_info "  pip install faster-whisper    (recommended, local)"
    print_info "  brew install --cask buzz      (GUI + CLI, local)"
    print_info "  aidevops secret set GROQ_API_KEY  (cloud, free tier)"
    return 1
}

# ─── Main Commands ───────────────────────────────────────────────────

# Parse transcription options
parse_transcribe_options() {
    TRANSCRIBE_INPUT=""
    TRANSCRIBE_MODEL=""
    TRANSCRIBE_BACKEND=""
    TRANSCRIBE_LANGUAGE=""
    TRANSCRIBE_FORMAT=""
    TRANSCRIBE_OUTPUT=""
    TRANSCRIBE_OUTPUT_DIR=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model|-m)
                TRANSCRIBE_MODEL="$2"
                shift 2
                ;;
            --backend|-b)
                TRANSCRIBE_BACKEND="$2"
                shift 2
                ;;
            --language|-l)
                TRANSCRIBE_LANGUAGE="$2"
                shift 2
                ;;
            --format|-f)
                TRANSCRIBE_FORMAT="$2"
                shift 2
                ;;
            --output|-o)
                TRANSCRIBE_OUTPUT="$2"
                shift 2
                ;;
            --output-dir)
                TRANSCRIBE_OUTPUT_DIR="$2"
                shift 2
                ;;
            -*)
                print_error "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$TRANSCRIBE_INPUT" ]]; then
                    TRANSCRIBE_INPUT="$1"
                else
                    print_error "Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done

    # Apply defaults from config
    TRANSCRIBE_MODEL="${TRANSCRIBE_MODEL:-$(load_config model "$DEFAULT_MODEL")}"
    TRANSCRIBE_LANGUAGE="${TRANSCRIBE_LANGUAGE:-$(load_config language "$DEFAULT_LANGUAGE")}"
    TRANSCRIBE_FORMAT="${TRANSCRIBE_FORMAT:-$(load_config format "$DEFAULT_OUTPUT_FORMAT")}"

    return 0
}

# Main transcribe command
cmd_transcribe() {
    if [[ $# -eq 0 ]]; then
        print_error "Input file or URL required."
        print_info "Usage: transcription-helper.sh transcribe <file|url> [options]"
        return 1
    fi

    parse_transcribe_options "$@" || return 1

    if [[ -z "$TRANSCRIBE_INPUT" ]]; then
        print_error "Input file or URL required."
        return 1
    fi

    # Detect source type
    local source_type
    source_type=$(detect_source "$TRANSCRIBE_INPUT")

    case "$source_type" in
        not_found)
            print_error "File not found: $TRANSCRIBE_INPUT"
            return 1
            ;;
        unknown)
            print_error "Unsupported file type: $TRANSCRIBE_INPUT"
            print_info "Supported audio: $AUDIO_EXTENSIONS"
            print_info "Supported video: $VIDEO_EXTENSIONS"
            return 1
            ;;
    esac

    # Select backend
    local backend
    backend=$(select_backend "$TRANSCRIBE_BACKEND") || return 1

    # Prepare temp directory for intermediate files
    mkdir -p "$CACHE_DIR"
    local temp_audio=""
    local cleanup_temp=false

    # Prepare audio file based on source type
    local audio_file=""
    case "$source_type" in
        youtube)
            temp_audio="$CACHE_DIR/yt-audio-$$.wav"
            download_youtube_audio "$TRANSCRIBE_INPUT" "$temp_audio" || return 1
            # yt-dlp may add extension, find the actual file
            if [[ ! -f "$temp_audio" ]]; then
                temp_audio=$(find "$CACHE_DIR" -name "yt-audio-$$.*" -type f | head -1)
            fi
            audio_file="$temp_audio"
            cleanup_temp=true
            ;;
        url)
            temp_audio="$CACHE_DIR/url-audio-$$.wav"
            download_url_audio "$TRANSCRIBE_INPUT" "$temp_audio" || return 1
            audio_file="$temp_audio"
            cleanup_temp=true
            ;;
        video)
            temp_audio="$CACHE_DIR/extracted-audio-$$.wav"
            extract_audio "$TRANSCRIBE_INPUT" "$temp_audio" || return 1
            audio_file="$temp_audio"
            cleanup_temp=true
            ;;
        audio)
            audio_file="$TRANSCRIBE_INPUT"
            ;;
    esac

    if [[ ! -f "$audio_file" ]]; then
        print_error "Audio file not available after preparation."
        return 1
    fi

    # Determine output file path
    local output_file="$TRANSCRIBE_OUTPUT"
    if [[ -z "$output_file" ]]; then
        local base_name=""
        if [[ "$source_type" == "youtube" ]] || [[ "$source_type" == "url" ]]; then
            base_name="transcription-$(date '+%Y%m%d-%H%M%S')"
        else
            base_name="$(basename "${TRANSCRIBE_INPUT%.*}")"
        fi
        local out_dir="${TRANSCRIBE_OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
        mkdir -p "$out_dir"
        output_file="$out_dir/${base_name}.${TRANSCRIBE_FORMAT}"
    fi

    print_header "Transcription"
    print_info "Input:    $TRANSCRIBE_INPUT ($source_type)"
    print_info "Backend:  $backend"
    print_info "Model:    $TRANSCRIBE_MODEL"
    print_info "Language: $TRANSCRIBE_LANGUAGE"
    print_info "Format:   $TRANSCRIBE_FORMAT"
    print_info "Output:   $output_file"
    echo ""

    # Run transcription
    local exit_code=0
    case "$backend" in
        faster-whisper)
            transcribe_faster_whisper "$audio_file" "$TRANSCRIBE_MODEL" \
                "$TRANSCRIBE_LANGUAGE" "$TRANSCRIBE_FORMAT" "$output_file" || exit_code=$?
            ;;
        whisper-cpp)
            transcribe_whisper_cpp "$audio_file" "$TRANSCRIBE_MODEL" \
                "$TRANSCRIBE_LANGUAGE" "$TRANSCRIBE_FORMAT" "$output_file" || exit_code=$?
            ;;
        groq)
            transcribe_groq "$audio_file" "$TRANSCRIBE_MODEL" \
                "$TRANSCRIBE_LANGUAGE" "$TRANSCRIBE_FORMAT" "$output_file" || exit_code=$?
            ;;
        openai)
            transcribe_openai "$audio_file" "$TRANSCRIBE_MODEL" \
                "$TRANSCRIBE_LANGUAGE" "$TRANSCRIBE_FORMAT" "$output_file" || exit_code=$?
            ;;
        buzz)
            print_info "Transcribing with Buzz CLI..."
            local buzz_args=(transcribe "$audio_file" --model "$TRANSCRIBE_MODEL")
            if [[ "$TRANSCRIBE_LANGUAGE" != "auto" ]]; then
                buzz_args+=(--language "$TRANSCRIBE_LANGUAGE")
            fi
            buzz_args+=(--output-format "$TRANSCRIBE_FORMAT")
            buzz "${buzz_args[@]}" > "$output_file" || exit_code=$?
            ;;
    esac

    # Cleanup temp files
    if [[ "$cleanup_temp" == true ]] && [[ -n "$temp_audio" ]]; then
        rm -f "$temp_audio"
    fi

    if [[ $exit_code -eq 0 ]]; then
        echo ""
        print_success "Transcription saved to: $output_file"

        # Show file size and preview
        if [[ -f "$output_file" ]]; then
            local file_size
            file_size=$(wc -c < "$output_file" | tr -d ' ')
            local line_count
            line_count=$(wc -l < "$output_file" | tr -d ' ')
            print_info "Size: ${file_size} bytes, ${line_count} lines"

            if [[ "$TRANSCRIBE_FORMAT" == "txt" ]] && [[ $line_count -gt 0 ]]; then
                echo ""
                print_info "Preview (first 5 lines):"
                head -5 "$output_file"
            fi
        fi
    else
        print_error "Transcription failed (exit code: $exit_code)"
    fi

    return $exit_code
}

# List available models
cmd_models() {
    print_header "Available Transcription Models"

    echo ""
    echo -e "${CYAN}Local Models (Whisper Family):${NC}"
    echo "  tiny              75MB    Speed: 9.5  Accuracy: 6.0  Draft/preview only"
    echo "  base              142MB   Speed: 8.5  Accuracy: 7.3  Quick transcription"
    echo "  small             461MB   Speed: 7.0  Accuracy: 8.5  Good balance, multilingual"
    echo "  medium            1.5GB   Speed: 5.0  Accuracy: 9.0  Solid quality"
    echo "  large-v3          2.9GB   Speed: 3.0  Accuracy: 9.8  Best quality"
    echo "  large-v3-turbo    1.5GB   Speed: 7.5  Accuracy: 9.7  Recommended default"

    echo ""
    echo -e "${CYAN}Other Local Models:${NC}"
    echo "  parakeet-v2       474MB   Speed: 9.9  Accuracy: 9.4  English-only, fastest"
    echo "  parakeet-v3       494MB   Speed: 9.9  Accuracy: 9.4  Multilingual, experimental"

    echo ""
    echo -e "${CYAN}Cloud APIs:${NC}"
    echo "  groq              -       Speed: 10   Accuracy: 9.6  Free tier available"
    echo "  openai            -       Speed: 8    Accuracy: 9.5  \$0.006/min"
    echo "  elevenlabs        -       Speed: 8    Accuracy: 9.9  Pay per minute"
    echo "  deepgram          -       Speed: 10   Accuracy: 9.5  Pay per minute"

    echo ""
    echo -e "${CYAN}Available Backends:${NC}"
    local check_mark="${GREEN}available${NC}"
    local cross_mark="${RED}not installed${NC}"

    printf "  %-20s " "faster-whisper:"
    if has_faster_whisper; then echo -e "$check_mark"; else echo -e "$cross_mark"; fi

    printf "  %-20s " "whisper.cpp:"
    if has_whisper_cpp; then echo -e "$check_mark"; else echo -e "$cross_mark"; fi

    printf "  %-20s " "buzz:"
    if has_buzz; then echo -e "$check_mark"; else echo -e "$cross_mark"; fi

    printf "  %-20s " "groq:"
    if [[ -n "${GROQ_API_KEY:-}" ]]; then echo -e "$check_mark (API key set)"; else echo -e "$cross_mark (no API key)"; fi

    printf "  %-20s " "openai:"
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then echo -e "$check_mark (API key set)"; else echo -e "$cross_mark (no API key)"; fi

    echo ""
    return 0
}

# Configure defaults
cmd_configure() {
    print_header "Configure Transcription Defaults"

    mkdir -p "$CONFIG_DIR"

    local model="${1:-$DEFAULT_MODEL}"
    local format="${2:-$DEFAULT_OUTPUT_FORMAT}"
    local language="${3:-$DEFAULT_LANGUAGE}"

    if ! command -v jq &>/dev/null; then
        print_error "jq is required for configuration. Install: brew install jq"
        return 1
    fi

    jq -n \
        --arg model "$model" \
        --arg format "$format" \
        --arg language "$language" \
        '{model: $model, format: $format, language: $language}' > "$CONFIG_FILE"

    print_success "Configuration saved to: $CONFIG_FILE"
    print_info "  Model:    $model"
    print_info "  Format:   $format"
    print_info "  Language: $language"
    return 0
}

# Install dependencies
cmd_install() {
    print_header "Installing Transcription Dependencies"

    local os_type
    os_type=$(uname -s)

    # Install ffmpeg and yt-dlp
    echo ""
    print_info "Installing system dependencies..."
    case "$os_type" in
        "Darwin")
            if command -v brew &>/dev/null; then
                brew install ffmpeg yt-dlp 2>&1 | tail -5
            else
                print_warning "Homebrew not found. Install manually: ffmpeg, yt-dlp"
            fi
            ;;
        "Linux")
            if command -v apt-get &>/dev/null; then
                sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg 2>&1 | tail -3
                pip3 install -U yt-dlp 2>&1 | tail -3
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm ffmpeg yt-dlp 2>&1 | tail -3
            else
                print_warning "Unknown package manager. Install manually: ffmpeg, yt-dlp"
            fi
            ;;
    esac

    # Install faster-whisper
    echo ""
    print_info "Installing faster-whisper (recommended local backend)..."
    local python_bin
    python_bin=$(find_python 2>/dev/null || echo "python3")
    "$python_bin" -m pip install faster-whisper 2>&1 | tail -5

    echo ""
    cmd_status
    return 0
}

# Check installation status
cmd_status() {
    print_header "Transcription Installation Status"

    # ffmpeg
    if command -v ffmpeg &>/dev/null; then
        local ffmpeg_version
        ffmpeg_version=$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')
        print_success "ffmpeg: $ffmpeg_version"
    else
        print_error "ffmpeg: not installed"
    fi

    # yt-dlp
    if command -v yt-dlp &>/dev/null; then
        local ytdlp_version
        ytdlp_version=$(yt-dlp --version 2>/dev/null)
        print_success "yt-dlp: $ytdlp_version"
    else
        print_warning "yt-dlp: not installed (needed for YouTube)"
    fi

    # faster-whisper
    if has_faster_whisper; then
        print_success "faster-whisper: available"
    else
        print_warning "faster-whisper: not installed (pip install faster-whisper)"
    fi

    # whisper.cpp
    if has_whisper_cpp; then
        print_success "whisper.cpp: available"
    else
        print_info "whisper.cpp: not installed (optional)"
    fi

    # Buzz
    if has_buzz; then
        print_success "buzz: available"
    else
        print_info "buzz: not installed (optional, brew install --cask buzz)"
    fi

    # Cloud API keys
    if [[ -n "${GROQ_API_KEY:-}" ]]; then
        print_success "Groq API: key configured"
    else
        print_info "Groq API: no key (aidevops secret set GROQ_API_KEY)"
    fi

    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        print_success "OpenAI API: key configured"
    else
        print_info "OpenAI API: no key (aidevops secret set OPENAI_API_KEY)"
    fi

    # Config
    if [[ -f "$CONFIG_FILE" ]]; then
        print_success "Config: $CONFIG_FILE"
    else
        print_info "Config: using defaults (run: transcription-helper.sh configure)"
    fi

    return 0
}

# Show help
show_help() {
    cat << 'EOF'
Transcription Helper - Audio/Video Transcription

Usage: transcription-helper.sh <command> [options]

Commands:
  transcribe <input> [opts]  Transcribe audio/video file or URL
  models                     List available transcription models and backends
  configure [model] [fmt]    Set default model and output format
  install                    Install transcription dependencies
  status                     Check installation status
  help                       Show this help message

Transcribe Options:
  --model, -m <model>        Whisper model (default: large-v3-turbo)
  --backend, -b <backend>    Backend: faster-whisper, whisper-cpp, groq, openai, buzz
  --language, -l <lang>      Language code or "auto" (default: auto)
  --format, -f <format>      Output: txt, srt, vtt, json (default: txt)
  --output, -o <file>        Output file path (default: auto-generated)
  --output-dir <dir>         Output directory (default: ~/Downloads)

Input Sources:
  Local audio    .wav, .mp3, .flac, .ogg, .m4a, .wma, .aac
  Local video    .mp4, .mkv, .webm, .avi, .mov (audio extracted via ffmpeg)
  YouTube URL    youtu.be/ or youtube.com/watch (downloaded via yt-dlp)
  Direct URL     Any HTTP(S) URL to audio/video file

Examples:
  transcription-helper.sh transcribe recording.mp3
  transcription-helper.sh transcribe recording.mp3 --model large-v3-turbo
  transcription-helper.sh transcribe video.mp4 --format srt
  transcription-helper.sh transcribe "https://youtu.be/dQw4w9WgXcQ" --format txt
  transcription-helper.sh transcribe meeting.wav --backend groq --format json
  transcription-helper.sh transcribe lecture.mp4 -b openai -f srt -o subtitles.srt
  transcription-helper.sh models
  transcription-helper.sh configure large-v3-turbo srt en
  transcription-helper.sh install
  transcription-helper.sh status

Backends (auto-selected if not specified):
  faster-whisper   Local, 4x faster than OpenAI Whisper (recommended)
  whisper-cpp      Local, C++ native, optimized for Apple Silicon
  buzz             Local, GUI + CLI, offline Whisper
  groq             Cloud, free tier, lightning fast
  openai           Cloud, $0.006/min
EOF
    return 0
}

# ─── Main Entry Point ────────────────────────────────────────────────

main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "$command" in
        transcribe)
            cmd_transcribe "$@"
            ;;
        models)
            cmd_models
            ;;
        configure)
            cmd_configure "$@"
            ;;
        install)
            cmd_install
            ;;
        status)
            cmd_status
            ;;
        help|-h|--help|"")
            show_help
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND: $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
