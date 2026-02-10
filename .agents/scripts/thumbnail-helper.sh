#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155
set -euo pipefail

# Thumbnail A/B Testing Pipeline
# Generate and test multiple thumbnail variants per video using AI image generation
# and YouTube's A/B testing capabilities.
#
# Usage: ./thumbnail-helper.sh [command] [options]
# Commands:
#   generate <topic> [--count N]        - Generate N thumbnail variants (default: 5)
#   score <image_path>                  - Score a thumbnail on quality criteria
#   batch-score <dir>                   - Score all thumbnails in a directory
#   upload <video_id> <image_path>      - Upload thumbnail to YouTube video
#   ab-test <video_id> <dir>            - Upload multiple thumbnails for A/B testing
#   analyze <video_id>                  - Analyze thumbnail performance metrics
#   templates                           - List available thumbnail style templates
#   help                                - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly THUMBNAIL_CACHE_DIR="$HOME/.cache/aidevops/thumbnails"
readonly THUMBNAIL_TEMPLATES_DIR="${SCRIPT_DIR}/../content/production/thumbnail-templates"
readonly THUMBNAIL_WIDTH=1280
readonly THUMBNAIL_HEIGHT=720
readonly THUMBNAIL_MAX_SIZE_MB=2
readonly MIN_SCORE_THRESHOLD=7.5

# Ensure cache directory exists
mkdir -p "$THUMBNAIL_CACHE_DIR"

# =============================================================================
# Credential Management
# =============================================================================

