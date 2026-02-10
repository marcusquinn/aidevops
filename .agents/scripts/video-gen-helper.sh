#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2129
set -euo pipefail

# Video Generation Helper Script
# Unified CLI for AI video generation APIs: Sora 2, Veo 3.1, and Nanobanana Pro (via Higgsfield)
#
# Usage: video-gen-helper.sh <command> [options]
#
# Commands:
#   generate    Generate a video from text prompt
#   status      Check generation job status
#   download    Download completed video
#   list        List recent video jobs
#   models      Show available models and capabilities
#   help        Show this help message

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Configuration
# =============================================================================

# Credential loading (from gopass or credentials.sh fallback)
load_credentials() {
    local provider="$1"

    case "$provider" in
        sora|openai)
            if command -v gopass >/dev/null 2>&1 && gopass show "aidevops/openai-api-key" >/dev/null 2>&1; then
                OPENAI_API_KEY="$(gopass show -o "aidevops/openai-api-key" 2>/dev/null)" || true
            fi
            if [[ -z "${OPENAI_API_KEY:-}" ]] && [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
                source "${HOME}/.config/aidevops/credentials.sh"
            fi
            if [[ -z "${OPENAI_API_KEY:-}" ]]; then
                print_error "OPENAI_API_KEY not set. Run: aidevops secret set openai-api-key"
                return 1
            fi
            ;;
        veo|google)
            # Veo uses gcloud ADC or GOOGLE_API_KEY
            if command -v gopass >/dev/null 2>&1 && gopass show "aidevops/google-api-key" >/dev/null 2>&1; then
                GOOGLE_API_KEY="$(gopass show -o "aidevops/google-api-key" 2>/dev/null)" || true
            fi
            if [[ -z "${GOOGLE_API_KEY:-}" ]] && [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
                source "${HOME}/.config/aidevops/credentials.sh"
            fi
            # Veo can also use gcloud auth — check for that
            if [[ -z "${GOOGLE_API_KEY:-}" ]] && ! command -v gcloud >/dev/null 2>&1; then
                print_error "GOOGLE_API_KEY not set and gcloud CLI not found. Set up Google Cloud auth."
                return 1
            fi
            ;;
        nanobanana|higgsfield)
            if command -v gopass >/dev/null 2>&1 && gopass show "aidevops/higgsfield-api-key" >/dev/null 2>&1; then
                HIGGSFIELD_API_KEY="$(gopass show -o "aidevops/higgsfield-api-key" 2>/dev/null)" || true
                HIGGSFIELD_SECRET="$(gopass show -o "aidevops/higgsfield-secret" 2>/dev/null)" || true
            fi
            if [[ -z "${HIGGSFIELD_API_KEY:-}" ]] && [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
                source "${HOME}/.config/aidevops/credentials.sh"
            fi
            if [[ -z "${HIGGSFIELD_API_KEY:-}" ]] || [[ -z "${HIGGSFIELD_SECRET:-}" ]]; then
                print_error "HIGGSFIELD_API_KEY/HIGGSFIELD_SECRET not set. Run: aidevops secret set higgsfield-api-key"
                return 1
            fi
            ;;
        *)
            print_error "Unknown provider: $provider"
            return 1
            ;;
    esac

    return 0
}

# =============================================================================
# Sora 2 (OpenAI) Functions
# =============================================================================

