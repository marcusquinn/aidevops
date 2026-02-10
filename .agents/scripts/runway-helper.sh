#!/usr/bin/env bash
# runway-helper.sh - CLI helper for Runway API video, image, and audio generation
# Usage: runway-helper.sh [command] [options]
# Commands: video, image, tts, sts, sfx, dub, isolate, status, cancel, credits, usage, help

set -euo pipefail

# --- Configuration ---
RUNWAY_API_BASE="https://api.dev.runwayml.com"
RUNWAY_API_VERSION="2024-11-06"
# SCRIPT_DIR available for future use by sourcing scripts
# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load credentials ---
load_credentials() {
    if [[ -z "${RUNWAYML_API_SECRET:-}" ]]; then
        # Try gopass first
        if command -v gopass &>/dev/null; then
            RUNWAYML_API_SECRET="$(gopass show -o "aidevops/RUNWAYML_API_SECRET" 2>/dev/null || true)"
        fi
        # Fallback to credentials file
        if [[ -z "${RUNWAYML_API_SECRET:-}" ]] && [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
            # shellcheck source=/dev/null
            source "$HOME/.config/aidevops/credentials.sh"
        fi
        if [[ -z "${RUNWAYML_API_SECRET:-}" ]]; then
            echo "ERROR: RUNWAYML_API_SECRET not set." >&2
            echo "Run: aidevops secret set RUNWAYML_API_SECRET" >&2
            echo "Or export RUNWAYML_API_SECRET in ~/.config/aidevops/credentials.sh" >&2
            return 1
        fi
    fi
    return 0
}

# --- API request helper ---
runway_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local curl_args=(
        -s -w "\n%{http_code}"
        -X "$method"
        -H "Authorization: Bearer ${RUNWAYML_API_SECRET}"
        -H "X-Runway-Version: ${RUNWAY_API_VERSION}"
        -H "Content-Type: application/json"
    )

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    local response
    response="$(curl "${curl_args[@]}" "${RUNWAY_API_BASE}${endpoint}")"

    local http_code
    http_code="$(echo "$response" | tail -1)"
    local body
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" -ge 400 ]]; then
        echo "ERROR: HTTP $http_code" >&2
        echo "$body" | jq . 2>/dev/null || echo "$body" >&2
        return 1
    fi

    echo "$body"
    return 0
}

# --- Commands ---

cmd_video() {
    local image=""
    local prompt=""
    local model="gen4_turbo"
    local ratio="1280:720"
    local duration=""
    local seed=""
    local audio=""
    local video_uri=""
    local wait_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image|-i) image="$2"; shift 2 ;;
            --video|-v) video_uri="$2"; shift 2 ;;
            --prompt|-p) prompt="$2"; shift 2 ;;
            --model|-m) model="$2"; shift 2 ;;
            --ratio|-r) ratio="$2"; shift 2 ;;
            --duration|-d) duration="$2"; shift 2 ;;
            --seed|-s) seed="$2"; shift 2 ;;
            --audio) audio="$2"; shift 2 ;;
            --wait|-w) wait_flag=true; shift ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    local json_body=""

    # Determine endpoint based on inputs
    if [[ -n "$video_uri" ]]; then
        # Video-to-video (Aleph)
        json_body="{\"model\":\"${model}\",\"videoUri\":\"${video_uri}\",\"promptText\":\"${prompt}\"}"
        local endpoint="/v1/video_to_video"
    elif [[ -n "$image" ]]; then
        # Image-to-video
        json_body="{\"model\":\"${model}\",\"promptImage\":\"${image}\",\"ratio\":\"${ratio}\""
        if [[ -n "$prompt" ]]; then
            json_body="${json_body},\"promptText\":\"${prompt}\""
        fi
        if [[ -n "$duration" ]]; then
            json_body="${json_body},\"duration\":${duration}"
        fi
        if [[ -n "$seed" ]]; then
            json_body="${json_body},\"seed\":${seed}"
        fi
        json_body="${json_body}}"
        local endpoint="/v1/image_to_video"
    else
        # Text-to-video (Veo models)
        if [[ -z "$prompt" ]]; then
            echo "ERROR: --prompt is required for text-to-video" >&2
            return 1
        fi
        json_body="{\"model\":\"${model}\",\"promptText\":\"${prompt}\",\"ratio\":\"${ratio}\""
        if [[ -n "$duration" ]]; then
            json_body="${json_body},\"duration\":${duration}"
        fi
        if [[ -n "$audio" ]]; then
            json_body="${json_body},\"audio\":${audio}"
        fi
        json_body="${json_body}}"
        local endpoint="/v1/text_to_video"
    fi

    local result
    result="$(runway_api POST "$endpoint" "$json_body")"
    local task_id
    task_id="$(echo "$result" | jq -r '.id // empty')"

    if [[ -z "$task_id" ]]; then
        echo "ERROR: No task ID returned" >&2
        echo "$result" >&2
        return 1
    fi

    echo "Task created: $task_id"
    echo "Model: $model"
    echo "Endpoint: $endpoint"

    if [[ "$wait_flag" == true ]]; then
        cmd_wait "$task_id"
    fi

    return 0
}

