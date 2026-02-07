#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155

# yt-dlp Helper Script
# Download YouTube video, audio, playlists, channels, and transcripts
#
# Downloads to ~/Downloads/ in organized named folders:
#   yt-dlp-{type}-{name}-{yyyy-mm-dd-hh-mm}/
#
# Usage: ./yt-dlp-helper.sh [command] [url] [options]
# Commands:
#   video       - Download video (best quality, max 1080p)
#   audio       - Extract audio only (MP3)
#   playlist    - Download full playlist
#   channel     - Download all channel videos
#   transcript  - Download subtitles/transcript only
#   info        - Show video info without downloading
#   convert     - Extract audio from local video file(s) via ffmpeg
#   install     - Install yt-dlp and ffmpeg
#   update      - Update yt-dlp to latest version
#   config      - Generate default config file
#   status      - Check installation status
#   help        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly DEFAULT_DOWNLOAD_DIR="$HOME/Downloads"
readonly CONFIG_DIR="$HOME/.config/yt-dlp"
readonly CONFIG_FILE="$CONFIG_DIR/config"
readonly ARCHIVE_FILE="$CONFIG_DIR/archive.txt"
readonly HELP_SHOW_MESSAGE="Show this help message"

# Print functions
print_header() {
    local message="$1"
    echo -e "${PURPLE}=== $message ===${NC}"
    return 0
}

# Check if yt-dlp is installed
check_ytdlp() {
    if ! command -v yt-dlp &> /dev/null; then
        print_error "yt-dlp is not installed."
        print_info "Run: yt-dlp-helper.sh install"
        return 1
    fi
    return 0
}

# Check if ffmpeg is installed
check_ffmpeg() {
    if ! command -v ffmpeg &> /dev/null; then
        print_warning "ffmpeg is not installed. Some features (merging, audio extraction) require it."
        print_info "Run: yt-dlp-helper.sh install"
        return 1
    fi
    return 0
}

# Sanitize a string for use in directory/file names
sanitize_name() {
    local name="$1"
    local max_length="${2:-60}"
    echo "$name" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-"$max_length"
    return 0
}

# Get timestamp for folder naming
get_timestamp() {
    date '+%Y-%m-%d-%H-%M'
    return 0
}

# Detect URL type (video, playlist, channel)
detect_url_type() {
    local url="$1"
    if [[ "$url" =~ playlist\?list= ]]; then
        echo "playlist"
    elif [[ "$url" =~ /@[^/]+$ ]] || [[ "$url" =~ /c/ ]] || [[ "$url" =~ /channel/ ]] || [[ "$url" =~ /user/ ]]; then
        echo "channel"
    else
        echo "video"
    fi
    return 0
}

# Get video/playlist/channel title for folder naming
get_title() {
    local url="$1"
    local url_type
    url_type=$(detect_url_type "$url")

    case "$url_type" in
        "playlist")
            yt-dlp --flat-playlist --print "%(playlist_title)s" --playlist-items 1 "$url" 2>/dev/null | head -1
            ;;
        "channel")
            yt-dlp --flat-playlist --print "%(channel)s" --playlist-items 1 "$url" 2>/dev/null | head -1
            ;;
        *)
            yt-dlp --print "%(title)s" "$url" 2>/dev/null | head -1
            ;;
    esac
    return 0
}

# Build output directory path
build_output_dir() {
    local type="$1"
    local url="$2"
    local custom_dir="$3"

    local base_dir="${custom_dir:-$DEFAULT_DOWNLOAD_DIR}"
    local title
    title=$(get_title "$url")
    local safe_title
    safe_title=$(sanitize_name "${title:-unknown}")
    local timestamp
    timestamp=$(get_timestamp)

    local output_dir="$base_dir/yt-dlp-${type}-${safe_title}-${timestamp}"
    echo "$output_dir"
    return 0
}