sora_generate() {
    local prompt="$1"
    local model="${2:-sora-2}"
    local seconds="${3:-4}"
    local size="${4:-1280x720}"

    load_credentials "sora" || return 1

    print_info "Generating video with Sora 2 (model=$model, ${seconds}s, $size)..."

    local response
    response=$(curl -s -X POST "https://api.openai.com/v1/videos" \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" \
        -H "${CONTENT_TYPE_JSON}" \
        -d "{
            \"prompt\": $(printf '%s' "$prompt" | jq -Rs .),
            \"model\": \"$model\",
            \"seconds\": \"$seconds\",
            \"size\": \"$size\"
        }")

    local job_id
    job_id=$(printf '%s' "$response" | jq -r '.id // empty')

    if [[ -z "$job_id" ]]; then
        print_error "Failed to create video job"
        printf '%s\n' "$response" | jq . 2>/dev/null || printf '%s\n' "$response"
        return 1
    fi

    print_success "Video job created: $job_id"
    printf '%s\n' "$response" | jq '{ id, status, model, seconds, size }'
    return 0
}

sora_status() {
    local job_id="$1"

    load_credentials "sora" || return 1

    local response
    response=$(curl -s "https://api.openai.com/v1/videos/${job_id}" \
        -H "Authorization: Bearer ${OPENAI_API_KEY}")

    printf '%s\n' "$response" | jq '{ id, status, progress, model, seconds, size, completed_at, expires_at }'
    return 0
}

sora_download() {
    local job_id="$1"
    local output_path="${2:-.}"

    load_credentials "sora" || return 1

    local status_response
    status_response=$(curl -s "https://api.openai.com/v1/videos/${job_id}" \
        -H "Authorization: Bearer ${OPENAI_API_KEY}")

    local status
    status=$(printf '%s' "$status_response" | jq -r '.status')

    if [[ "$status" != "completed" ]]; then
        print_error "Video not ready. Status: $status"
        return 1
    fi

    print_info "Downloading video ${job_id}..."
    curl -s "https://api.openai.com/v1/videos/${job_id}/content" \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" \
        -o "${output_path}/sora-${job_id}.mp4"

    print_success "Downloaded to ${output_path}/sora-${job_id}.mp4"
    return 0
}

sora_list() {
    load_credentials "sora" || return 1

    local response
    response=$(curl -s "https://api.openai.com/v1/videos" \
        -H "Authorization: Bearer ${OPENAI_API_KEY}")

    printf '%s\n' "$response" | jq '.data[] | { id, status, model, seconds, prompt: .prompt[:60], created_at }' 2>/dev/null || \
        printf '%s\n' "$response" | jq .
    return 0
}

# =============================================================================
# Veo 3.1 (Google Vertex AI) Functions
# =============================================================================

veo_generate() {
    local prompt="$1"
    local model="${2:-veo-3.1-generate-001}"
    local aspect_ratio="${3:-16:9}"
    local output_gcs_uri="${4:-}"

    # Veo supports two auth paths: API key (Gemini API) or gcloud ADC (Vertex AI)
    if [[ -n "${GOOGLE_API_KEY:-}" ]]; then
        veo_generate_gemini_api "$prompt" "$model" "$aspect_ratio"
    else
        veo_generate_vertex_ai "$prompt" "$model" "$aspect_ratio" "$output_gcs_uri"
    fi
}

veo_generate_gemini_api() {
    local prompt="$1"
    local model="${2:-veo-3.1-generate-001}"
    local aspect_ratio="${3:-16:9}"

    load_credentials "veo" || return 1

    print_info "Generating video with Veo (model=$model, aspect=$aspect_ratio) via Gemini API..."

    local response
    response=$(curl -s -X POST \
        "https://generativelanguage.googleapis.com/v1beta/models/${model}:predictLongRunning?key=${GOOGLE_API_KEY}" \
        -H "${CONTENT_TYPE_JSON}" \
        -d "{
            \"instances\": [{
                \"prompt\": $(printf '%s' "$prompt" | jq -Rs .)
            }],
            \"parameters\": {
                \"aspectRatio\": \"$aspect_ratio\",
                \"sampleCount\": 1
            }
        }")

    local op_name
    op_name=$(printf '%s' "$response" | jq -r '.name // empty')

    if [[ -z "$op_name" ]]; then
        print_error "Failed to create Veo video job"
        printf '%s\n' "$response" | jq . 2>/dev/null || printf '%s\n' "$response"
        return 1
    fi

    print_success "Veo operation started: $op_name"
    printf '%s\n' "$response" | jq '{ name, done, metadata }'
    return 0
}