cmd_image() {
    local prompt=""
    local model="gen4_image"
    local ratio="1920:1080"
    local seed=""
    local wait_flag=false
    local -a refs=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prompt|-p) prompt="$2"; shift 2 ;;
            --model|-m) model="$2"; shift 2 ;;
            --ratio|-r) ratio="$2"; shift 2 ;;
            --seed|-s) seed="$2"; shift 2 ;;
            --ref) refs+=("$2"); shift 2 ;;
            --wait|-w) wait_flag=true; shift ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    if [[ -z "$prompt" ]]; then
        echo "ERROR: --prompt is required" >&2
        return 1
    fi

    # Build reference images JSON array
    local ref_json="[]"
    if [[ ${#refs[@]} -gt 0 ]]; then
        ref_json="["
        local first=true
        for ref in "${refs[@]}"; do
            if [[ "$first" != true ]]; then
                ref_json="${ref_json},"
            fi
            first=false
            # Format: url:tag or just url
            if [[ "$ref" == *":"* ]] && [[ "$ref" != "https://"* ]] && [[ "$ref" != "http://"* ]]; then
                # Has a tag suffix (not a URL scheme colon)
                local ref_uri="${ref%:*}"
                local ref_tag="${ref##*:}"
                ref_json="${ref_json}{\"uri\":\"${ref_uri}\",\"tag\":\"${ref_tag}\"}"
            elif [[ "$ref" == *"https://"* ]]; then
                # URL with possible tag after space
                local ref_uri="$ref"
                ref_json="${ref_json}{\"uri\":\"${ref_uri}\"}"
            else
                ref_json="${ref_json}{\"uri\":\"${ref}\"}"
            fi
        done
        ref_json="${ref_json}]"
    fi

    local json_body="{\"model\":\"${model}\",\"promptText\":\"${prompt}\",\"ratio\":\"${ratio}\""
    if [[ "$ref_json" != "[]" ]]; then
        json_body="${json_body},\"referenceImages\":${ref_json}"
    fi
    if [[ -n "$seed" ]]; then
        json_body="${json_body},\"seed\":${seed}"
    fi
    json_body="${json_body}}"

    local result
    result="$(runway_api POST "/v1/text_to_image" "$json_body")"
    local task_id
    task_id="$(echo "$result" | jq -r '.id // empty')"

    if [[ -z "$task_id" ]]; then
        echo "ERROR: No task ID returned" >&2
        echo "$result" >&2
        return 1
    fi

    echo "Task created: $task_id"
    echo "Model: $model"

    if [[ "$wait_flag" == true ]]; then
        cmd_wait "$task_id"
    fi

    return 0
}

cmd_tts() {
    local text=""
    local voice="Leslie"
    local wait_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --text|-t) text="$2"; shift 2 ;;
            --voice) voice="$2"; shift 2 ;;
            --wait|-w) wait_flag=true; shift ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    if [[ -z "$text" ]]; then
        echo "ERROR: --text is required" >&2
        return 1
    fi

    local json_body
    json_body="{\"model\":\"eleven_multilingual_v2\",\"promptText\":\"${text}\",\"voice\":{\"type\":\"runway-preset\",\"presetId\":\"${voice}\"}}"

    local result
    result="$(runway_api POST "/v1/text_to_speech" "$json_body")"
    local task_id
    task_id="$(echo "$result" | jq -r '.id // empty')"

    if [[ -z "$task_id" ]]; then
        echo "ERROR: No task ID returned" >&2
        echo "$result" >&2
        return 1
    fi

    echo "Task created: $task_id"
    echo "Voice: $voice"

    if [[ "$wait_flag" == true ]]; then
        cmd_wait "$task_id"
    fi

    return 0
}

