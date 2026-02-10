#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC2001
set -euo pipefail

# Thumbnail Factory Helper Script
# Generate, score, and A/B test multiple thumbnail variants per video.
# Integrates with YouTube Data API, image generation APIs, and vision models.
#
# Usage: ./thumbnail-factory-helper.sh [command] [args] [options]
# Commands:
#   generate <video_id> [count]    - Generate thumbnail variants for a video
#   score <image_path>             - Score a thumbnail against quality rubric
#   batch-score <directory>        - Score all thumbnails in a directory
#   compare <dir1> <dir2>          - Compare two sets of thumbnails
#   ab-status <video_id>           - Check A/B test status from YouTube Studio
#   brief <video_id>               - Generate thumbnail design brief from video metadata
#   competitors <video_id> [count] - Analyse competitor thumbnails for the same topic
#   history [video_id]             - Show thumbnail test history
#   report [--recent]              - Generate performance report across all tests
#   help                           - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly THUMB_WORKSPACE="$HOME/.aidevops/.agent-workspace/work/youtube/thumbnails"
readonly THUMB_DB_DIR="$HOME/.aidevops/.agent-workspace"
readonly THUMB_DB="$THUMB_DB_DIR/thumbnail-tests.db"
readonly THUMB_STYLE_LIB="$THUMB_WORKSPACE/style-library"
readonly THUMB_WIDTH=1280
readonly THUMB_HEIGHT=720
readonly THUMB_MIN_SCORE="7.5"
readonly THUMB_DEFAULT_VARIANTS=5
readonly HELP_SHOW_MESSAGE="Show this help message"

# ============================================================================
# Database
# ============================================================================