veo_generate_vertex_ai() {
    local prompt="$1"
    local model="${2:-veo-3.1-generate-001}"
    local aspect_ratio="${3:-16:9}"
    local output_gcs_uri="${4:-}"

    if ! command -v gcloud >/dev/null 2>&1; then
        print_error "gcloud CLI required for Vertex AI. Install: https://cloud.google.com/sdk/docs/install"
        return 1
    fi

    local project
    project=$(gcloud config get-value project 2>/dev/null)
    local location="global"

    if [[ -z "$project" ]]; then
        print_error "No Google Cloud project set. Run: gcloud config set project YOUR_PROJECT"
        return 1
    fi

    local access_token
    access_token=$(gcloud auth print-access-token 2>/dev/null)

    print_info "Generating video with Veo (model=$model, aspect=$aspect_ratio) via Vertex AI..."

    local request_body
    request_body="{
        \"instances\": [{
            \"prompt\": $(printf '%s' "$prompt" | jq -Rs .)
        }],
        \"parameters\": {
            \"aspectRatio\": \"$aspect_ratio\",
            \"sampleCount\": 1
        }"

    if [[ -n "$output_gcs_uri" ]]; then
        request_body="${request_body},
        \"outputOptions\": {
            \"gcsUri\": \"$output_gcs_uri\"
        }"
    fi

    request_body="${request_body}}"

    local response
    response=$(curl -s -X POST \
        "https://${location}-aiplatform.googleapis.com/v1/projects/${project}/locations/${location}/publishers/google/models/${model}:predictLongRunning" \
        -H "Authorization: Bearer ${access_token}" \
        -H "${CONTENT_TYPE_JSON}" \
        -d "$request_body")

    local op_name
    op_name=$(printf '%s' "$response" | jq -r '.name // empty')

    if [[ -z "$op_name" ]]; then
        print_error "Failed to create Veo video job"
        printf '%s\n' "$response" | jq . 2>/dev/null || printf '%s\n' "$response"
        return 1
    fi

    print_success "Veo operation started: $op_name"
    printf '%s\n' "$response" | jq '{ name, done, metadata }'
    return 0
}

veo_status() {
    local op_name="$1"

    if [[ -n "${GOOGLE_API_KEY:-}" ]]; then
        local response
        response=$(curl -s \
            "https://generativelanguage.googleapis.com/v1beta/${op_name}?key=${GOOGLE_API_KEY}")
        printf '%s\n' "$response" | jq '{ name, done, metadata, response }'
    else
        if ! command -v gcloud >/dev/null 2>&1; then
            print_error "gcloud CLI required"
            return 1
        fi
        local access_token
        access_token=$(gcloud auth print-access-token 2>/dev/null)
        local location="global"

        local response
        response=$(curl -s \
            "https://${location}-aiplatform.googleapis.com/v1/${op_name}" \
            -H "Authorization: Bearer ${access_token}")
        printf '%s\n' "$response" | jq '{ name, done, metadata, response }'
    fi

    return 0
}

# =============================================================================
# Nanobanana Pro / Higgsfield Functions
# =============================================================================

nanobanana_generate_image() {
    local prompt="$1"
    local width_height="${2:-1696x960}"
    local quality="${3:-1080p}"

    load_credentials "higgsfield" || return 1

    print_info "Generating image with Nanobanana Pro (Soul model, $width_height, $quality)..."

    local response
    response=$(curl -s -X POST 'https://platform.higgsfield.ai/v1/text2image/soul' \
        -H "hf-api-key: ${HIGGSFIELD_API_KEY}" \
        -H "hf-secret: ${HIGGSFIELD_SECRET}" \
        -H "${CONTENT_TYPE_JSON}" \
        -d "{
            \"params\": {
                \"prompt\": $(printf '%s' "$prompt" | jq -Rs .),
                \"width_and_height\": \"$width_height\",
                \"enhance_prompt\": true,
                \"quality\": \"$quality\",
                \"batch_size\": 1
            }
        }")

    local job_id
    job_id=$(printf '%s' "$response" | jq -r '.id // empty')

    if [[ -z "$job_id" ]]; then
        print_error "Failed to create image generation job"
        printf '%s\n' "$response" | jq . 2>/dev/null || printf '%s\n' "$response"
        return 1
    fi

    print_success "Image job created: $job_id"
    printf '%s\n' "$response" | jq '{ id, type, created_at }'
    return 0
}