# Parse common options from arguments
# Sets global variables: OUTPUT_DIR, FORMAT_OVERRIDE, USE_COOKIES, USE_ARCHIVE,
# NO_SPONSORBLOCK, NO_METADATA, NO_INFO_JSON, NO_SLEEP, SUB_LANGS, EXTRA_ARGS
parse_options() {
    OUTPUT_DIR=""
    FORMAT_OVERRIDE=""
    USE_COOKIES=false
    USE_ARCHIVE=true
    NO_SPONSORBLOCK=false
    NO_METADATA=false
    NO_INFO_JSON=false
    NO_SLEEP=false
    SUB_LANGS="en"
    EXTRA_ARGS=()

    local arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --format)
                FORMAT_OVERRIDE="$2"
                shift 2
                ;;
            --cookies)
                USE_COOKIES=true
                shift
                ;;
            --no-archive)
                USE_ARCHIVE=false
                shift
                ;;
            --no-sponsorblock)
                NO_SPONSORBLOCK=true
                shift
                ;;
            --no-metadata)
                NO_METADATA=true
                shift
                ;;
            --no-info-json)
                NO_INFO_JSON=true
                shift
                ;;
            --no-sleep)
                NO_SLEEP=true
                shift
                ;;
            --sub-langs)
                SUB_LANGS="$2"
                shift 2
                ;;
            *)
                EXTRA_ARGS+=("$arg")
                shift
                ;;
        esac
    done
    return 0
}

# Resolve format string from shorthand
resolve_format() {
    local format="$1"
    local mode="$2"

    if [[ -n "$format" ]]; then
        case "$format" in
            "4k"|"2160p")
                echo "bv*[height<=2160]+ba/b[height<=2160]"
                ;;
            "1080p")
                echo "bv*[height<=1080]+ba/b[height<=1080]"
                ;;
            "720p")
                echo "bv*[height<=720]+ba/b[height<=720]"
                ;;
            "480p")
                echo "bv*[height<=480]+ba/b[height<=480]"
                ;;
            "audio-mp3"|"mp3")
                echo "bestaudio/best"
                ;;
            "audio-m4a"|"m4a")
                echo "bestaudio/best"
                ;;
            "audio-opus"|"opus")
                echo "bestaudio/best"
                ;;
            *)
                echo "$format"
                ;;
        esac
    else
        case "$mode" in
            "audio")
                echo "bestaudio/best"
                ;;
            *)
                echo "bv*[height<=1080]+ba/b[height<=1080]"
                ;;
        esac
    fi
    return 0
}

# Build common yt-dlp arguments
build_common_args() {
    local args=()

    # Metadata
    if [[ "$NO_METADATA" != true ]]; then
        args+=(--embed-metadata --embed-chapters --embed-thumbnail)
    fi

    # Info JSON
    if [[ "$NO_INFO_JSON" != true ]]; then
        args+=(--write-info-json)
    fi

    # SponsorBlock
    if [[ "$NO_SPONSORBLOCK" != true ]]; then
        args+=(--sponsorblock-remove sponsor)
    fi

    # Download archive
    if [[ "$USE_ARCHIVE" == true ]]; then
        mkdir -p "$CONFIG_DIR"
        args+=(--download-archive "$ARCHIVE_FILE")
    fi

    # Rate limiting
    if [[ "$NO_SLEEP" != true ]]; then
        args+=(--sleep-interval 1 --max-sleep-interval 5)
    fi

    # Cookies
    if [[ "$USE_COOKIES" == true ]]; then
        args+=(--cookies-from-browser chrome)
    fi

    # Error handling
    args+=(--ignore-errors --no-overwrites --continue)

    echo "${args[@]}"
    return 0
}

# Download video
download_video() {
    local url="$1"
    shift
    parse_options "$@"

    if ! check_ytdlp; then return 1; fi
    check_ffmpeg

    local output_dir
    output_dir=$(build_output_dir "video" "$url" "$OUTPUT_DIR")
    mkdir -p "$output_dir"

    local format
    format=$(resolve_format "$FORMAT_OVERRIDE" "video")

    print_header "Downloading Video"
    print_info "URL: $url"
    print_info "Output: $output_dir"
    print_info "Format: $format"

    local common_args
    common_args=$(build_common_args)

    # shellcheck disable=SC2086
    yt-dlp \
        -f "$format" \
        -o "$output_dir/%(title)s.%(ext)s" \
        --write-auto-subs \
        --sub-langs "$SUB_LANGS" \
        --convert-subs srt \
        --embed-subs \
        $common_args \
        "${EXTRA_ARGS[@]}" \
        "$url"

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_success "Video downloaded to: $output_dir"
    else
        print_error "Download failed (exit code: $exit_code)"
    fi
    return $exit_code
}