load_youtube_credentials() {
    # YouTube API credentials (for upload and analytics)
    if command -v gopass >/dev/null 2>&1 && gopass show "aidevops/youtube-api-key" >/dev/null 2>&1; then
        YOUTUBE_API_KEY="$(gopass show -o "aidevops/youtube-api-key" 2>/dev/null)" || true
    fi
    if [[ -z "${YOUTUBE_API_KEY:-}" ]] && [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
        # shellcheck source=/dev/null
        source "${HOME}/.config/aidevops/credentials.sh"
    fi
    
    return 0
}

load_image_gen_credentials() {
    # Nanobanana Pro / Higgsfield credentials (for image generation)
    if command -v gopass >/dev/null 2>&1 && gopass show "aidevops/higgsfield-api-key" >/dev/null 2>&1; then
        HIGGSFIELD_API_KEY="$(gopass show -o "aidevops/higgsfield-api-key" 2>/dev/null)" || true
        HIGGSFIELD_SECRET="$(gopass show -o "aidevops/higgsfield-secret" 2>/dev/null)" || true
    fi
    if [[ -z "${HIGGSFIELD_API_KEY:-}" ]] && [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
        # shellcheck source=/dev/null
        source "${HOME}/.config/aidevops/credentials.sh"
    fi
    
    return 0
}

# =============================================================================
# Thumbnail Style Templates
# =============================================================================

# List available thumbnail style templates
cmd_templates() {
    print_info "Available thumbnail style templates:"
    echo ""
    
    cat <<'EOF'
1. high-contrast-face
   - Face prominence: Close-up with clear emotion
   - High contrast background
   - Bold accent colors
   - Best for: Personal brand, talking head content

2. text-heavy
   - Large bold text overlay space
   - Simple background
   - High contrast colors
   - Best for: Tutorials, how-to content, listicles

3. before-after
   - Split-screen composition
   - Clear visual comparison
   - Contrasting colors for each side
   - Best for: Transformation content, comparisons

4. curiosity-gap
   - Mysterious or surprising visual
   - Minimal text
   - Emotion-driven (surprised, shocked, curious)
   - Best for: Clickbait-style content, reveals

5. product-showcase
   - Centered product with clean background
   - Professional lighting
   - Brand colors
   - Best for: Product reviews, unboxing

6. cinematic
   - Film-like composition
   - Dramatic lighting
   - Muted or stylized colors
   - Best for: Storytelling, documentary-style

7. minimalist
   - Clean, simple composition
   - Lots of negative space
   - Monochromatic or limited palette
   - Best for: Professional, corporate content

8. action-packed
   - Dynamic composition
   - Multiple elements
   - Vibrant colors
   - Best for: Gaming, sports, high-energy content
EOF
    
    echo ""
    print_info "Use these templates with: thumbnail-helper.sh generate <topic> --template <name>"
    
    return 0
}

# Get template JSON for a given style
get_template_json() {
    local template_name="$1"
    local subject="$2"
    local concept="$3"
    
    case "$template_name" in
        high-contrast-face)
            cat <<EOF
{
  "subject": "$subject",
  "concept": "$concept",
  "composition": {
    "framing": "close-up",
    "angle": "eye-level",
    "rule_of_thirds": true,
    "focal_point": "face and eyes",
    "depth_of_field": "shallow"
  },
  "lighting": {
    "type": "studio",
    "direction": "three-point",
    "quality": "soft diffused",
    "color_temperature": "neutral (5500K)",
    "mood": "high contrast"
  },
  "color": {
    "palette": ["#FF6B35", "#004E89", "#FFFFFF"],
    "dominant": "#004E89",
    "accent": "#FF6B35",
    "saturation": "vibrant",
    "harmony": "complementary"
  },
  "style": {
    "aesthetic": "editorial",
    "texture": "digital clean",
    "post_processing": "light grading",
    "reference": "Professional YouTube thumbnail"
  },
  "technical": {
    "camera": "Canon R5",
    "lens": "85mm f/1.2",
    "settings": "f/1.8, 1/200s, ISO 200",
    "resolution": "4K",
    "aspect_ratio": "16:9"
  },
  "negative": "blurry, low quality, distorted, watermark, text overlay, multiple faces, cluttered background"
}
EOF
            ;;
        text-heavy)
            cat <<EOF
{
  "subject": "$subject",
  "concept": "$concept",
  "composition": {
    "framing": "medium shot",
    "angle": "eye-level",
    "rule_of_thirds": false,
    "focal_point": "centered with 30% clear space for text",
    "depth_of_field": "deep"
  },
  "lighting": {
    "type": "studio",
    "direction": "front",
    "quality": "soft diffused",
    "color_temperature": "neutral (5500K)",
    "mood": "bright and airy"
  },
  "color": {
    "palette": ["#FFFFFF", "#2C3E50", "#E74C3C"],
    "dominant": "#FFFFFF",
    "accent": "#E74C3C",
    "saturation": "vibrant",
    "harmony": "complementary"
  },
  "style": {
    "aesthetic": "minimalist",
    "texture": "digital clean",
    "post_processing": "none",
    "reference": "Tutorial thumbnail with text space"
  },
  "technical": {
    "camera": "Sony A7IV",
    "lens": "50mm f/1.8",
    "settings": "f/2.8, 1/250s, ISO 400",
    "resolution": "4K",
    "aspect_ratio": "16:9"
  },
  "negative": "cluttered, busy background, text overlay, watermark, low contrast"
}
EOF
            ;;
        before-after)
            cat <<EOF
{
  "subject": "$subject",
  "concept": "$concept - split screen comparison",
  "composition": {
    "framing": "wide shot",
    "angle": "eye-level",
    "rule_of_thirds": false,
    "focal_point": "split down the middle",
    "depth_of_field": "deep"
  },
  "lighting": {
    "type": "studio",
    "direction": "front",
    "quality": "soft diffused",
    "color_temperature": "neutral (5500K)",
    "mood": "high contrast"
  },
  "color": {
    "palette": ["#E74C3C", "#27AE60", "#FFFFFF"],
    "dominant": "#FFFFFF",
    "accent": "#E74C3C",
    "saturation": "vibrant",
    "harmony": "complementary"
  },
  "style": {
    "aesthetic": "editorial",
    "texture": "digital clean",
    "post_processing": "light grading",
    "reference": "Before/after transformation thumbnail"
  },
  "technical": {
    "camera": "Canon R5",
    "lens": "24-70mm f/2.8",
    "settings": "f/4, 1/250s, ISO 400",
    "resolution": "4K",
    "aspect_ratio": "16:9"
  },
  "negative": "blurry, low quality, distorted, watermark, text overlay, cluttered"
}
EOF
            ;;
        curiosity-gap)
            cat <<EOF
{
  "subject": "$subject with surprised or shocked expression",
  "concept": "$concept",
  "composition": {
    "framing": "close-up",
    "angle": "slightly low angle",
    "rule_of_thirds": true,
    "focal_point": "face with exaggerated emotion",
    "depth_of_field": "shallow"
  },
  "lighting": {
    "type": "dramatic",
    "direction": "side",
    "quality": "hard direct",
    "color_temperature": "warm (3000K)",
    "mood": "dark and moody"
  },
  "color": {
    "palette": ["#FF006E", "#8338EC", "#FFBE0B"],
    "dominant": "#8338EC",
    "accent": "#FF006E",
    "saturation": "vibrant",
    "harmony": "triadic"
  },
  "style": {
    "aesthetic": "cinematic",
    "texture": "film grain",
    "post_processing": "heavy grading",
    "reference": "Clickbait YouTube thumbnail"
  },
  "technical": {
    "camera": "RED Komodo 6K",
    "lens": "35mm f/1.4",
    "settings": "f/2.0, 1/50s, ISO 800",
    "resolution": "4K",
    "aspect_ratio": "16:9"
  },
  "negative": "blurry, low quality, neutral expression, boring, text overlay, watermark"
}
EOF
            ;;
        product-showcase)
            cat <<EOF
{
  "subject": "$subject centered on clean background",
  "concept": "$concept",
  "composition": {
    "framing": "medium shot",
    "angle": "slightly high angle",
    "rule_of_thirds": false,
    "focal_point": "centered product",
    "depth_of_field": "medium"
  },
  "lighting": {
    "type": "studio",
    "direction": "three-point",
    "quality": "soft diffused",
    "color_temperature": "neutral (5500K)",
    "mood": "bright and airy"
  },
  "color": {
    "palette": ["#FFFFFF", "#2C3E50", "#3498DB"],
    "dominant": "#FFFFFF",
    "accent": "#3498DB",
    "saturation": "muted",
    "harmony": "monochromatic"
  },
  "style": {
    "aesthetic": "photorealistic",
    "texture": "smooth",
    "post_processing": "light grading",
    "reference": "Product photography"
  },
  "technical": {
    "camera": "Sony A7IV",
    "lens": "50mm f/1.8",
    "settings": "f/2.8, 1/250s, ISO 400",
    "resolution": "4K",
    "aspect_ratio": "16:9"
  },
  "negative": "blurry, low quality, cluttered background, text overlay, watermark, multiple products"
}
EOF
            ;;
        *)
            print_error "Unknown template: $template_name"
            return 1
            ;;
    esac
    
    return 0
}