nanobanana_generate_video() {
    local prompt="$1"
    local image_url="${2:-}"
    local model="${3:-dop-turbo}"
    local seed="${4:-}"

    load_credentials "higgsfield" || return 1

    if [[ -z "$image_url" ]]; then
        print_error "Image URL required for image-to-video generation"
        return 1
    fi

    print_info "Generating video with Higgsfield ($model)..."

    local request_body
    if [[ "$model" == "dop-turbo" ]] || [[ "$model" == "dop-standard" ]]; then
        request_body="{
            \"params\": {
                \"model\": \"$model\",
                \"prompt\": $(printf '%s' "$prompt" | jq -Rs .),
                \"input_images\": [{
                    \"type\": \"image_url\",
                    \"image_url\": \"$image_url\"
                }],
                \"enhance_prompt\": true"
        if [[ -n "$seed" ]]; then
            request_body="${request_body},
                \"seed\": $seed"
        fi
        request_body="${request_body}
            }
        }"

        local response
        response=$(curl -s -X POST 'https://platform.higgsfield.ai/v1/image2video/dop' \
            -H "hf-api-key: ${HIGGSFIELD_API_KEY}" \
            -H "hf-secret: ${HIGGSFIELD_SECRET}" \
            -H "${CONTENT_TYPE_JSON}" \
            -d "$request_body")

        local job_id
        job_id=$(printf '%s' "$response" | jq -r '.id // .jobs[0].id // empty')

        if [[ -z "$job_id" ]]; then
            print_error "Failed to create video job"
            printf '%s\n' "$response" | jq . 2>/dev/null || printf '%s\n' "$response"
            return 1
        fi

        print_success "Video job created: $job_id"
        printf '%s\n' "$response" | jq '{ id, type, created_at }'
    else
        # Kling, Seedance, etc. use Authorization header
        local endpoint
        case "$model" in
            kling-v2.1-pro)
                endpoint="kling-video/v2.1/pro/image-to-video"
                ;;
            seedance-v1-pro)
                endpoint="bytedance/seedance/v1/pro/image-to-video"
                ;;
            *)
                print_error "Unknown Higgsfield model: $model. Use: dop-turbo, dop-standard, kling-v2.1-pro, seedance-v1-pro"
                return 1
                ;;
        esac

        local response
        response=$(curl -s -X POST "https://platform.higgsfield.ai/${endpoint}" \
            -H "Authorization: Key ${HIGGSFIELD_API_KEY}:${HIGGSFIELD_SECRET}" \
            -H "${CONTENT_TYPE_JSON}" \
            -d "{
                \"image_url\": \"$image_url\",
                \"prompt\": $(printf '%s' "$prompt" | jq -Rs .)
            }")

        local job_id
        job_id=$(printf '%s' "$response" | jq -r '.id // .request_id // empty')

        if [[ -z "$job_id" ]]; then
            print_error "Failed to create video job"
            printf '%s\n' "$response" | jq . 2>/dev/null || printf '%s\n' "$response"
            return 1
        fi

        print_success "Video job created: $job_id"
        printf '%s\n' "$response" | jq .
    fi

    return 0
}

nanobanana_status() {
    local job_id="$1"

    load_credentials "higgsfield" || return 1

    local response
    response=$(curl -s "https://platform.higgsfield.ai/api/generation-results?id=${job_id}" \
        -H "hf-api-key: ${HIGGSFIELD_API_KEY}" \
        -H "hf-secret: ${HIGGSFIELD_SECRET}")

    printf '%s\n' "$response" | jq '{ id, status, results, retention_expires_at }'
    return 0
}

nanobanana_create_character() {
    local photo_path="$1"

    load_credentials "higgsfield" || return 1

    if [[ ! -f "$photo_path" ]]; then
        print_error "Photo file not found: $photo_path"
        return 1
    fi

    print_info "Creating character from $photo_path..."

    local response
    response=$(curl -s -X POST 'https://platform.higgsfield.ai/api/characters' \
        -H "hf-api-key: ${HIGGSFIELD_API_KEY}" \
        -H "hf-secret: ${HIGGSFIELD_SECRET}" \
        -F "photo=@${photo_path}")

    local char_id
    char_id=$(printf '%s' "$response" | jq -r '.id // empty')

    if [[ -z "$char_id" ]]; then
        print_error "Failed to create character"
        printf '%s\n' "$response" | jq . 2>/dev/null || printf '%s\n' "$response"
        return 1
    fi

    print_success "Character created: $char_id"
    printf '%s\n' "$response" | jq '{ id, photo_url, created_at }'
    return 0
}

# =============================================================================
# Seed Bracketing
# =============================================================================