# Download audio only
download_audio() {
    local url="$1"
    shift
    parse_options "$@"

    if ! check_ytdlp; then return 1; fi
    check_ffmpeg

    local output_dir
    output_dir=$(build_output_dir "audio" "$url" "$OUTPUT_DIR")
    mkdir -p "$output_dir"

    local format
    format=$(resolve_format "$FORMAT_OVERRIDE" "audio")

    # Determine audio codec from format override
    local audio_format="mp3"
    case "$FORMAT_OVERRIDE" in
        "audio-m4a"|"m4a") audio_format="m4a" ;;
        "audio-opus"|"opus") audio_format="opus" ;;
        "audio-mp3"|"mp3"|"") audio_format="mp3" ;;
        *) audio_format="mp3" ;;  # Default to mp3 for unknown formats
    esac

    print_header "Extracting Audio"
    print_info "URL: $url"
    print_info "Output: $output_dir"
    print_info "Audio format: $audio_format"

    local common_args
    common_args=$(build_common_args)

    # shellcheck disable=SC2086
    yt-dlp \
        -f "$format" \
        -x \
        --audio-format "$audio_format" \
        --audio-quality 0 \
        -o "$output_dir/%(title)s.%(ext)s" \
        $common_args \
        "${EXTRA_ARGS[@]}" \
        "$url"

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_success "Audio extracted to: $output_dir"
    else
        print_error "Audio extraction failed (exit code: $exit_code)"
    fi
    return $exit_code
}

# Download playlist
download_playlist() {
    local url="$1"
    shift
    parse_options "$@"

    if ! check_ytdlp; then return 1; fi
    check_ffmpeg

    local output_dir
    output_dir=$(build_output_dir "playlist" "$url" "$OUTPUT_DIR")
    mkdir -p "$output_dir"

    local format
    format=$(resolve_format "$FORMAT_OVERRIDE" "video")

    print_header "Downloading Playlist"
    print_info "URL: $url"
    print_info "Output: $output_dir"
    print_info "Format: $format"

    local common_args
    common_args=$(build_common_args)

    # shellcheck disable=SC2086
    yt-dlp \
        -f "$format" \
        -o "$output_dir/%(playlist_index)03d - %(title)s.%(ext)s" \
        --write-auto-subs \
        --sub-langs "$SUB_LANGS" \
        --convert-subs srt \
        --embed-subs \
        --yes-playlist \
        $common_args \
        "${EXTRA_ARGS[@]}" \
        "$url"

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_success "Playlist downloaded to: $output_dir"
    else
        print_error "Playlist download failed (exit code: $exit_code)"
    fi
    return $exit_code
}

# Download channel
download_channel() {
    local url="$1"
    shift
    parse_options "$@"

    if ! check_ytdlp; then return 1; fi
    check_ffmpeg

    local output_dir
    output_dir=$(build_output_dir "channel" "$url" "$OUTPUT_DIR")
    mkdir -p "$output_dir"

    local format
    format=$(resolve_format "$FORMAT_OVERRIDE" "video")

    print_header "Downloading Channel"
    print_info "URL: $url"
    print_info "Output: $output_dir"
    print_info "Format: $format"

    local common_args
    common_args=$(build_common_args)

    # shellcheck disable=SC2086
    yt-dlp \
        -f "$format" \
        -o "$output_dir/%(upload_date)s - %(title)s.%(ext)s" \
        --write-auto-subs \
        --sub-langs "$SUB_LANGS" \
        --convert-subs srt \
        --embed-subs \
        --yes-playlist \
        $common_args \
        "${EXTRA_ARGS[@]}" \
        "$url"

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_success "Channel downloaded to: $output_dir"
    else
        print_error "Channel download failed (exit code: $exit_code)"
    fi
    return $exit_code
}