cmd_sts() {
    local audio_uri=""
    local video_uri=""
    local voice="Maggie"
    local remove_noise=""
    local wait_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --audio|-a) audio_uri="$2"; shift 2 ;;
            --video|-v) video_uri="$2"; shift 2 ;;
            --voice) voice="$2"; shift 2 ;;
            --remove-noise) remove_noise="true"; shift ;;
            --wait|-w) wait_flag=true; shift ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    local media_json=""
    if [[ -n "$video_uri" ]]; then
        media_json="{\"type\":\"video\",\"uri\":\"${video_uri}\"}"
    elif [[ -n "$audio_uri" ]]; then
        media_json="{\"type\":\"audio\",\"uri\":\"${audio_uri}\"}"
    else
        echo "ERROR: --audio or --video is required" >&2
        return 1
    fi

    local json_body="{\"model\":\"eleven_multilingual_sts_v2\",\"media\":${media_json},\"voice\":{\"type\":\"runway-preset\",\"presetId\":\"${voice}\"}"
    if [[ -n "$remove_noise" ]]; then
        json_body="${json_body},\"removeBackgroundNoise\":true"
    fi
    json_body="${json_body}}"

    local result
    result="$(runway_api POST "/v1/speech_to_speech" "$json_body")"
    local task_id
    task_id="$(echo "$result" | jq -r '.id // empty')"

    if [[ -z "$task_id" ]]; then
        echo "ERROR: No task ID returned" >&2
        echo "$result" >&2
        return 1
    fi

    echo "Task created: $task_id"
    echo "Voice: $voice"

    if [[ "$wait_flag" == true ]]; then
        cmd_wait "$task_id"
    fi

    return 0
}

cmd_sfx() {
    local prompt=""
    local duration=""
    local loop=""
    local wait_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prompt|-p) prompt="$2"; shift 2 ;;
            --duration|-d) duration="$2"; shift 2 ;;
            --loop) loop="true"; shift ;;
            --wait|-w) wait_flag=true; shift ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    if [[ -z "$prompt" ]]; then
        echo "ERROR: --prompt is required" >&2
        return 1
    fi

    local json_body="{\"model\":\"eleven_text_to_sound_v2\",\"promptText\":\"${prompt}\""
    if [[ -n "$duration" ]]; then
        json_body="${json_body},\"duration\":${duration}"
    fi
    if [[ -n "$loop" ]]; then
        json_body="${json_body},\"loop\":true"
    fi
    json_body="${json_body}}"

    local result
    result="$(runway_api POST "/v1/sound_effect" "$json_body")"
    local task_id
    task_id="$(echo "$result" | jq -r '.id // empty')"

    if [[ -z "$task_id" ]]; then
        echo "ERROR: No task ID returned" >&2
        echo "$result" >&2
        return 1
    fi

    echo "Task created: $task_id"

    if [[ "$wait_flag" == true ]]; then
        cmd_wait "$task_id"
    fi

    return 0
}