seed_bracket() {
    local prompt="$1"
    local image_url="${2:-}"
    local seed_start="${3:-1000}"
    local seed_end="${4:-1010}"
    local model="${5:-dop-turbo}"

    load_credentials "higgsfield" || return 1

    print_info "Seed bracketing: seeds $seed_start-$seed_end with model $model"

    local results_file
    results_file="seed_bracket_$(date +%Y%m%d_%H%M%S).csv"
    printf 'seed,job_id,status\n' > "$results_file"

    local seed
    for seed in $(seq "$seed_start" "$seed_end"); do
        print_info "Testing seed $seed..."

        local request_body
        request_body="{
            \"params\": {
                \"model\": \"$model\",
                \"prompt\": $(printf '%s' "$prompt" | jq -Rs .),
                \"seed\": $seed,
                \"enhance_prompt\": true"

        if [[ -n "$image_url" ]]; then
            request_body="${request_body},
                \"input_images\": [{
                    \"type\": \"image_url\",
                    \"image_url\": \"$image_url\"
                }]"
        fi

        request_body="${request_body}
            }
        }"

        local response
        response=$(curl -s -X POST 'https://platform.higgsfield.ai/v1/image2video/dop' \
            -H "hf-api-key: ${HIGGSFIELD_API_KEY}" \
            -H "hf-secret: ${HIGGSFIELD_SECRET}" \
            -H "${CONTENT_TYPE_JSON}" \
            -d "$request_body")

        local job_id
        job_id=$(printf '%s' "$response" | jq -r '.id // .jobs[0].id // "error"')

        printf '%s,%s,queued\n' "$seed" "$job_id" >> "$results_file"
        printf '  Seed %s -> Job %s\n' "$seed" "$job_id"
    done

    print_success "Bracket test complete. Results saved to $results_file"
    print_info "Review outputs and score manually using the 5-criteria rubric."
    return 0
}

# =============================================================================
# Models Reference
# =============================================================================

show_models() {
    cat <<'EOF'
AI Video Generation Models
==========================

SORA 2 (OpenAI)
  Models:     sora-2, sora-2-pro
  Duration:   4s, 8s, 12s
  Sizes:      720x1280, 1280x720, 1024x1792, 1792x1024
  Auth:       OPENAI_API_KEY
  Best for:   UGC, social media, authentic content (<$10k production value)
  API:        POST https://api.openai.com/v1/videos

VEO 3.1 (Google Vertex AI)
  Models:     veo-2-generate-001, veo-3-generate-001, veo-3.1-generate-001
  Aspect:     16:9, 9:16, 1:1
  Auth:       GOOGLE_API_KEY or gcloud ADC
  Best for:   Cinematic, character-consistent, commercial (>$100k production value)
  API:        Vertex AI predictLongRunning or Gemini API
  Note:       ALWAYS use ingredients-to-video, NEVER frame-to-video

NANOBANANA PRO / HIGGSFIELD
  Image:      Soul (text-to-image)
  Video:      DOP Turbo/Standard, Kling v2.1 Pro, Seedance v1 Pro
  Auth:       HIGGSFIELD_API_KEY + HIGGSFIELD_SECRET
  Best for:   Multi-model pipelines, batch generation, A/B testing
  API:        https://platform.higgsfield.ai

Seed Ranges (for seed bracketing):
  People/Characters:  1000-1999
  Action/Movement:    2000-2999
  Landscape/Env:      3000-3999
  Product/Object:     4000-4999
  YouTube-Optimized:  2000-3000
EOF
    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat <<'EOF'
video-gen-helper.sh - Unified AI Video Generation CLI

Usage: video-gen-helper.sh <command> [options]

Commands:
  generate <provider> <prompt> [options]   Generate video
  status <provider> <job_id>               Check job status
  download <provider> <job_id> [path]      Download completed video
  list <provider>                          List recent jobs
  image <prompt> [size] [quality]          Generate image (Nanobanana/Soul)
  character <photo_path>                   Create character (Higgsfield)
  bracket <prompt> [image_url] [start] [end] [model]  Seed bracketing
  models                                   Show available models
  help                                     Show this help

Providers:
  sora        OpenAI Sora 2 / Sora 2 Pro
  veo         Google Veo 3.1 (Vertex AI or Gemini API)
  nanobanana  Higgsfield (DOP, Kling, Seedance)

Generate Options:
  sora:       video-gen-helper.sh generate sora "prompt" [model] [seconds] [size]
              Models: sora-2, sora-2-pro
              Seconds: 4, 8, 12
              Sizes: 1280x720, 720x1280, 1792x1024, 1024x1792

  veo:        video-gen-helper.sh generate veo "prompt" [model] [aspect] [gcs_uri]
              Models: veo-2-generate-001, veo-3-generate-001, veo-3.1-generate-001
              Aspect: 16:9, 9:16, 1:1

  nanobanana: video-gen-helper.sh generate nanobanana "prompt" <image_url> [model] [seed]
              Models: dop-turbo, dop-standard, kling-v2.1-pro, seedance-v1-pro

Examples:
  video-gen-helper.sh generate sora "A cat reading a book in a library" sora-2-pro 8 1280x720
  video-gen-helper.sh generate veo "Cinematic shot of mountains at sunset" veo-3.1-generate-001 16:9
  video-gen-helper.sh generate nanobanana "Cat walking through garden" https://example.com/cat.jpg dop-turbo 4001
  video-gen-helper.sh image "Professional headshot, studio lighting" 1696x960 1080p
  video-gen-helper.sh bracket "Product demo animation" https://example.com/product.jpg 4000 4010 dop-turbo
  video-gen-helper.sh status sora vid_abc123
  video-gen-helper.sh download sora vid_abc123 ./output
  video-gen-helper.sh models

Credentials:
  Store via: aidevops secret set <key-name>
  Or export: OPENAI_API_KEY, GOOGLE_API_KEY, HIGGSFIELD_API_KEY, HIGGSFIELD_SECRET
EOF
    return 0
}