# Download transcript/subtitles only
download_transcript() {
    local url="$1"
    shift
    parse_options "$@"

    if ! check_ytdlp; then return 1; fi

    local output_dir
    output_dir=$(build_output_dir "transcript" "$url" "$OUTPUT_DIR")
    mkdir -p "$output_dir"

    print_header "Downloading Transcript"
    print_info "URL: $url"
    print_info "Output: $output_dir"
    print_info "Languages: $SUB_LANGS"

    local extra_transcript_args=()
    if [[ "$USE_COOKIES" == true ]]; then
        extra_transcript_args+=(--cookies-from-browser chrome)
    fi
    if [[ "$NO_INFO_JSON" != true ]]; then
        extra_transcript_args+=(--write-info-json)
    fi

    yt-dlp \
        --skip-download \
        --write-auto-subs \
        --write-subs \
        --sub-langs "$SUB_LANGS" \
        --convert-subs srt \
        -o "$output_dir/%(title)s.%(ext)s" \
        "${extra_transcript_args[@]}" \
        "${EXTRA_ARGS[@]}" \
        "$url"

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        print_success "Transcript downloaded to: $output_dir"
        # Show downloaded files
        print_info "Files:"
        ls -la "$output_dir"/ 2>/dev/null
    else
        print_error "Transcript download failed (exit code: $exit_code)"
    fi
    return $exit_code
}

# Convert local video file(s) to audio using ffmpeg
convert_local() {
    local input_path="$1"
    shift
    parse_options "$@"

    if ! check_ffmpeg; then
        print_error "ffmpeg is required for local file conversion."
        print_info "Run: yt-dlp-helper.sh install"
        return 1
    fi

    if [[ ! -e "$input_path" ]]; then
        print_error "File or directory not found: $input_path"
        return 1
    fi

    # Determine audio codec from format override
    local audio_ext="mp3"
    local audio_codec="libmp3lame"
    local audio_quality="0"
    case "$FORMAT_OVERRIDE" in
        "m4a"|"audio-m4a")
            audio_ext="m4a"
            audio_codec="aac"
            audio_quality="2"
            ;;
        "opus"|"audio-opus")
            audio_ext="opus"
            audio_codec="libopus"
            audio_quality="128k"
            ;;
        "wav")
            audio_ext="wav"
            audio_codec="pcm_s16le"
            audio_quality=""
            ;;
        "flac")
            audio_ext="flac"
            audio_codec="flac"
            audio_quality=""
            ;;
        *)
            # Default to mp3 for unknown formats
            ;;
    esac

    # Build output directory
    local output_dir
    if [[ -n "$OUTPUT_DIR" ]]; then
        output_dir="$OUTPUT_DIR"
    elif [[ -d "$input_path" ]]; then
        output_dir="$DEFAULT_DOWNLOAD_DIR/yt-dlp-convert-$(basename "$input_path")-$(get_timestamp)"
    else
        output_dir="$DEFAULT_DOWNLOAD_DIR/yt-dlp-convert-$(get_timestamp)"
    fi
    mkdir -p "$output_dir"

    print_header "Converting Local File(s) to Audio"
    print_info "Input: $input_path"
    print_info "Output: $output_dir"
    print_info "Format: $audio_ext ($audio_codec)"

    local file_count=0
    local success_count=0
    local fail_count=0

    # Process single file or directory
    local files=()
    if [[ -d "$input_path" ]]; then
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$input_path" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.webm" -o -name "*.avi" -o -name "*.mov" -o -name "*.flv" -o -name "*.wmv" -o -name "*.m4v" -o -name "*.ts" \) -print0 | sort -z)
    else
        files+=("$input_path")
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        print_error "No video files found in: $input_path"
        print_info "Supported: mp4, mkv, webm, avi, mov, flv, wmv, m4v, ts"
        return 1
    fi

    for file in "${files[@]}"; do
        file_count=$((file_count + 1))
        local basename
        basename=$(basename "$file")
        local name_no_ext="${basename%.*}"
        local output_file="$output_dir/${name_no_ext}.${audio_ext}"

        print_info "[$file_count/${#files[@]}] Converting: $basename"

        local ffmpeg_args=(-i "$file" -vn -acodec "$audio_codec")
        if [[ -n "$audio_quality" ]]; then
            case "$audio_codec" in
                "libmp3lame")
                    ffmpeg_args+=(-q:a "$audio_quality")
                    ;;
                "aac")
                    ffmpeg_args+=(-q:a "$audio_quality")
                    ;;
                "libopus")
                    ffmpeg_args+=(-b:a "$audio_quality")
                    ;;
                *)
                    # No quality setting for other codecs
                    ;;
            esac
        fi

        if [[ "$NO_METADATA" != true ]]; then
            ffmpeg_args+=(-map_metadata 0)
        fi

        ffmpeg_args+=(-y "$output_file")

        if ffmpeg "${ffmpeg_args[@]}" 2>/dev/null; then
            success_count=$((success_count + 1))
            print_success "  -> ${name_no_ext}.${audio_ext}"
        else
            fail_count=$((fail_count + 1))
            print_error "  Failed: $basename"
        fi
    done

    echo ""
    print_info "Results: $success_count/$file_count converted, $fail_count failed"
    if [[ $success_count -gt 0 ]]; then
        print_success "Output: $output_dir"
    fi
    return $fail_count
}