cmd_dub() {
    local audio_uri=""
    local target_lang=""
    local disable_cloning=""
    local drop_bg=""
    local num_speakers=""
    local wait_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --audio|-a) audio_uri="$2"; shift 2 ;;
            --lang|-l) target_lang="$2"; shift 2 ;;
            --no-clone) disable_cloning="true"; shift ;;
            --drop-bg) drop_bg="true"; shift ;;
            --speakers) num_speakers="$2"; shift 2 ;;
            --wait|-w) wait_flag=true; shift ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    if [[ -z "$audio_uri" ]]; then
        echo "ERROR: --audio is required" >&2
        return 1
    fi
    if [[ -z "$target_lang" ]]; then
        echo "ERROR: --lang is required (e.g., es, fr, de, ja)" >&2
        return 1
    fi

    local json_body="{\"model\":\"eleven_voice_dubbing\",\"audioUri\":\"${audio_uri}\",\"targetLang\":\"${target_lang}\""
    if [[ -n "$disable_cloning" ]]; then
        json_body="${json_body},\"disableVoiceCloning\":true"
    fi
    if [[ -n "$drop_bg" ]]; then
        json_body="${json_body},\"dropBackgroundAudio\":true"
    fi
    if [[ -n "$num_speakers" ]]; then
        json_body="${json_body},\"numSpeakers\":${num_speakers}"
    fi
    json_body="${json_body}}"

    local result
    result="$(runway_api POST "/v1/voice_dubbing" "$json_body")"
    local task_id
    task_id="$(echo "$result" | jq -r '.id // empty')"

    if [[ -z "$task_id" ]]; then
        echo "ERROR: No task ID returned" >&2
        echo "$result" >&2
        return 1
    fi

    echo "Task created: $task_id"
    echo "Target language: $target_lang"

    if [[ "$wait_flag" == true ]]; then
        cmd_wait "$task_id"
    fi

    return 0
}

cmd_isolate() {
    local audio_uri=""
    local wait_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --audio|-a) audio_uri="$2"; shift 2 ;;
            --wait|-w) wait_flag=true; shift ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    if [[ -z "$audio_uri" ]]; then
        echo "ERROR: --audio is required" >&2
        return 1
    fi

    local json_body="{\"model\":\"eleven_voice_isolation\",\"audioUri\":\"${audio_uri}\"}"

    local result
    result="$(runway_api POST "/v1/voice_isolation" "$json_body")"
    local task_id
    task_id="$(echo "$result" | jq -r '.id // empty')"

    if [[ -z "$task_id" ]]; then
        echo "ERROR: No task ID returned" >&2
        echo "$result" >&2
        return 1
    fi

    echo "Task created: $task_id"

    if [[ "$wait_flag" == true ]]; then
        cmd_wait "$task_id"
    fi

    return 0
}

cmd_status() {
    local task_id="${1:-}"
    if [[ -z "$task_id" ]]; then
        echo "Usage: runway-helper.sh status <task-id>" >&2
        return 1
    fi

    local result
    result="$(runway_api GET "/v1/tasks/${task_id}")"
    echo "$result" | jq .
    return 0
}

cmd_wait() {
    local task_id="${1:-}"
    local timeout="${2:-600}"
    if [[ -z "$task_id" ]]; then
        echo "Usage: runway-helper.sh wait <task-id> [timeout-seconds]" >&2
        return 1
    fi

    local elapsed=0
    local interval=5
    echo "Waiting for task $task_id (timeout: ${timeout}s)..."

    while [[ "$elapsed" -lt "$timeout" ]]; do
        local result
        result="$(runway_api GET "/v1/tasks/${task_id}")"
        local status
        status="$(echo "$result" | jq -r '.status // "UNKNOWN"')"

        case "$status" in
            SUCCEEDED)
                echo "Task succeeded!"
                echo "$result" | jq .
                return 0
                ;;
            FAILED)
                echo "Task failed!" >&2
                echo "$result" | jq . >&2
                return 1
                ;;
            PENDING|THROTTLED|RUNNING)
                echo "  Status: $status (${elapsed}s elapsed)"
                ;;
            *)
                echo "  Unknown status: $status" >&2
                ;;
        esac

        sleep "$interval"
        elapsed=$((elapsed + interval))
        # Add jitter: vary interval between 5-8 seconds
        interval=$(( (RANDOM % 4) + 5 ))
    done

    echo "ERROR: Timeout after ${timeout}s" >&2
    return 1
}