# =============================================================================
# Main Dispatch
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        generate)
            local provider="${1:-}"
            local prompt="${2:-}"
            shift 2 || true

            if [[ -z "$provider" ]] || [[ -z "$prompt" ]]; then
                print_error "Usage: video-gen-helper.sh generate <provider> <prompt> [options]"
                return 1
            fi

            case "$provider" in
                sora|openai)
                    sora_generate "$prompt" "${1:-sora-2}" "${2:-4}" "${3:-1280x720}"
                    ;;
                veo|google)
                    veo_generate "$prompt" "${1:-veo-3.1-generate-001}" "${2:-16:9}" "${3:-}"
                    ;;
                nanobanana|higgsfield)
                    nanobanana_generate_video "$prompt" "${1:-}" "${2:-dop-turbo}" "${3:-}"
                    ;;
                *)
                    print_error "Unknown provider: $provider. Use: sora, veo, nanobanana"
                    return 1
                    ;;
            esac
            ;;
        status)
            local provider="${1:-}"
            local job_id="${2:-}"

            if [[ -z "$provider" ]] || [[ -z "$job_id" ]]; then
                print_error "Usage: video-gen-helper.sh status <provider> <job_id>"
                return 1
            fi

            case "$provider" in
                sora|openai)     sora_status "$job_id" ;;
                veo|google)      veo_status "$job_id" ;;
                nanobanana|higgsfield) nanobanana_status "$job_id" ;;
                *)
                    print_error "Unknown provider: $provider"
                    return 1
                    ;;
            esac
            ;;
        download)
            local provider="${1:-}"
            local job_id="${2:-}"
            local output_path="${3:-.}"

            if [[ -z "$provider" ]] || [[ -z "$job_id" ]]; then
                print_error "Usage: video-gen-helper.sh download <provider> <job_id> [output_path]"
                return 1
            fi

            case "$provider" in
                sora|openai)     sora_download "$job_id" "$output_path" ;;
                veo|google)
                    print_info "Veo videos are saved to GCS. Check status for output URI."
                    veo_status "$job_id"
                    ;;
                nanobanana|higgsfield)
                    print_info "Higgsfield results available via status API (7-day retention)."
                    nanobanana_status "$job_id"
                    ;;
                *)
                    print_error "Unknown provider: $provider"
                    return 1
                    ;;
            esac
            ;;
        list)
            local provider="${1:-sora}"
            case "$provider" in
                sora|openai)     sora_list ;;
                veo|google)      print_info "Veo: Use Google Cloud Console to list operations." ;;
                nanobanana|higgsfield) print_info "Higgsfield: Use dashboard at https://cloud.higgsfield.ai" ;;
                *)
                    print_error "Unknown provider: $provider"
                    return 1
                    ;;
            esac
            ;;
        image)
            nanobanana_generate_image "${1:-}" "${2:-1696x960}" "${3:-1080p}"
            ;;
        character)
            nanobanana_create_character "${1:-}"
            ;;
        bracket|seed-bracket)
            seed_bracket "${1:-}" "${2:-}" "${3:-1000}" "${4:-1010}" "${5:-dop-turbo}"
            ;;
        models)
            show_models
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