# =============================================================================
# Thumbnail Generation
# =============================================================================

cmd_generate() {
    local topic="$1"
    local count="${2:-5}"
    local template="${3:-high-contrast-face}"
    
    validate_required_param "topic" "$topic" || return 1
    load_image_gen_credentials || return 1
    
    if [[ -z "${HIGGSFIELD_API_KEY:-}" ]] || [[ -z "${HIGGSFIELD_SECRET:-}" ]]; then
        print_error "Higgsfield credentials not configured. Run: aidevops secret set higgsfield-api-key"
        return 1
    fi
    
    print_info "Generating $count thumbnail variants for: $topic"
    print_info "Using template: $template"
    
    # Create output directory
    local output_dir="$THUMBNAIL_CACHE_DIR/$(date +%Y%m%d_%H%M%S)_${topic// /_}"
    mkdir -p "$output_dir"
    
    # Generate variants
    for i in $(seq 1 "$count"); do
        print_info "Generating variant $i/$count..."
        
        # Create variant-specific subject and concept
        local subject="Person discussing $topic"
        local concept="YouTube thumbnail for video about $topic - variant $i"
        
        # Get template JSON
        local template_json
        template_json=$(get_template_json "$template" "$subject" "$concept") || return 1
        
        # Save template JSON
        local json_file="$output_dir/variant_${i}_prompt.json"
        echo "$template_json" > "$json_file"
        
        # Call Nanobanana Pro API via Higgsfield
        # Note: This is a placeholder - actual API integration would go here
        # For now, we'll create a marker file
        print_info "  → Prompt saved to: $json_file"
        print_warning "  → API integration pending - use Higgsfield UI to generate from this JSON"
        
        # Placeholder for actual API call:
        # local response
        # response=$(curl -s -X POST "https://api.higgsfield.ai/v1/nanobanana/generate" \
        #     -H "X-API-Key: ${HIGGSFIELD_API_KEY}" \
        #     -H "X-API-Secret: ${HIGGSFIELD_SECRET}" \
        #     -H "${CONTENT_TYPE_JSON}" \
        #     -d "$template_json")
        # 
        # local job_id
        # job_id=$(echo "$response" | jq -r '.job_id // empty')
        # if [[ -z "$job_id" ]]; then
        #     print_error "Failed to start generation job for variant $i"
        #     continue
        # fi
        # 
        # echo "$job_id" > "$output_dir/variant_${i}_job_id.txt"
    done
    
    print_success "Generated $count thumbnail variant prompts in: $output_dir"
    print_info "Next steps:"
    print_info "  1. Use Higgsfield UI to generate images from the JSON prompts"
    print_info "  2. Download generated images to: $output_dir"
    print_info "  3. Run: thumbnail-helper.sh batch-score $output_dir"
    
    return 0
}