init_db() {
    mkdir -p "$THUMB_DB_DIR" 2>/dev/null || true
    mkdir -p "$THUMB_WORKSPACE" 2>/dev/null || true
    mkdir -p "$THUMB_STYLE_LIB" 2>/dev/null || true

    sqlite3 "$THUMB_DB" "
        CREATE TABLE IF NOT EXISTS thumbnail_tests (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            video_id        TEXT NOT NULL,
            video_title     TEXT DEFAULT '',
            variant_path    TEXT NOT NULL,
            variant_label   TEXT DEFAULT '',
            style_template  TEXT DEFAULT '',
            score_total     REAL DEFAULT 0,
            score_face      REAL DEFAULT 0,
            score_contrast  REAL DEFAULT 0,
            score_text      REAL DEFAULT 0,
            score_brand     REAL DEFAULT 0,
            score_emotion   REAL DEFAULT 0,
            score_clarity   REAL DEFAULT 0,
            is_winner       INTEGER DEFAULT 0,
            ctr             REAL DEFAULT 0,
            impressions     INTEGER DEFAULT 0,
            status          TEXT DEFAULT 'generated',
            notes           TEXT DEFAULT '',
            created_at      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            updated_at      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS thumbnail_briefs (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            video_id        TEXT NOT NULL,
            video_title     TEXT DEFAULT '',
            concept         TEXT DEFAULT '',
            emotional_trigger TEXT DEFAULT '',
            layout          TEXT DEFAULT '',
            face_direction  TEXT DEFAULT '',
            background      TEXT DEFAULT '',
            key_object      TEXT DEFAULT '',
            text_overlay    TEXT DEFAULT '',
            color_palette   TEXT DEFAULT '',
            reference_urls  TEXT DEFAULT '',
            created_at      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS style_templates (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT UNIQUE NOT NULL,
            description     TEXT DEFAULT '',
            json_template   TEXT NOT NULL,
            avg_score       REAL DEFAULT 0,
            avg_ctr         REAL DEFAULT 0,
            usage_count     INTEGER DEFAULT 0,
            created_at      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            updated_at      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_tests_video ON thumbnail_tests(video_id);
        CREATE INDEX IF NOT EXISTS idx_tests_status ON thumbnail_tests(status);
        CREATE INDEX IF NOT EXISTS idx_tests_winner ON thumbnail_tests(is_winner);
    " 2>/dev/null || true
    return 0
}

# ============================================================================
# Thumbnail Brief Generation
# ============================================================================

cmd_brief() {
    local video_id="${1:?Video ID required}"

    init_db

    # Fetch video metadata via youtube-helper.sh
    local yt_helper="${SCRIPT_DIR}/youtube-helper.sh"
    if [[ ! -x "$yt_helper" ]]; then
        print_error "youtube-helper.sh not found at: $yt_helper"
        return 1
    fi

    print_info "Fetching video metadata for: $video_id"
    local video_json
    video_json=$("$yt_helper" video "$video_id" json 2>/dev/null) || {
        print_error "Failed to fetch video metadata"
        return 1
    }

    # Extract metadata
    local video_data
    video_data=$(node -e "
const data = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
const v = data.items?.[0];
if (!v) { console.error('Video not found'); process.exit(1); }
const s = v.snippet;
const st = v.statistics;
console.log(JSON.stringify({
    title: s.title,
    description: (s.description || '').substring(0, 500),
    channel: s.channelTitle,
    tags: (s.tags || []).slice(0, 10),
    category: s.categoryId,
    views: Number(st.viewCount || 0),
    likes: Number(st.likeCount || 0),
    thumbnails: s.thumbnails
}));
" <<< "$video_json" 2>/dev/null) || {
        print_error "Failed to parse video metadata"
        return 1
    }

    # Extract current thumbnail URL
    local thumb_url
    thumb_url=$(node -e "
const d = JSON.parse('$(echo "$video_data" | sed "s/'/\\\\'/g")');
console.log(d.thumbnails?.maxres?.url || d.thumbnails?.high?.url || d.thumbnails?.default?.url || '');
" 2>/dev/null)

    local title
    title=$(node -e "console.log(JSON.parse('$(echo "$video_data" | sed "s/'/\\\\'/g")').title)" 2>/dev/null)

    # Generate brief
    local brief_dir="$THUMB_WORKSPACE/$video_id"
    mkdir -p "$brief_dir" 2>/dev/null || true

    local brief_file="$brief_dir/brief.md"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    cat > "$brief_file" << BRIEF_EOF
## Thumbnail Brief: $title

**Video ID**: $video_id
**Generated**: $timestamp
**Current thumbnail**: $thumb_url

### Concept Options

Generate 5+ variants exploring these concepts:

1. **Face + Emotion**: Close-up face with strong emotion (surprise, excitement, curiosity)
2. **Before/After Split**: Left side = problem, right side = solution
3. **Bold Text + Visual**: Large text overlay with supporting visual element
4. **Product/Object Focus**: Key object from video, dramatic lighting
5. **Contrarian/Unexpected**: Visual that contradicts expectations

### Design Constraints

- **Dimensions**: ${THUMB_WIDTH}x${THUMB_HEIGHT} (16:9)
- **Text overlay space**: Reserve 30% of frame for title text (add in post)
- **Mobile readability**: Must be legible at 320px width
- **High contrast**: Stand out in YouTube's white/dark mode feed
- **No text in generation**: Add text overlays separately for A/B flexibility

### Scoring Criteria

| Criterion | Weight | Target |
|-----------|--------|--------|
| Face Prominence | 25% | Face >30% of frame, clear emotion |
| Contrast | 20% | Stands out in thumbnail grid |
| Text Space | 15% | Clear area for title overlay |
| Brand Alignment | 15% | Matches channel visual identity |
| Emotion | 15% | Evokes curiosity/surprise/excitement |
| Clarity | 10% | Readable at 120x90px |

**Minimum score**: ${THUMB_MIN_SCORE}/10 to proceed to A/B testing

### Video Context

$(node -e "
const d = JSON.parse('$(echo "$video_data" | sed "s/'/\\\\'/g")');
console.log('**Title**: ' + d.title);
console.log('**Channel**: ' + d.channel);
console.log('**Tags**: ' + d.tags.join(', '));
console.log('**Views**: ' + d.views.toLocaleString());
console.log('');
console.log('**Description excerpt**:');
console.log(d.description.substring(0, 300));
" 2>/dev/null)

### Style Library Templates

Use templates from: \`$THUMB_STYLE_LIB/\`

Recommended starting templates:
- Magazine Cover (high impact, centered subject)
- Editorial Portrait (face-focused, professional)
- Product Shot (object-focused, clean background)

See \`content/production/image.md\` for full JSON schema.
BRIEF_EOF

    # Store brief in database
    sqlite3 "$THUMB_DB" "
        INSERT INTO thumbnail_briefs (video_id, video_title, concept, emotional_trigger)
        VALUES ('$video_id', '$(echo "$title" | sed "s/'/''/g")', 'multi-concept', 'curiosity/surprise');
    " 2>/dev/null || true

    print_success "Brief generated: $brief_file"
    cat "$brief_file"
    return 0
}

# ============================================================================
# Thumbnail Generation (via image APIs)
# ============================================================================

cmd_generate() {
    local video_id="${1:?Video ID required}"
    local count="${2:-$THUMB_DEFAULT_VARIANTS}"
    local style="${3:-magazine-cover}"

    init_db

    local output_dir="$THUMB_WORKSPACE/$video_id/variants"
    mkdir -p "$output_dir" 2>/dev/null || true

    # Check for DALL-E API key
    local api_key=""
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        api_key="$OPENAI_API_KEY"
    elif [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
        api_key=$(grep -oP 'OPENAI_API_KEY="\K[^"]+' "$HOME/.config/aidevops/credentials.sh" 2>/dev/null | head -1 || true)
    fi

    if [[ -z "$api_key" ]]; then
        print_warning "No OPENAI_API_KEY found. Generating prompt files only (no images)."
        print_info "Set key: aidevops secret set OPENAI_API_KEY"
        _generate_prompt_files "$video_id" "$count" "$style" "$output_dir"
        return 0
    fi

    # Generate brief first if not exists
    local brief_file="$THUMB_WORKSPACE/$video_id/brief.md"
    if [[ ! -f "$brief_file" ]]; then
        print_info "Generating brief first..."
        cmd_brief "$video_id" > /dev/null 2>&1 || true
    fi

    print_info "Generating $count thumbnail variants for video: $video_id"

    local concepts=(
        "Close-up face with surprised expression, dramatic side lighting, shallow depth of field"
        "Split composition showing before and after, high contrast, bold colors"
        "Centered subject with bold graphic elements, vibrant accent colors, clean background"
        "Product or key object in dramatic lighting, dark moody background, rim light"
        "Wide shot with subject in environment, natural lighting, cinematic composition"
        "Extreme close-up of hands or detail, macro style, shallow depth of field"
        "Subject pointing at or looking at key element, rule of thirds, bright background"
        "Minimalist composition with single bold element, negative space, high contrast"
        "Action shot with motion blur, dynamic angle, energetic composition"
        "Overhead flat lay arrangement, organized grid, clean aesthetic"
    )

    local generated=0
    local i=0
    while [[ $generated -lt $count ]] && [[ $i -lt ${#concepts[@]} ]]; do
        local concept="${concepts[$i]}"
        local variant_label="variant-$((i + 1))"
        local output_file="$output_dir/${variant_label}.png"

        print_info "Generating variant $((generated + 1))/$count: $variant_label"

        local prompt="YouTube thumbnail, ${THUMB_WIDTH}x${THUMB_HEIGHT}, 16:9 aspect ratio, ${concept}, high contrast, readable at small size, no text, no watermark, professional quality, 4K"

        local response
        response=$(curl -s "https://api.openai.com/v1/images/generations" \
            -H "Authorization: Bearer $api_key" \
            -H "$CONTENT_TYPE_JSON" \
            -d "{
                \"model\": \"dall-e-3\",
                \"prompt\": $(node -e "console.log(JSON.stringify('$prompt'))" 2>/dev/null),
                \"size\": \"1792x1024\",
                \"quality\": \"hd\",
                \"style\": \"natural\"
            }" 2>/dev/null) || {
            print_warning "Failed to generate variant $variant_label"
            i=$((i + 1))
            continue
        }

        # Extract URL and download
        local image_url
        image_url=$(node -e "
const r = JSON.parse('$(echo "$response" | sed "s/'/\\\\'/g")');
if (r.data?.[0]?.url) console.log(r.data[0].url);
else { console.error(JSON.stringify(r.error || r)); process.exit(1); }
" 2>/dev/null) || {
            print_warning "Failed to parse response for variant $variant_label"
            i=$((i + 1))
            continue
        }

        curl -s -o "$output_file" "$image_url" 2>/dev/null || {
            print_warning "Failed to download variant $variant_label"
            i=$((i + 1))
            continue
        }

        # Record in database
        sqlite3 "$THUMB_DB" "
            INSERT INTO thumbnail_tests (video_id, variant_path, variant_label, style_template, status)
            VALUES ('$video_id', '$output_file', '$variant_label', '$style', 'generated');
        " 2>/dev/null || true

        print_success "Generated: $output_file"
        generated=$((generated + 1))
        i=$((i + 1))
    done

    print_success "Generated $generated/$count variants in: $output_dir"
    print_info "Next: thumbnail-factory-helper.sh batch-score $output_dir"
    return 0
}

# Generate prompt files when no API key is available
_generate_prompt_files() {
    local video_id="$1"
    local count="$2"
    local style="$3"
    local output_dir="$4"

    local concepts=(
        "Close-up face with surprised expression, dramatic side lighting"
        "Split composition showing before and after, high contrast"
        "Centered subject with bold graphic elements, vibrant colors"
        "Product in dramatic lighting, dark moody background"
        "Wide shot with subject in environment, cinematic"
        "Extreme close-up of detail, macro style"
        "Subject pointing at key element, rule of thirds"
        "Minimalist with single bold element, negative space"
        "Action shot with motion blur, dynamic angle"
        "Overhead flat lay, organized grid, clean aesthetic"
    )

    local generated=0
    local i=0
    while [[ $generated -lt $count ]] && [[ $i -lt ${#concepts[@]} ]]; do
        local variant_label="variant-$((i + 1))"
        local prompt_file="$output_dir/${variant_label}-prompt.json"

        cat > "$prompt_file" << PROMPT_EOF
{
  "model": "dall-e-3",
  "prompt": "YouTube thumbnail, ${THUMB_WIDTH}x${THUMB_HEIGHT}, 16:9 aspect ratio, ${concepts[$i]}, high contrast, readable at small size, no text, no watermark, professional quality, 4K",
  "size": "1792x1024",
  "quality": "hd",
  "style": "natural",
  "metadata": {
    "video_id": "$video_id",
    "variant": "$variant_label",
    "concept": "${concepts[$i]}",
    "style_template": "$style"
  }
}
PROMPT_EOF

        # Record in database
        sqlite3 "$THUMB_DB" "
            INSERT INTO thumbnail_tests (video_id, variant_path, variant_label, style_template, status)
            VALUES ('$video_id', '$prompt_file', '$variant_label', '$style', 'prompt-only');
        " 2>/dev/null || true

        generated=$((generated + 1))
        i=$((i + 1))
    done

    print_success "Generated $generated prompt files in: $output_dir"
    print_info "Use these prompts with your preferred image generation tool."
    print_info "Or set OPENAI_API_KEY to generate images directly."
    return 0
}

# ============================================================================
# Thumbnail Scoring
# ============================================================================

cmd_score() {
    local image_path="${1:?Image path required}"

    if [[ ! -f "$image_path" ]]; then
        print_error "Image not found: $image_path"
        return 1
    fi

    init_db

    print_info "Scoring thumbnail: $image_path"

    # Check image dimensions
    local dimensions=""
    if command -v identify &> /dev/null; then
        dimensions=$(identify -format "%wx%h" "$image_path" 2>/dev/null || echo "unknown")
    elif command -v sips &> /dev/null; then
        local w h
        w=$(sips -g pixelWidth "$image_path" 2>/dev/null | tail -1 | awk '{print $2}')
        h=$(sips -g pixelHeight "$image_path" 2>/dev/null | tail -1 | awk '{print $2}')
        dimensions="${w}x${h}"
    fi

    # Automated scoring based on image properties
    local score_face=0
    local score_contrast=0
    local score_text=0
    local score_brand=0
    local score_emotion=0
    local score_clarity=0

    # Basic automated checks
    if [[ "$dimensions" != "unknown" ]] && [[ -n "$dimensions" ]]; then
        local img_w="${dimensions%%x*}"
        local img_h="${dimensions##*x}"

        # Aspect ratio check (should be ~16:9)
        if [[ -n "$img_w" ]] && [[ -n "$img_h" ]] && [[ "$img_h" -gt 0 ]]; then
            local ratio
            ratio=$(node -e "console.log(($img_w / $img_h).toFixed(2))" 2>/dev/null || echo "0")
            if [[ $(node -e "console.log($ratio >= 1.6 && $ratio <= 1.85 ? 1 : 0)" 2>/dev/null) == "1" ]]; then
                score_clarity=7
            else
                score_clarity=5
                print_warning "Aspect ratio ($ratio) is not 16:9 — may crop poorly"
            fi
        fi

        # Resolution check
        if [[ -n "$img_w" ]] && [[ "$img_w" -ge 1280 ]]; then
            score_clarity=$((score_clarity + 1))
        fi
    else
        score_clarity=5
    fi

    # For full scoring, we need vision AI — output a scoring prompt
    local score_prompt_file="${image_path%.png}-score-prompt.txt"
    cat > "$score_prompt_file" << 'SCORE_EOF'
Score this YouTube thumbnail on these criteria (1-10 scale):

1. **Face Prominence** (25% weight): Is a human face visible, clear, and emotionally expressive? Face should be >30% of frame.
2. **Contrast** (20% weight): Does it stand out in a grid of thumbnails? High contrast between elements?
3. **Text Space** (15% weight): Is there clear space for title overlay text? At least 30% of frame clear?
4. **Brand Alignment** (15% weight): Does it look professional and consistent with a channel brand?
5. **Emotion** (15% weight): Does it evoke curiosity, surprise, or excitement?
6. **Clarity** (10% weight): Is it readable and clear at small sizes (120x90px)?

Output format (one line per criterion):
FACE: [score]
CONTRAST: [score]
TEXT_SPACE: [score]
BRAND: [score]
EMOTION: [score]
CLARITY: [score]
TOTAL: [weighted average]
VERDICT: [PASS if >= 7.5, FAIL if < 7.5]
NOTES: [brief improvement suggestions]
SCORE_EOF

    # Output scoring template for manual or AI-assisted scoring
    echo ""
    echo "Thumbnail: $image_path"
    echo "Dimensions: $dimensions"
    echo ""
    echo "Automated checks:"
    echo "  Clarity (resolution/aspect): $score_clarity/10"
    echo ""
    echo "For full scoring, use vision AI with the prompt at:"
    echo "  $score_prompt_file"
    echo ""
    echo "Or enter scores manually:"
    echo "  thumbnail-factory-helper.sh record-score $image_path <face> <contrast> <text> <brand> <emotion> <clarity>"
    echo ""

    return 0
}

cmd_record_score() {
    local image_path="${1:?Image path required}"
    local score_face="${2:?Face score required (1-10)}"
    local score_contrast="${3:?Contrast score required (1-10)}"
    local score_text="${4:?Text space score required (1-10)}"
    local score_brand="${5:?Brand score required (1-10)}"
    local score_emotion="${6:?Emotion score required (1-10)}"
    local score_clarity="${7:?Clarity score required (1-10)}"

    init_db

    # Calculate weighted total
    local total
    total=$(node -e "
const f=$score_face, co=$score_contrast, t=$score_text, b=$score_brand, e=$score_emotion, cl=$score_clarity;
const total = (f * 0.25) + (co * 0.20) + (t * 0.15) + (b * 0.15) + (e * 0.15) + (cl * 0.10);
console.log(total.toFixed(2));
" 2>/dev/null)

    local verdict="FAIL"
    if [[ $(node -e "console.log($total >= $THUMB_MIN_SCORE ? 1 : 0)" 2>/dev/null) == "1" ]]; then
        verdict="PASS"
    fi

    # Update database
    sqlite3 "$THUMB_DB" "
        UPDATE thumbnail_tests SET
            score_face = $score_face,
            score_contrast = $score_contrast,
            score_text = $score_text,
            score_brand = $score_brand,
            score_emotion = $score_emotion,
            score_clarity = $score_clarity,
            score_total = $total,
            status = 'scored',
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE variant_path = '$(echo "$image_path" | sed "s/'/''/g")';
    " 2>/dev/null || true

    echo ""
    echo "Scores recorded for: $(basename "$image_path")"
    echo ""
    echo "  Face Prominence (25%): $score_face/10"
    echo "  Contrast (20%):        $score_contrast/10"
    echo "  Text Space (15%):      $score_text/10"
    echo "  Brand Alignment (15%): $score_brand/10"
    echo "  Emotion (15%):         $score_emotion/10"
    echo "  Clarity (10%):         $score_clarity/10"
    echo ""
    echo "  TOTAL: $total/10"
    echo "  VERDICT: $verdict (threshold: $THUMB_MIN_SCORE)"
    echo ""

    if [[ "$verdict" == "PASS" ]]; then
        print_success "Thumbnail passes quality threshold — ready for A/B testing"
    else
        print_warning "Thumbnail below threshold — regenerate or improve"
    fi

    return 0
}

cmd_batch_score() {
    local directory="${1:?Directory path required}"

    if [[ ! -d "$directory" ]]; then
        print_error "Directory not found: $directory"
        return 1
    fi

    init_db

    local count=0
    local scored=0

    print_info "Scoring thumbnails in: $directory"
    echo ""

    while IFS= read -r -d '' img; do
        count=$((count + 1))
        echo "--- Thumbnail $count: $(basename "$img") ---"
        cmd_score "$img"
        scored=$((scored + 1))
        echo ""
    done < <(find "$directory" -maxdepth 1 \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) -print0 2>/dev/null)

    if [[ $count -eq 0 ]]; then
        print_warning "No image files found in: $directory"
        print_info "Supported formats: .png, .jpg, .jpeg, .webp"
        return 0
    fi

    print_info "Scored $scored thumbnails. Use record-score to enter scores."
    return 0
}

# ============================================================================
# Competitor Thumbnail Analysis
# ============================================================================

cmd_competitors() {
    local video_id="${1:?Video ID required}"
    local count="${2:-5}"

    init_db

    local yt_helper="${SCRIPT_DIR}/youtube-helper.sh"
    if [[ ! -x "$yt_helper" ]]; then
        print_error "youtube-helper.sh not found"
        return 1
    fi

    # Get video details to find the topic
    print_info "Fetching video metadata..."
    local video_json
    video_json=$("$yt_helper" video "$video_id" json 2>/dev/null) || {
        print_error "Failed to fetch video metadata"
        return 1
    }

    local title
    title=$(node -e "
const d = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
console.log(d.items?.[0]?.snippet?.title || 'unknown');
" <<< "$video_json" 2>/dev/null)

    print_info "Searching for competitor thumbnails on: $title"

    # Search for similar videos
    local search_json
    search_json=$("$yt_helper" search "$title" video "$count" json 2>/dev/null) || {
        print_error "Failed to search for competitors"
        return 1
    }

    # Extract competitor video IDs and thumbnail URLs
    local comp_dir="$THUMB_WORKSPACE/$video_id/competitors"
    mkdir -p "$comp_dir" 2>/dev/null || true

    node -e "
const data = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
const items = data.items || [];
console.log('Competitor Thumbnails for: \"$title\"');
console.log('');
console.log('# | Video ID    | Channel              | Thumbnail URL');
console.log('--|-------------|----------------------|-------------');
items.forEach((item, i) => {
    const vid = item.id?.videoId || 'N/A';
    const ch = (item.snippet?.channelTitle || 'N/A').substring(0, 20).padEnd(20);
    const thumb = item.snippet?.thumbnails?.high?.url || item.snippet?.thumbnails?.default?.url || 'N/A';
    console.log((i+1) + ' | ' + vid.padEnd(11) + ' | ' + ch + ' | ' + thumb);
});
" <<< "$search_json" 2>/dev/null

    # Download competitor thumbnails
    local downloaded=0
    local comp_urls
    comp_urls=$(node -e "
const data = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
(data.items || []).forEach((item, i) => {
    const vid = item.id?.videoId || '';
    const url = item.snippet?.thumbnails?.high?.url || item.snippet?.thumbnails?.default?.url || '';
    if (vid && url) console.log(vid + '|' + url);
});
" <<< "$search_json" 2>/dev/null)

    while IFS='|' read -r comp_vid comp_url; do
        [[ -z "$comp_vid" ]] && continue
        local comp_file="$comp_dir/${comp_vid}.jpg"
        if curl -s -o "$comp_file" "$comp_url" 2>/dev/null; then
            downloaded=$((downloaded + 1))
        fi
    done <<< "$comp_urls"

    echo ""
    print_success "Downloaded $downloaded competitor thumbnails to: $comp_dir"
    print_info "Analyse these with vision AI to identify winning patterns."
    print_info "Score prompt: thumbnail-factory-helper.sh score <image_path>"
    return 0
}

# ============================================================================
# A/B Test Status
# ============================================================================

cmd_ab_status() {
    local video_id="${1:?Video ID required}"

    init_db

    print_info "A/B test status for video: $video_id"
    echo ""

    # Show all variants and their scores
    local results
    results=$(sqlite3 -header -column "$THUMB_DB" "
        SELECT
            variant_label AS 'Variant',
            printf('%.1f', score_total) AS 'Score',
            status AS 'Status',
            CASE WHEN is_winner = 1 THEN 'YES' ELSE '' END AS 'Winner',
            CASE WHEN ctr > 0 THEN printf('%.2f%%', ctr) ELSE '-' END AS 'CTR',
            CASE WHEN impressions > 0 THEN impressions ELSE '-' END AS 'Impressions',
            substr(created_at, 1, 10) AS 'Created'
        FROM thumbnail_tests
        WHERE video_id = '$video_id'
        ORDER BY score_total DESC;
    " 2>/dev/null)

    if [[ -z "$results" ]]; then
        print_warning "No thumbnail tests found for video: $video_id"
        print_info "Start with: thumbnail-factory-helper.sh brief $video_id"
        return 0
    fi

    echo "$results"
    echo ""

    # Summary stats
    local stats
    stats=$(sqlite3 "$THUMB_DB" "
        SELECT
            count(*) AS total,
            count(CASE WHEN score_total >= $THUMB_MIN_SCORE THEN 1 END) AS passing,
            printf('%.1f', avg(score_total)) AS avg_score,
            count(CASE WHEN is_winner = 1 THEN 1 END) AS winners
        FROM thumbnail_tests
        WHERE video_id = '$video_id';
    " 2>/dev/null)

    local total passing avg_score winners
    IFS='|' read -r total passing avg_score winners <<< "$stats"

    echo "Summary:"
    echo "  Total variants: $total"
    echo "  Passing (>=$THUMB_MIN_SCORE): $passing"
    echo "  Average score: $avg_score"
    echo "  Winner declared: ${winners:-0}"
    echo ""

    # YouTube A/B testing note
    echo "YouTube A/B Testing:"
    echo "  YouTube Studio now supports built-in thumbnail A/B testing."
    echo "  Upload passing variants via YouTube Studio > Video > Thumbnail > Test & Compare"
    echo "  Minimum 1000 impressions per variant for statistical significance."
    echo ""

    return 0
}

# ============================================================================
# Test History
# ============================================================================

cmd_history() {
    local video_id="${1:-}"

    init_db

    if [[ -n "$video_id" ]]; then
        print_info "Thumbnail test history for video: $video_id"
        sqlite3 -header -column "$THUMB_DB" "
            SELECT
                variant_label AS 'Variant',
                printf('%.1f', score_total) AS 'Score',
                status AS 'Status',
                CASE WHEN is_winner = 1 THEN 'YES' ELSE '' END AS 'Winner',
                CASE WHEN ctr > 0 THEN printf('%.2f%%', ctr) ELSE '-' END AS 'CTR',
                substr(created_at, 1, 10) AS 'Created'
            FROM thumbnail_tests
            WHERE video_id = '$video_id'
            ORDER BY created_at DESC;
        " 2>/dev/null
    else
        print_info "All thumbnail tests (most recent first)"
        sqlite3 -header -column "$THUMB_DB" "
            SELECT
                video_id AS 'Video',
                count(*) AS 'Variants',
                printf('%.1f', max(score_total)) AS 'Best',
                printf('%.1f', avg(score_total)) AS 'Avg',
                count(CASE WHEN is_winner = 1 THEN 1 END) AS 'Winners',
                substr(max(created_at), 1, 10) AS 'Last Test'
            FROM thumbnail_tests
            GROUP BY video_id
            ORDER BY max(created_at) DESC
            LIMIT 20;
        " 2>/dev/null
    fi

    return 0
}

# ============================================================================
# Performance Report
# ============================================================================

cmd_report() {
    local recent_only=false
    if [[ "${1:-}" == "--recent" ]]; then
        recent_only=true
    fi

    init_db

    print_info "Thumbnail A/B Testing Performance Report"
    echo ""

    # Overall stats
    local overall
    overall=$(sqlite3 "$THUMB_DB" "
        SELECT
            count(DISTINCT video_id),
            count(*),
            printf('%.1f', avg(score_total)),
            printf('%.1f', max(score_total)),
            count(CASE WHEN score_total >= $THUMB_MIN_SCORE THEN 1 END),
            count(CASE WHEN is_winner = 1 THEN 1 END),
            CASE WHEN count(CASE WHEN ctr > 0 THEN 1 END) > 0
                THEN printf('%.2f', avg(CASE WHEN ctr > 0 THEN ctr END))
                ELSE 'N/A' END
        FROM thumbnail_tests;
    " 2>/dev/null)

    IFS='|' read -r videos variants avg_score best_score passing winners avg_ctr <<< "$overall"

    echo "Overall Statistics:"
    echo "  Videos tested:     $videos"
    echo "  Total variants:    $variants"
    echo "  Average score:     $avg_score/10"
    echo "  Best score:        $best_score/10"
    echo "  Passing variants:  $passing (>=$THUMB_MIN_SCORE)"
    echo "  Winners declared:  $winners"
    echo "  Average CTR:       ${avg_ctr}%"
    echo ""

    # Score distribution
    echo "Score Distribution:"
    sqlite3 "$THUMB_DB" "
        SELECT
            CASE
                WHEN score_total >= 9 THEN '9-10 (Excellent)'
                WHEN score_total >= 7.5 THEN '7.5-9 (Good/Pass)'
                WHEN score_total >= 5 THEN '5-7.5 (Below threshold)'
                WHEN score_total > 0 THEN '1-5 (Poor)'
                ELSE 'Unscored'
            END AS range,
            count(*) AS count
        FROM thumbnail_tests
        GROUP BY range
        ORDER BY
            CASE range
                WHEN '9-10 (Excellent)' THEN 1
                WHEN '7.5-9 (Good/Pass)' THEN 2
                WHEN '5-7.5 (Below threshold)' THEN 3
                WHEN '1-5 (Poor)' THEN 4
                ELSE 5
            END;
    " 2>/dev/null | while IFS='|' read -r range cnt; do
        printf "  %-30s %s\n" "$range" "$cnt"
    done
    echo ""

    # Style template performance
    echo "Style Template Performance:"
    sqlite3 -header -column "$THUMB_DB" "
        SELECT
            style_template AS 'Template',
            count(*) AS 'Uses',
            printf('%.1f', avg(score_total)) AS 'Avg Score',
            printf('%.1f', max(score_total)) AS 'Best',
            count(CASE WHEN is_winner = 1 THEN 1 END) AS 'Winners'
        FROM thumbnail_tests
        WHERE style_template != ''
        GROUP BY style_template
        ORDER BY avg(score_total) DESC;
    " 2>/dev/null
    echo ""

    # Recent tests
    if [[ "$recent_only" == "true" ]]; then
        echo "Recent Tests (last 7 days):"
        sqlite3 -header -column "$THUMB_DB" "
            SELECT
                video_id AS 'Video',
                variant_label AS 'Variant',
                printf('%.1f', score_total) AS 'Score',
                status AS 'Status',
                substr(created_at, 1, 10) AS 'Date'
            FROM thumbnail_tests
            WHERE created_at >= datetime('now', '-7 days')
            ORDER BY created_at DESC
            LIMIT 20;
        " 2>/dev/null
    fi

    # Recommendations
    echo ""
    echo "Recommendations:"
    if [[ "$variants" -lt 10 ]]; then
        echo "  - Generate more variants (current: $variants, target: 10+ per video)"
    fi
    if [[ "$passing" -eq 0 ]] && [[ "$variants" -gt 0 ]]; then
        echo "  - No variants pass threshold ($THUMB_MIN_SCORE) — review style templates"
    fi
    if [[ "$winners" -eq 0 ]] && [[ "$passing" -gt 0 ]]; then
        echo "  - Passing variants exist but no winner declared — run A/B tests"
    fi
    echo "  - Store winning patterns: memory-helper.sh store --namespace youtube-patterns"
    echo ""

    return 0
}

# ============================================================================
# Compare thumbnail sets
# ============================================================================

cmd_compare() {
    local dir1="${1:?First directory required}"
    local dir2="${2:?Second directory required}"

    if [[ ! -d "$dir1" ]] || [[ ! -d "$dir2" ]]; then
        print_error "Both directories must exist"
        return 1
    fi

    init_db

    local count1=0 count2=0
    count1=$(find "$dir1" -maxdepth 1 \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) 2>/dev/null | wc -l | tr -d ' ')
    count2=$(find "$dir2" -maxdepth 1 \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) 2>/dev/null | wc -l | tr -d ' ')

    echo "Thumbnail Set Comparison:"
    echo ""
    echo "  Set A: $dir1 ($count1 images)"
    echo "  Set B: $dir2 ($count2 images)"
    echo ""

    # Compare scores if available
    local scores_a scores_b
    scores_a=$(sqlite3 "$THUMB_DB" "
        SELECT printf('%.1f', avg(score_total)), printf('%.1f', max(score_total)), count(*)
        FROM thumbnail_tests
        WHERE variant_path LIKE '$(echo "$dir1" | sed "s/'/''/g")%' AND score_total > 0;
    " 2>/dev/null)

    scores_b=$(sqlite3 "$THUMB_DB" "
        SELECT printf('%.1f', avg(score_total)), printf('%.1f', max(score_total)), count(*)
        FROM thumbnail_tests
        WHERE variant_path LIKE '$(echo "$dir2" | sed "s/'/''/g")%' AND score_total > 0;
    " 2>/dev/null)

    if [[ -n "$scores_a" ]] || [[ -n "$scores_b" ]]; then
        echo "  Metric          | Set A    | Set B"
        echo "  ----------------|----------|--------"
        IFS='|' read -r avg_a best_a scored_a <<< "$scores_a"
        IFS='|' read -r avg_b best_b scored_b <<< "$scores_b"
        printf "  %-16s| %-9s| %s\n" "Avg Score" "${avg_a:-N/A}" "${avg_b:-N/A}"
        printf "  %-16s| %-9s| %s\n" "Best Score" "${best_a:-N/A}" "${best_b:-N/A}"
        printf "  %-16s| %-9s| %s\n" "Scored" "${scored_a:-0}" "${scored_b:-0}"
    else
        echo "  No scores recorded yet. Score thumbnails first:"
        echo "  thumbnail-factory-helper.sh batch-score $dir1"
        echo "  thumbnail-factory-helper.sh batch-score $dir2"
    fi

    echo ""
    return 0
}

# ============================================================================
# Help
# ============================================================================

show_help() {
    cat << 'EOF'
Thumbnail Factory Helper - Generate, Score, and A/B Test Thumbnails

Usage: thumbnail-factory-helper.sh <command> [args] [options]

Commands:
  brief <video_id>                  Generate thumbnail design brief from video metadata
  generate <video_id> [count]       Generate thumbnail variants (default: 5)
  score <image_path>                Score a single thumbnail against quality rubric
  record-score <path> <f> <co> <t> <b> <e> <cl>
                                    Record manual scores (face, contrast, text, brand, emotion, clarity)
  batch-score <directory>           Score all thumbnails in a directory
  competitors <video_id> [count]    Download and analyse competitor thumbnails
  compare <dir1> <dir2>             Compare two sets of thumbnails
  ab-status <video_id>              Show A/B test status for a video
  history [video_id]                Show test history (all videos or specific)
  report [--recent]                 Generate performance report
  help                              Show this help message

Workflow:
  1. brief <video_id>               Generate design brief with concepts
  2. generate <video_id> 10         Generate 10 thumbnail variants
  3. batch-score <variants_dir>     Score all variants
  4. record-score <path> ...        Enter scores for each variant
  5. ab-status <video_id>           Review which pass threshold (7.5+)
  6. Upload passing variants to YouTube Studio A/B test
  7. After 1000+ impressions, declare winner

Scoring Rubric (1-10 scale, weighted):
  Face Prominence  25%   Face visible, clear, emotionally expressive
  Contrast         20%   Stands out in thumbnail grid
  Text Space       15%   Clear area for title overlay
  Brand Alignment  15%   Matches channel visual identity
  Emotion          15%   Evokes curiosity/surprise/excitement
  Clarity          10%   Readable at small sizes (120x90px)

  Threshold: 7.5+ = ready for A/B testing

Image Generation:
  Requires OPENAI_API_KEY for DALL-E 3 generation.
  Without API key, generates prompt files for manual use.
  Set key: aidevops secret set OPENAI_API_KEY

Data Storage:
  Workspace: ~/.aidevops/.agent-workspace/work/youtube/thumbnails/
  Database:  ~/.aidevops/.agent-workspace/thumbnail-tests.db

Examples:
  thumbnail-factory-helper.sh brief dQw4w9WgXcQ
  thumbnail-factory-helper.sh generate dQw4w9WgXcQ 10
  thumbnail-factory-helper.sh competitors dQw4w9WgXcQ 5
  thumbnail-factory-helper.sh batch-score ~/.aidevops/.agent-workspace/work/youtube/thumbnails/dQw4w9WgXcQ/variants/
  thumbnail-factory-helper.sh record-score /path/to/variant-1.png 8 7 9 8 7 8
  thumbnail-factory-helper.sh ab-status dQw4w9WgXcQ
  thumbnail-factory-helper.sh report --recent

Related:
  youtube-helper.sh                 YouTube Data API wrapper
  content/production/image.md       Image generation templates
  content/optimization.md           A/B testing methodology
  youtube/optimizer.md              Thumbnail brief templates
  youtube/thumbnail-ab-testing.md   Full pipeline documentation
EOF
    return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "$command" in
        "brief")
            cmd_brief "$@"
            ;;
        "generate")
            cmd_generate "$@"
            ;;
        "score")
            cmd_score "$@"
            ;;
        "record-score")
            cmd_record_score "$@"
            ;;
        "batch-score")
            cmd_batch_score "$@"
            ;;
        "competitors")
            cmd_competitors "$@"
            ;;
        "compare")
            cmd_compare "$@"
            ;;
        "ab-status")
            cmd_ab_status "$@"
            ;;
        "history")
            cmd_history "$@"
            ;;
        "report")
            cmd_report "$@"
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