cmd_cancel() {
    local task_id="${1:-}"
    if [[ -z "$task_id" ]]; then
        echo "Usage: runway-helper.sh cancel <task-id>" >&2
        return 1
    fi

    runway_api DELETE "/v1/tasks/${task_id}" >/dev/null
    echo "Task $task_id cancelled/deleted."
    return 0
}

cmd_credits() {
    local result
    result="$(runway_api GET "/v1/organization")"
    local balance
    balance="$(echo "$result" | jq -r '.creditBalance // "unknown"')"
    echo "Credit balance: $balance credits (\$$(echo "scale=2; $balance / 100" | bc 2>/dev/null || echo "?"))"
    echo "$result" | jq '{tier: .tier, creditBalance: .creditBalance}'
    return 0
}

cmd_usage() {
    local start_date=""
    local end_date=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start) start_date="$2"; shift 2 ;;
            --end) end_date="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
    done

    local json_body="{}"
    if [[ -n "$start_date" ]] || [[ -n "$end_date" ]]; then
        json_body="{"
        local first=true
        if [[ -n "$start_date" ]]; then
            json_body="${json_body}\"startDate\":\"${start_date}\""
            first=false
        fi
        if [[ -n "$end_date" ]]; then
            if [[ "$first" != true ]]; then
                json_body="${json_body},"
            fi
            json_body="${json_body}\"beforeDate\":\"${end_date}\""
        fi
        json_body="${json_body}}"
    fi

    local result
    result="$(runway_api POST "/v1/organization/usage" "$json_body")"
    echo "$result" | jq .
    return 0
}