# =============================================================================
# Thumbnail Scoring
# =============================================================================

# Score a single thumbnail on quality criteria
cmd_score() {
    local image_path="$1"
    
    validate_required_param "image_path" "$image_path" || return 1
    validate_file_exists "$image_path" "Thumbnail image" || return 1
    
    print_info "Scoring thumbnail: $image_path"
    
    # Check image dimensions
    if command -v identify >/dev/null 2>&1; then
        local dimensions
        dimensions=$(identify -format "%wx%h" "$image_path" 2>/dev/null || echo "unknown")
        print_info "Dimensions: $dimensions (recommended: ${THUMBNAIL_WIDTH}x${THUMBNAIL_HEIGHT})"
    fi
    
    # Check file size
    local file_size_mb
    if [[ "$OSTYPE" == "darwin"* ]]; then
        file_size_mb=$(stat -f%z "$image_path" | awk '{print $1/1024/1024}')
    else
        file_size_mb=$(stat -c%s "$image_path" | awk '{print $1/1024/1024}')
    fi
    print_info "File size: ${file_size_mb}MB (max: ${THUMBNAIL_MAX_SIZE_MB}MB)"
    
    # Manual scoring rubric
    echo ""
    print_info "Score this thumbnail on the following criteria (1-10 scale):"
    echo ""
    echo "1. Face Prominence (25% weight)"
    echo "   - Is face visible, clear, and emotionally expressive?"
    read -r -p "   Score (1-10): " face_score
    
    echo ""
    echo "2. Contrast (20% weight)"
    echo "   - Does it stand out in a grid of thumbnails?"
    read -r -p "   Score (1-10): " contrast_score
    
    echo ""
    echo "3. Text Space (15% weight)"
    echo "   - Is there clear space for title overlay?"
    read -r -p "   Score (1-10): " text_space_score
    
    echo ""
    echo "4. Brand Alignment (15% weight)"
    echo "   - Does it match channel/brand visual identity?"
    read -r -p "   Score (1-10): " brand_score
    
    echo ""
    echo "5. Emotion (15% weight)"
    echo "   - Does it evoke curiosity, surprise, or excitement?"
    read -r -p "   Score (1-10): " emotion_score
    
    echo ""
    echo "6. Clarity (10% weight)"
    echo "   - Is it readable at small sizes (320px)?"
    read -r -p "   Score (1-10): " clarity_score
    
    # Calculate weighted score
    local weighted_score
    weighted_score=$(awk "BEGIN {
        score = ($face_score * 0.25) + \
                ($contrast_score * 0.20) + \
                ($text_space_score * 0.15) + \
                ($brand_score * 0.15) + \
                ($emotion_score * 0.15) + \
                ($clarity_score * 0.10);
        printf \"%.2f\", score
    }")
    
    echo ""
    print_info "Weighted Score: $weighted_score / 10"
    
    if (( $(echo "$weighted_score >= $MIN_SCORE_THRESHOLD" | bc -l) )); then
        print_success "✓ PASS - Score meets threshold (>= $MIN_SCORE_THRESHOLD)"
    else
        print_warning "✗ FAIL - Score below threshold (< $MIN_SCORE_THRESHOLD) - regenerate recommended"
    fi
    
    # Save score to file
    local score_file="${image_path%.png}_score.txt"
    score_file="${score_file%.jpg}_score.txt"
    cat > "$score_file" <<EOF
Thumbnail Score Report
======================
Image: $image_path
Date: $(date)

Criteria Scores:
- Face Prominence (25%): $face_score
- Contrast (20%): $contrast_score
- Text Space (15%): $text_space_score
- Brand Alignment (15%): $brand_score
- Emotion (15%): $emotion_score
- Clarity (10%): $clarity_score

Weighted Score: $weighted_score / 10
Threshold: $MIN_SCORE_THRESHOLD
Status: $(if (( $(echo "$weighted_score >= $MIN_SCORE_THRESHOLD" | bc -l) )); then echo "PASS"; else echo "FAIL"; fi)
EOF
    
    print_info "Score saved to: $score_file"
    
    return 0
}