# Show video info without downloading
show_info() {
    local url="$1"
    shift
    parse_options "$@"

    if ! check_ytdlp; then return 1; fi

    print_header "Video Information"

    local cookie_args=()
    if [[ "$USE_COOKIES" == true ]]; then
        cookie_args=(--cookies-from-browser chrome)
    fi

    yt-dlp \
        --dump-json \
        --no-download \
        "${cookie_args[@]}" \
        "$url" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(f\"Title:       {data.get('title', 'N/A')}\")
    print(f\"Channel:     {data.get('channel', data.get('uploader', 'N/A'))}\")
    print(f\"Duration:    {data.get('duration_string', 'N/A')}\")
    print(f\"Upload date: {data.get('upload_date', 'N/A')}\")
    vc = data.get('view_count')
    print(f\"View count:  {vc:,}\" if isinstance(vc, int) else f\"View count:  {vc or 'N/A'}\")
    print(f\"Like count:  {data.get('like_count', 'N/A')}\")
    print(f\"Description: {(data.get('description', 'N/A') or 'N/A')[:200]}...\")
    print()
    print('Available formats:')
    for f in data.get('formats', []):
        res = f.get('resolution', 'N/A')
        ext = f.get('ext', 'N/A')
        vcodec = f.get('vcodec', 'none')
        acodec = f.get('acodec', 'none')
        filesize = f.get('filesize') or f.get('filesize_approx')
        size_str = f'{filesize / 1024 / 1024:.1f}MB' if filesize else 'N/A'
        if vcodec != 'none' or acodec != 'none':
            print(f'  {f.get(\"format_id\", \"?\"): <10} {res: <12} {ext: <6} v:{vcodec[:10]: <10} a:{acodec[:10]: <10} {size_str}')
except Exception as e:
    print(f'Error parsing info: {e}', file=sys.stderr)
"
    return $?
}

# Install yt-dlp and ffmpeg
install_ytdlp() {
    print_header "Installing yt-dlp and Dependencies"

    local os_type
    os_type=$(uname -s)

    case "$os_type" in
        "Darwin")
            if command -v brew &> /dev/null; then
                print_info "Installing via Homebrew..."
                brew install yt-dlp ffmpeg
            else
                print_info "Installing yt-dlp via pip..."
                pip3 install -U yt-dlp
                print_warning "Please install ffmpeg manually: https://ffmpeg.org/download.html"
            fi
            ;;
        "Linux")
            if command -v apt-get &> /dev/null; then
                print_info "Installing via apt..."
                sudo apt-get update && sudo apt-get install -y ffmpeg
                pip3 install -U yt-dlp
            elif command -v dnf &> /dev/null; then
                print_info "Installing via dnf..."
                sudo dnf install -y ffmpeg
                pip3 install -U yt-dlp
            elif command -v pacman &> /dev/null; then
                print_info "Installing via pacman..."
                sudo pacman -S --noconfirm yt-dlp ffmpeg
            else
                print_info "Installing yt-dlp via pip..."
                pip3 install -U yt-dlp
                print_warning "Please install ffmpeg manually: https://ffmpeg.org/download.html"
            fi
            ;;
        *)
            print_info "Installing yt-dlp via pip..."
            pip3 install -U yt-dlp
            print_warning "Please install ffmpeg manually: https://ffmpeg.org/download.html"
            ;;
    esac

    # Verify installation
    echo ""
    check_installation_status
    return 0
}

# Update yt-dlp
update_ytdlp() {
    print_header "Updating yt-dlp"

    if command -v brew &> /dev/null && brew list yt-dlp &> /dev/null; then
        print_info "Updating via Homebrew..."
        brew upgrade yt-dlp
    else
        print_info "Updating via pip..."
        pip3 install -U yt-dlp
    fi

    local version
    version=$(yt-dlp --version 2>/dev/null)
    if [[ -n "$version" ]]; then
        print_success "yt-dlp updated to version: $version"
    else
        print_error "Update may have failed. Check installation."
    fi
    return 0
}

# Generate default config file
generate_config() {
    print_header "Generating yt-dlp Configuration"

    mkdir -p "$CONFIG_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        print_warning "Config file already exists: $CONFIG_FILE"
        print_info "Creating backup: ${CONFIG_FILE}.bak"
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    fi

    cat > "$CONFIG_FILE" << 'YTDLP_CONFIG'
# yt-dlp configuration
# Generated by aidevops yt-dlp-helper.sh
# Location: ~/.config/yt-dlp/config

# Output template (overridden by helper script per-command)
# --output ~/Downloads/%(title)s.%(ext)s

# Format: best video up to 1080p + best audio, fallback to best combined
--format bestvideo[height<=1080]+bestaudio/best[height<=1080]

# Metadata embedding
--embed-metadata
--embed-thumbnail
--embed-chapters

# Subtitles
--embed-subs
--sub-langs en
--write-auto-subs
--convert-subs srt

# Metadata file
--write-info-json

# Download archive (skip already downloaded)
--download-archive ~/.config/yt-dlp/archive.txt

# SponsorBlock: remove sponsor segments
--sponsorblock-remove sponsor

# Rate limiting (polite downloading)
--sleep-interval 1
--max-sleep-interval 5

# Error handling
--ignore-errors
--no-overwrites
--continue
YTDLP_CONFIG

    print_success "Config written to: $CONFIG_FILE"
    print_info "Edit this file to change global defaults."
    print_info "The helper script overrides output templates per command."
    return 0
}

# Check installation status
check_installation_status() {
    print_header "yt-dlp Installation Status"

    # yt-dlp
    if command -v yt-dlp &> /dev/null; then
        local ytdlp_version
        ytdlp_version=$(yt-dlp --version 2>/dev/null)
        local ytdlp_path
        ytdlp_path=$(which yt-dlp)
        print_success "yt-dlp: $ytdlp_version ($ytdlp_path)"
    else
        print_error "yt-dlp: not installed"
    fi

    # ffmpeg
    if command -v ffmpeg &> /dev/null; then
        local ffmpeg_version
        ffmpeg_version=$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')
        print_success "ffmpeg: $ffmpeg_version"
    else
        print_error "ffmpeg: not installed (required for merging/conversion)"
    fi

    # Config file
    if [[ -f "$CONFIG_FILE" ]]; then
        print_success "Config: $CONFIG_FILE"
    else
        print_warning "Config: not found (run: yt-dlp-helper.sh config)"
    fi

    # Archive file
    if [[ -f "$ARCHIVE_FILE" ]]; then
        local archive_count
        archive_count=$(wc -l < "$ARCHIVE_FILE" | tr -d ' ')
        print_success "Archive: $ARCHIVE_FILE ($archive_count entries)"
    else
        print_info "Archive: not yet created (created on first download)"
    fi

    return 0
}

# Show help
show_help() {
    cat << 'EOF'
yt-dlp Helper - YouTube Video/Audio Downloader

Usage: yt-dlp-helper.sh <command> [url] [options]

Commands:
  video <url>       Download video (best quality, max 1080p)
  audio <url>       Extract audio only (MP3 by default)
  playlist <url>    Download full playlist
  channel <url>     Download all channel videos
  transcript <url>  Download subtitles/transcript only (no video)
  info <url>        Show video info without downloading
  convert <path>    Extract audio from local video file(s) via ffmpeg
  install           Install yt-dlp and ffmpeg
  update            Update yt-dlp to latest version
  config            Generate default config file (~/.config/yt-dlp/config)
  status            Check installation status
  help              Show this help message

Options:
  --output-dir <path>   Override output directory (default: ~/Downloads/)
  --format <fmt>        Format: 4k, 1080p, 720p, 480p, audio-mp3, audio-m4a, audio-opus
  --cookies             Use Chrome browser cookies (for private/age-restricted)
  --no-archive          Don't use download archive (allow re-downloads)
  --no-sponsorblock     Disable SponsorBlock sponsor removal
  --no-metadata         Skip metadata/thumbnail/chapter embedding
  --no-info-json        Skip writing info JSON file
  --no-sleep            Disable rate-limiting sleep between downloads
  --sub-langs <langs>   Subtitle languages (default: en). Use "all" for all.

Examples:
  yt-dlp-helper.sh video "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
  yt-dlp-helper.sh audio "https://www.youtube.com/watch?v=dQw4w9WgXcQ" --format m4a
  yt-dlp-helper.sh playlist "https://www.youtube.com/playlist?list=PLxxx" --format 720p
  yt-dlp-helper.sh channel "https://www.youtube.com/@channelname" --output-dir ~/Videos
  yt-dlp-helper.sh transcript "https://www.youtube.com/watch?v=xxx" --sub-langs "en,es"
  yt-dlp-helper.sh video "https://www.youtube.com/watch?v=xxx" --cookies --format 4k
  yt-dlp-helper.sh convert ~/Videos/lecture.mp4
  yt-dlp-helper.sh convert ~/Videos/ --format m4a --output-dir ~/Music

Output directories:
  ~/Downloads/yt-dlp-video-{title}-{timestamp}/
  ~/Downloads/yt-dlp-audio-{title}-{timestamp}/
  ~/Downloads/yt-dlp-playlist-{name}-{timestamp}/
  ~/Downloads/yt-dlp-channel-{name}-{timestamp}/
  ~/Downloads/yt-dlp-transcript-{title}-{timestamp}/
EOF
    return 0
}

# Main entry point
main() {
    local command="${1:-help}"
    local url="$2"
    shift 2 2>/dev/null || shift $# 2>/dev/null

    case "$command" in
        "video")
            if [[ -z "$url" ]]; then
                print_error "URL required. Usage: yt-dlp-helper.sh video <url>"
                return 1
            fi
            download_video "$url" "$@"
            ;;
        "audio")
            if [[ -z "$url" ]]; then
                print_error "URL required. Usage: yt-dlp-helper.sh audio <url>"
                return 1
            fi
            download_audio "$url" "$@"
            ;;
        "playlist")
            if [[ -z "$url" ]]; then
                print_error "URL required. Usage: yt-dlp-helper.sh playlist <url>"
                return 1
            fi
            download_playlist "$url" "$@"
            ;;
        "channel")
            if [[ -z "$url" ]]; then
                print_error "URL required. Usage: yt-dlp-helper.sh channel <url>"
                return 1
            fi
            download_channel "$url" "$@"
            ;;
        "transcript")
            if [[ -z "$url" ]]; then
                print_error "URL required. Usage: yt-dlp-helper.sh transcript <url>"
                return 1
            fi
            download_transcript "$url" "$@"
            ;;
        "info")
            if [[ -z "$url" ]]; then
                print_error "URL required. Usage: yt-dlp-helper.sh info <url>"
                return 1
            fi
            show_info "$url" "$@"
            ;;
        "convert")
            if [[ -z "$url" ]]; then
                print_error "File/directory required. Usage: yt-dlp-helper.sh convert <path> [options]"
                return 1
            fi
            convert_local "$url" "$@"
            ;;
        "install")
            install_ytdlp
            ;;
        "update")
            update_ytdlp
            ;;
        "config")
            generate_config
            ;;
        "status")
            check_installation_status
            ;;
        "help"|"-h"|"--help"|"")
            show_help
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