cmd_help() {
    cat <<'HELP'
runway-helper.sh - Runway API CLI for video, image, and audio generation

COMMANDS:
  video     Generate video from image, text, or video
  image     Generate image from text with optional references
  tts       Text-to-speech (ElevenLabs via Runway)
  sts       Speech-to-speech voice conversion
  sfx       Generate sound effects from text
  dub       Voice dubbing to target language
  isolate   Isolate voice from background audio
  status    Check task status
  wait      Wait for task completion (polling)
  cancel    Cancel or delete a task
  credits   Check credit balance
  usage     Query credit usage history
  help      Show this help

VIDEO OPTIONS:
  --image, -i URL     Source image URL (image-to-video)
  --video, -v URL     Source video URL (video-to-video, uses gen4_aleph)
  --prompt, -p TEXT    Text prompt describing the generation
  --model, -m MODEL   Model name (default: gen4_turbo)
                       Video: gen4_turbo, gen4_aleph, act_two, veo3, veo3.1, veo3.1_fast
  --ratio, -r RATIO   Output ratio (default: 1280:720)
  --duration, -d SECS  Duration in seconds (2-10)
  --seed, -s NUM      Seed for reproducibility (0-4294967295)
  --audio BOOL        Enable audio for Veo models (true/false)
  --wait, -w          Wait for task completion

IMAGE OPTIONS:
  --prompt, -p TEXT    Text prompt (required, use @tag for references)
  --model, -m MODEL   Model name (default: gen4_image)
                       Image: gen4_image, gen4_image_turbo, gemini_2.5_flash
  --ratio, -r RATIO   Output ratio (default: 1920:1080)
  --ref URL[:TAG]      Reference image (repeatable, up to 3)
  --seed, -s NUM      Seed for reproducibility
  --wait, -w          Wait for task completion

TTS OPTIONS:
  --text, -t TEXT      Text to speak (required)
  --voice NAME         Voice preset (default: Leslie)
  --wait, -w           Wait for task completion

STS OPTIONS:
  --audio, -a URL      Source audio URL (required unless --video)
  --video, -v URL      Source video URL (alternative to --audio)
  --voice NAME         Target voice preset (default: Maggie)
  --remove-noise       Remove background noise
  --wait, -w           Wait for task completion

SFX OPTIONS:
  --prompt, -p TEXT    Sound description (required, up to 3000 chars)
  --duration, -d SECS  Duration 0.5-30s (auto if omitted)
  --loop               Generate seamless loop
  --wait, -w           Wait for task completion

DUB OPTIONS:
  --audio, -a URL      Source audio URL (required)
  --lang, -l CODE      Target language code (required, e.g., es, fr, de, ja)
  --no-clone           Use generic voice instead of cloning
  --drop-bg            Remove background audio
  --speakers NUM       Number of speakers (auto-detected)
  --wait, -w           Wait for task completion

ISOLATE OPTIONS:
  --audio, -a URL      Source audio URL (required, 4.6s-3600s)
  --wait, -w           Wait for task completion

USAGE OPTIONS:
  --start DATE        Start date (YYYY-MM-DD)
  --end DATE          End date (YYYY-MM-DD)

EXAMPLES:
  # Image-to-video with Gen-4 Turbo
  runway-helper.sh video -i https://example.com/photo.jpg \
    -p "Camera slowly pans across the scene" -d 5

  # Text-to-video with Veo 3.1
  runway-helper.sh video -p "A cinematic mountain landscape" \
    -m veo3.1 -r 1920:1080 -d 8 --wait

  # Image generation with references
  runway-helper.sh image -p "@person in a garden" \
    --ref "https://example.com/face.jpg:person" \
    -m gen4_image -r 1920:1080

  # Text-to-speech
  runway-helper.sh tts -t "Hello, welcome to the show" --voice Noah

  # Speech-to-speech voice conversion
  runway-helper.sh sts -a https://example.com/audio.mp3 --voice Maggie

  # Sound effects
  runway-helper.sh sfx -p "A thunderstorm with heavy rain" -d 10 --loop

  # Voice dubbing to Spanish
  runway-helper.sh dub -a https://example.com/audio.mp3 -l es

  # Voice isolation
  runway-helper.sh isolate -a https://example.com/noisy-audio.mp3 --wait

  # Check credits
  runway-helper.sh credits

  # Poll task until complete
  runway-helper.sh wait abc-123-def

ENVIRONMENT:
  RUNWAYML_API_SECRET   API secret key (required)

VOICE PRESETS:
  Maya, Arjun, Serene, Bernard, Billy, Mark, Clint, Mabel, Chad, Leslie,
  Eleanor, Elias, Elliot, Grungle, Brodie, Sandra, Kirk, Kylie, Lara, Lisa,
  Malachi, Marlene, Martin, Miriam, Monster, Paula, Pip, Rusty, Ragnar,
  Xylar, Maggie, Jack, Katie, Noah, James, Rina, Ella, Mariah, Frank,
  Claudia, Niki, Vincent, Kendrick, Myrna, Tom, Wanda, Benjamin, Kiana, Rachel

DUBBING LANGUAGES:
  en, hi, pt, zh, es, fr, de, ja, ar, ru, ko, id, it, nl, tr, pl, sv,
  fil, ms, ro, uk, el, cs, da, fi, bg, hr, sk, ta
HELP
    return 0
}

# --- Main ---
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        video)   load_credentials && cmd_video "$@" ;;
        image)   load_credentials && cmd_image "$@" ;;
        tts)     load_credentials && cmd_tts "$@" ;;
        sts)     load_credentials && cmd_sts "$@" ;;
        sfx)     load_credentials && cmd_sfx "$@" ;;
        dub)     load_credentials && cmd_dub "$@" ;;
        isolate) load_credentials && cmd_isolate "$@" ;;
        status)  load_credentials && cmd_status "$@" ;;
        wait)    load_credentials && cmd_wait "$@" ;;
        cancel)  load_credentials && cmd_cancel "$@" ;;
        credits) load_credentials && cmd_credits "$@" ;;
        usage)   load_credentials && cmd_usage "$@" ;;
        help|--help|-h) cmd_help ;;
        *) echo "Unknown command: $command" >&2; cmd_help; return 1 ;;
    esac
}

main "$@"