# Score all thumbnails in a directory
cmd_batch_score() {
    local dir="$1"
    
    validate_required_param "directory" "$dir" || return 1
    
    if [[ ! -d "$dir" ]]; then
        print_error "Directory not found: $dir"
        return 1
    fi
    
    print_info "Batch scoring thumbnails in: $dir"
    
    local image_count=0
    local pass_count=0
    
    # Find all image files
    while IFS= read -r -d '' image_file; do
        ((image_count++))
        
        echo ""
        print_info "=== Image $image_count: $(basename "$image_file") ==="
        
        # Check if already scored
        local score_file="${image_file%.png}_score.txt"
        score_file="${score_file%.jpg}_score.txt"
        
        if [[ -f "$score_file" ]]; then
            print_info "Already scored - reading existing score..."
            local existing_score
            existing_score=$(grep "Weighted Score:" "$score_file" | awk '{print $3}')
            print_info "Weighted Score: $existing_score / 10"
            
            if (( $(echo "$existing_score >= $MIN_SCORE_THRESHOLD" | bc -l) )); then
                print_success "✓ PASS"
                ((pass_count++))
            else
                print_warning "✗ FAIL"
            fi
        else
            # Score interactively
            cmd_score "$image_file"
            
            # Check if passed
            local new_score
            new_score=$(grep "Weighted Score:" "$score_file" | awk '{print $3}')
            if (( $(echo "$new_score >= $MIN_SCORE_THRESHOLD" | bc -l) )); then
                ((pass_count++))
            fi
        fi
    done < <(find "$dir" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) -print0)
    
    echo ""
    print_success "Batch scoring complete!"
    print_info "Total images: $image_count"
    print_info "Passed (>= $MIN_SCORE_THRESHOLD): $pass_count"
    print_info "Failed: $((image_count - pass_count))"
    
    return 0
}

# =============================================================================
# YouTube Integration
# =============================================================================

cmd_upload() {
    local video_id="$1"
    local image_path="$2"
    
    validate_required_param "video_id" "$video_id" || return 1
    validate_required_param "image_path" "$image_path" || return 1
    validate_file_exists "$image_path" "Thumbnail image" || return 1
    load_youtube_credentials || return 1
    
    print_info "Uploading thumbnail to YouTube video: $video_id"
    
    # Use youtube-helper.sh if available, otherwise direct API call
    if [[ -x "${SCRIPT_DIR}/youtube-helper.sh" ]]; then
        print_info "Using youtube-helper.sh for upload..."
        "${SCRIPT_DIR}/youtube-helper.sh" upload-thumbnail "$video_id" "$image_path"
    else
        print_warning "youtube-helper.sh not found - implement direct API call"
        print_info "Manual upload: https://studio.youtube.com/video/$video_id/edit"
    fi
    
    return 0
}

cmd_ab_test() {
    local video_id="$1"
    local dir="$2"
    
    validate_required_param "video_id" "$video_id" || return 1
    validate_required_param "directory" "$dir" || return 1
    
    if [[ ! -d "$dir" ]]; then
        print_error "Directory not found: $dir"
        return 1
    fi
    
    print_info "Setting up A/B test for video: $video_id"
    print_info "Thumbnail directory: $dir"
    
    # Find all passing thumbnails
    local passing_thumbnails=()
    while IFS= read -r -d '' score_file; do
        local score
        score=$(grep "Weighted Score:" "$score_file" | awk '{print $3}')
        local status
        status=$(grep "Status:" "$score_file" | awk '{print $2}')
        
        if [[ "$status" == "PASS" ]]; then
            local image_file="${score_file%_score.txt}.png"
            if [[ ! -f "$image_file" ]]; then
                image_file="${score_file%_score.txt}.jpg"
            fi
            
            if [[ -f "$image_file" ]]; then
                passing_thumbnails+=("$image_file")
            fi
        fi
    done < <(find "$dir" -type f -name "*_score.txt" -print0)
    
    if [[ ${#passing_thumbnails[@]} -eq 0 ]]; then
        print_error "No passing thumbnails found in directory"
        print_info "Run: thumbnail-helper.sh batch-score $dir"
        return 1
    fi
    
    print_success "Found ${#passing_thumbnails[@]} passing thumbnails"
    
    # YouTube's A/B testing (via YouTube Studio)
    print_info ""
    print_info "YouTube A/B Testing Setup:"
    print_info "1. Upload all passing thumbnails to YouTube Studio"
    print_info "2. Navigate to: https://studio.youtube.com/video/$video_id/edit"
    print_info "3. Use 'Test & Compare' feature to set up A/B test"
    print_info ""
    print_info "Passing thumbnails:"
    for thumb in "${passing_thumbnails[@]}"; do
        print_info "  - $(basename "$thumb")"
    done
    
    # Optionally upload all thumbnails
    echo ""
    read -r -p "Upload all passing thumbnails now? (y/n): " upload_choice
    if [[ "$upload_choice" == "y" ]]; then
        for thumb in "${passing_thumbnails[@]}"; do
            print_info "Uploading: $(basename "$thumb")"
            cmd_upload "$video_id" "$thumb"
            sleep 2  # Rate limiting
        done
    fi
    
    return 0
}

cmd_analyze() {
    local video_id="$1"
    
    validate_required_param "video_id" "$video_id" || return 1
    load_youtube_credentials || return 1
    
    print_info "Analyzing thumbnail performance for video: $video_id"
    
    # Use youtube-helper.sh if available
    if [[ -x "${SCRIPT_DIR}/youtube-helper.sh" ]]; then
        print_info "Fetching video analytics..."
        "${SCRIPT_DIR}/youtube-helper.sh" video "$video_id"
    else
        print_warning "youtube-helper.sh not found"
        print_info "View analytics: https://studio.youtube.com/video/$video_id/analytics"
    fi
    
    print_info ""
    print_info "Key metrics to track:"
    print_info "  - CTR (Click-Through Rate): Target >= 5%"
    print_info "  - Impressions: Minimum 1000 for statistical significance"
    print_info "  - Average View Duration: Higher = better thumbnail relevance"
    
    return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
    cat <<'EOF'
Thumbnail A/B Testing Pipeline
===============================

Generate and test multiple thumbnail variants per video using AI image generation
and YouTube's A/B testing capabilities.

Usage: thumbnail-helper.sh [command] [options]

Commands:
  generate <topic> [--count N] [--template NAME]
      Generate N thumbnail variants (default: 5)
      Templates: high-contrast-face, text-heavy, before-after, curiosity-gap,
                 product-showcase, cinematic, minimalist, action-packed

  score <image_path>
      Score a thumbnail on quality criteria (1-10 scale)
      Criteria: face prominence, contrast, text space, brand alignment,
                emotion, clarity

  batch-score <dir>
      Score all thumbnails in a directory

  upload <video_id> <image_path>
      Upload thumbnail to YouTube video

  ab-test <video_id> <dir>
      Upload multiple thumbnails for A/B testing

  analyze <video_id>
      Analyze thumbnail performance metrics

  templates
      List available thumbnail style templates

  help
      Show this help message

Examples:
  # Generate 5 thumbnail variants
  thumbnail-helper.sh generate "AI Video Generation Tips" --count 5

  # Generate with specific template
  thumbnail-helper.sh generate "Product Review" --template product-showcase

  # Score a single thumbnail
  thumbnail-helper.sh score ./thumbnails/variant_1.png

  # Score all thumbnails in directory
  thumbnail-helper.sh batch-score ./thumbnails/

  # Upload thumbnail to video
  thumbnail-helper.sh upload dQw4w9WgXcQ ./thumbnails/variant_1.png

  # Set up A/B test
  thumbnail-helper.sh ab-test dQw4w9WgXcQ ./thumbnails/

  # Analyze performance
  thumbnail-helper.sh analyze dQw4w9WgXcQ

Workflow:
  1. Generate variants: thumbnail-helper.sh generate "topic" --count 10
  2. Download generated images from Higgsfield UI
  3. Score variants: thumbnail-helper.sh batch-score ./output_dir/
  4. Upload passing thumbnails: thumbnail-helper.sh ab-test VIDEO_ID ./output_dir/
  5. Wait for 1000+ impressions (7-14 days)
  6. Analyze results: thumbnail-helper.sh analyze VIDEO_ID
  7. Use winning template for next 10 videos

Quality Thresholds:
  - Minimum score: 7.5/10 (weighted)
  - Minimum impressions: 1000 (for statistical significance)
  - Target CTR: >= 5%

References:
  - content/production/image.md (thumbnail factory pattern)
  - content/optimization.md (A/B testing discipline)
  - youtube-helper.sh (YouTube API integration)

EOF
    
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        generate)
            local topic="${1:-}"
            local count=5
            local template="high-contrast-face"
            
            shift || true
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --count)
                        count="$2"
                        shift 2
                        ;;
                    --template)
                        template="$2"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            cmd_generate "$topic" "$count" "$template"
            ;;
        score)
            cmd_score "$1"
            ;;
        batch-score)
            cmd_batch_score "$1"
            ;;
        upload)
            cmd_upload "$1" "$2"
            ;;
        ab-test)
            cmd_ab_test "$1" "$2"
            ;;
        analyze)
            cmd_analyze "$1"
            ;;
        templates)
            cmd_templates
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            cmd_help
            return 1
            ;;
    esac
    
    return $?
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
