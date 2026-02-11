#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155
set -euo pipefail

# Content Fan-Out Helper Script
# Orchestrates the diamond pipeline: one story -> 10+ outputs across media and channels.
#
# Usage: ./content-fanout-helper.sh [command] [args] [options]
# Commands:
#   plan <brief-file>           - Generate a fan-out plan from a story brief
#   run <plan-file>             - Execute a fan-out plan (generates all outputs)
#   channels                    - List available distribution channels
#   formats                     - List available media formats
#   status <plan-file>          - Show progress of a fan-out run
#   template [type]             - Generate a story brief template (default|video|blog|social)
#   estimate <brief-file>       - Estimate time and token cost for a fan-out
#   help                        - Show this help message
#
# The fan-out pipeline:
#   1. Parse story brief (topic, angle, audience, channels)
#   2. Generate channel-specific output specs
#   3. Produce outputs per channel (scripts, copy, metadata)
#   4. Write all outputs to a structured directory
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly FANOUT_VERSION="1.0.0"
readonly WORKSPACE_DIR="${HOME}/.aidevops/.agent-workspace/work/content-fanout"
readonly TEMPLATES_DIR="${WORKSPACE_DIR}/templates"
readonly PLANS_DIR="${WORKSPACE_DIR}/plans"
readonly OUTPUTS_DIR="${WORKSPACE_DIR}/outputs"

# All available channels (space-separated for iteration)
readonly ALL_CHANNELS="blog email podcast short-form social-linkedin social-reddit social-x youtube"

# ─── Channel/format lookup functions (bash 3.2 compatible) ───────────

# Get subagent path for a channel
channel_subagent() {
    local ch="$1"
    case "$ch" in
        youtube)        echo "distribution/youtube" ;;
        short-form)     echo "distribution/short-form" ;;
        social-x)       echo "distribution/social" ;;
        social-linkedin) echo "distribution/social" ;;
        social-reddit)  echo "distribution/social" ;;
        blog)           echo "distribution/blog" ;;
        email)          echo "distribution/email" ;;
        podcast)        echo "distribution/podcast" ;;
        *) return 1 ;;
    esac
    return 0
}

# Get required formats for a channel
channel_formats() {
    local ch="$1"
    case "$ch" in
        youtube)        echo "script,image,video,audio" ;;
        short-form)     echo "script,video,audio" ;;
        social-x)       echo "script,image" ;;
        social-linkedin) echo "script,image" ;;
        social-reddit)  echo "script" ;;
        blog)           echo "script,image" ;;
        email)          echo "script,image" ;;
        podcast)        echo "script,audio" ;;
        *) return 1 ;;
    esac
    return 0
}

# Get output descriptions for a channel
channel_outputs() {
    local ch="$1"
    case "$ch" in
        youtube)        echo "Long-form script, thumbnail brief, description, tags, end screen CTA" ;;
        short-form)     echo "60s vertical script (TikTok/Reels/Shorts), caption, trending sound note" ;;
        social-x)       echo "Thread (3-10 posts) or single post, hook-first" ;;
        social-linkedin) echo "Thought leadership post, professional framing" ;;
        social-reddit)  echo "Community-native post, value-first, anti-promotional" ;;
        blog)           echo "SEO-optimized article outline, meta title/description, internal link suggestions" ;;
        email)          echo "Newsletter edition, subject line variants, preview text, CTA" ;;
        podcast)        echo "Show notes, episode script/talking points, intro/outro" ;;
        *) return 1 ;;
    esac
    return 0
}

# Get production subagent for a format
format_subagent() {
    local fmt="$1"
    case "$fmt" in
        script)    echo "production/writing" ;;
        image)     echo "production/image" ;;
        video)     echo "production/video" ;;
        audio)     echo "production/audio" ;;
        character) echo "production/characters" ;;
        *) return 1 ;;
    esac
    return 0
}

# Check if a channel is valid
is_valid_channel() {
    local ch="$1"
    channel_subagent "$ch" >/dev/null 2>&1
    return $?
}

# ─── Utility functions ────────────────────────────────────────────────

ensure_dirs() {
    mkdir -p "${TEMPLATES_DIR}" "${PLANS_DIR}" "${OUTPUTS_DIR}"
    return 0
}

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
    return 0
}

slug() {
    local input="$1"
    echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//'
    return 0
}

# Parse a story brief YAML-like file into variables
# Brief format:
#   topic: Why 95% of AI influencers fail
#   angle: contrarian
#   audience: aspiring AI content creators
#   channels: youtube, short-form, social-x, blog, email
#   tone: direct, data-backed, slightly provocative
#   cta: Subscribe for weekly AI creator breakdowns
#   notes: Include specific failure stats, name no names
parse_brief() {
    local brief_file="$1"

    if [[ ! -f "$brief_file" ]]; then
        print_error "Brief file not found: $brief_file"
        return 1
    fi

    # Extract fields (simple key: value parsing)
    BRIEF_TOPIC=$(grep -i '^topic:' "$brief_file" | sed 's/^[^:]*: *//' | head -1)
    BRIEF_ANGLE=$(grep -i '^angle:' "$brief_file" | sed 's/^[^:]*: *//' | head -1)
    BRIEF_AUDIENCE=$(grep -i '^audience:' "$brief_file" | sed 's/^[^:]*: *//' | head -1)
    BRIEF_CHANNELS=$(grep -i '^channels:' "$brief_file" | sed 's/^[^:]*: *//' | head -1)
    BRIEF_TONE=$(grep -i '^tone:' "$brief_file" | sed 's/^[^:]*: *//' | head -1)
    BRIEF_CTA=$(grep -i '^cta:' "$brief_file" | sed 's/^[^:]*: *//' | head -1)
    BRIEF_NOTES=$(grep -i '^notes:' "$brief_file" | sed 's/^[^:]*: *//' | head -1)

    # Defaults
    BRIEF_ANGLE="${BRIEF_ANGLE:-contrarian}"
    BRIEF_TONE="${BRIEF_TONE:-direct, conversational}"
    BRIEF_CHANNELS="${BRIEF_CHANNELS:-youtube,short-form,social-x,social-linkedin,blog,email}"

    # Validate required fields
    if [[ -z "${BRIEF_TOPIC:-}" ]]; then
        print_error "Brief must include 'topic:' field"
        return 1
    fi
    if [[ -z "${BRIEF_AUDIENCE:-}" ]]; then
        print_error "Brief must include 'audience:' field"
        return 1
    fi

    return 0
}

# Parse comma-separated channel list, validate each
# Outputs valid channels space-separated
parse_channels() {
    local channel_str="$1"
    local valid_channels=""

    # Normalize: remove spaces around commas
    channel_str="${channel_str// , /,}"
    channel_str="${channel_str//, /,}"
    channel_str="${channel_str// ,/,}"

    local IFS=','
    for ch in $channel_str; do
        # Trim whitespace
        ch=$(echo "$ch" | tr -d ' ')
        if [[ "$ch" == "all" ]]; then
            echo "$ALL_CHANNELS"
            return 0
        elif is_valid_channel "$ch"; then
            if [[ -n "$valid_channels" ]]; then
                valid_channels="${valid_channels} ${ch}"
            else
                valid_channels="$ch"
            fi
        else
            print_warning "Unknown channel: $ch (skipping)"
        fi
    done

    if [[ -z "$valid_channels" ]]; then
        print_error "No valid channels specified"
        return 1
    fi

    echo "$valid_channels"
    return 0
}

# ─── Commands ─────────────────────────────────────────────────────────

cmd_plan() {
    local brief_file="$1"
    ensure_dirs

    parse_brief "$brief_file" || return 1

    local channels
    channels=$(parse_channels "$BRIEF_CHANNELS") || return 1

    local topic_slug
    topic_slug=$(slug "$BRIEF_TOPIC")
    local plan_id="${topic_slug}-$(date +%Y%m%d-%H%M%S)"
    local plan_file="${PLANS_DIR}/${plan_id}.plan"

    # Count channels
    local channel_count=0
    for _ch in $channels; do
        channel_count=$((channel_count + 1))
    done

    print_info "Generating fan-out plan: ${plan_id}"
    print_info "Topic: ${BRIEF_TOPIC}"
    print_info "Channels: ${channel_count} (${channels})"

    # Calculate total outputs and collect unique formats
    local total_outputs=0
    local all_formats=""

    {
        echo "# Content Fan-Out Plan"
        echo "# Generated: $(timestamp)"
        echo "# Version: ${FANOUT_VERSION}"
        echo ""
        echo "id: ${plan_id}"
        echo "topic: ${BRIEF_TOPIC}"
        echo "angle: ${BRIEF_ANGLE}"
        echo "audience: ${BRIEF_AUDIENCE}"
        echo "tone: ${BRIEF_TONE}"
        echo "cta: ${BRIEF_CTA:-}"
        echo "notes: ${BRIEF_NOTES:-}"
        echo "status: planned"
        echo ""
        echo "# --- Channel Outputs ---"
        echo ""

        for ch in $channels; do
            local formats
            formats=$(channel_formats "$ch")
            local outputs
            outputs=$(channel_outputs "$ch")
            local subagent
            subagent=$(channel_subagent "$ch")

            echo "channel: ${ch}"
            echo "  subagent: ${subagent}"
            echo "  formats: ${formats}"
            echo "  outputs: ${outputs}"
            echo "  status: pending"
            echo ""

            total_outputs=$((total_outputs + 1))

            # Collect unique formats
            local IFS=','
            for fmt in $formats; do
                case " ${all_formats} " in
                    *" ${fmt} "*) ;;  # already present
                    *) all_formats="${all_formats} ${fmt}" ;;
                esac
            done
        done

        # Count unique formats
        local format_count=0
        for _fmt in $all_formats; do
            format_count=$((format_count + 1))
        done

        echo "# --- Summary ---"
        echo ""
        echo "total_channels: ${channel_count}"
        echo "total_outputs: ${total_outputs}"
        echo "unique_formats: ${format_count} (${all_formats})"
        echo "estimated_tokens: $((total_outputs * 2000))"
    } > "$plan_file"

    # Count unique formats for display
    local format_count=0
    for _fmt in $all_formats; do
        format_count=$((format_count + 1))
    done

    print_success "Plan written: ${plan_file}"
    echo ""
    echo "  Channels:  ${channel_count}"
    echo "  Outputs:   ${total_outputs}"
    echo "  Formats:   ${format_count} (${all_formats})"
    echo ""
    echo "Next: content-fanout-helper.sh run ${plan_file}"

    return 0
}

cmd_run() {
    local plan_file="$1"
    ensure_dirs

    if [[ ! -f "$plan_file" ]]; then
        print_error "Plan file not found: $plan_file"
        return 1
    fi

    local plan_id
    plan_id=$(grep '^id:' "$plan_file" | sed 's/^id: *//')
    local topic
    topic=$(grep '^topic:' "$plan_file" | sed 's/^topic: *//')
    local angle
    angle=$(grep '^angle:' "$plan_file" | sed 's/^angle: *//')
    local audience
    audience=$(grep '^audience:' "$plan_file" | sed 's/^audience: *//')
    local tone
    tone=$(grep '^tone:' "$plan_file" | sed 's/^tone: *//')
    local cta
    cta=$(grep '^cta:' "$plan_file" | sed 's/^cta: *//' || echo "")
    local notes
    notes=$(grep '^notes:' "$plan_file" | sed 's/^notes: *//' || echo "")

    local output_dir="${OUTPUTS_DIR}/${plan_id}"
    mkdir -p "$output_dir"

    print_info "Executing fan-out: ${plan_id}"
    print_info "Output directory: ${output_dir}"

    # Extract channels from plan
    local channels=""
    while IFS= read -r line; do
        local ch="${line#channel: }"
        if [[ -n "$channels" ]]; then
            channels="${channels} ${ch}"
        else
            channels="$ch"
        fi
    done < <(grep '^channel:' "$plan_file")

    local completed=0
    local failed=0

    for ch in $channels; do
        local ch_dir="${output_dir}/${ch}"
        mkdir -p "$ch_dir"

        print_info "Generating: ${ch}..."

        # Write the channel-specific prompt file for AI processing
        local prompt_file="${ch_dir}/prompt.md"
        local outputs
        outputs=$(channel_outputs "$ch" 2>/dev/null || echo "Channel-specific content")
        local formats
        formats=$(channel_formats "$ch" 2>/dev/null || echo "script")

        {
            echo "# Fan-Out Prompt: ${ch}"
            echo ""
            echo "## Story Context"
            echo ""
            echo "- **Topic**: ${topic}"
            echo "- **Angle**: ${angle}"
            echo "- **Audience**: ${audience}"
            echo "- **Tone**: ${tone}"
            echo "- **CTA**: ${cta}"
            echo "- **Notes**: ${notes}"
            echo ""
            echo "## Channel: ${ch}"
            echo ""
            echo "**Required outputs**: ${outputs}"
            echo ""
            echo "**Required formats**: ${formats}"
            echo ""
            echo "## Instructions"
            echo ""

            case "$ch" in
                youtube)
                    echo "Generate a complete YouTube video package:"
                    echo "1. Long-form script (scene-by-scene with B-roll directions, 8-12 min target)"
                    echo "2. Title (3 variants using hook formulas: Bold Claim, Question, Curiosity Gap)"
                    echo "3. Description (SEO-optimized, timestamps, links, keywords)"
                    echo "4. Tags (15-20 relevant tags)"
                    echo "5. Thumbnail brief (text overlay, emotion, color scheme, 3 variants)"
                    echo "6. End screen CTA script"
                    echo ""
                    echo "Reference: content/distribution/youtube/ for YouTube-specific conventions."
                    ;;
                short-form)
                    echo "Generate vertical short-form video content:"
                    echo "1. 60-second script (hook in first 1-3 seconds, fast cuts every 1-3s)"
                    echo "2. Caption/subtitle text (for 80%+ silent viewers)"
                    echo "3. Trending sound suggestion (describe mood/genre, not specific track)"
                    echo "4. 3 hook variants (pattern interrupt openers)"
                    echo ""
                    echo "Format: 9:16 vertical. Platforms: TikTok, Reels, Shorts."
                    echo "Reference: content/distribution/short-form.md"
                    ;;
                social-x)
                    echo "Generate X (Twitter) content:"
                    echo "1. Thread version (5-8 posts, hook-first, each post standalone value)"
                    echo "2. Single post version (under 280 chars, punchy)"
                    echo "3. Quote-post version (for sharing related content)"
                    echo ""
                    echo "Voice: Concise, opinionated, personality-forward."
                    echo "Reference: content/distribution/social.md"
                    ;;
                social-linkedin)
                    echo "Generate LinkedIn content:"
                    echo "1. Long-form post (1200-1500 chars, thought leadership framing)"
                    echo "2. Short-form post (under 300 chars, for quick engagement)"
                    echo "3. Article outline (if topic warrants deeper treatment)"
                    echo ""
                    echo "Voice: Professional, insight-driven, no sales pitch."
                    echo "Reference: content/distribution/social.md"
                    ;;
                social-reddit)
                    echo "Generate Reddit content:"
                    echo "1. Post title (curiosity-driven, not clickbait)"
                    echo "2. Post body (value-first, community-native, anti-promotional)"
                    echo "3. Suggested subreddits (3-5 relevant communities)"
                    echo "4. Comment engagement strategy"
                    echo ""
                    echo "Voice: Authentic, helpful, never salesy."
                    echo "Reference: content/distribution/social.md"
                    ;;
                blog)
                    echo "Generate SEO-optimized blog content:"
                    echo "1. Article outline (H2/H3 structure, 1500-2500 words target)"
                    echo "2. Meta title (under 60 chars, keyword-front-loaded)"
                    echo "3. Meta description (under 155 chars, includes CTA)"
                    echo "4. Target keyword + 5 secondary keywords"
                    echo "5. Internal link suggestions (3-5 related topics)"
                    echo "6. Featured image brief"
                    echo ""
                    echo "Reference: content/distribution/blog.md, seo/"
                    ;;
                email)
                    echo "Generate email/newsletter content:"
                    echo "1. Subject line (5 variants, A/B test ready)"
                    echo "2. Preview text (under 90 chars)"
                    echo "3. Newsletter body (story-driven, single CTA)"
                    echo "4. P.S. line (secondary hook)"
                    echo ""
                    echo "Reference: content/distribution/email.md"
                    ;;
                podcast)
                    echo "Generate podcast content:"
                    echo "1. Episode title (curiosity-driven)"
                    echo "2. Talking points / script outline (15-20 min target)"
                    echo "3. Intro script (30s hook)"
                    echo "4. Outro script (CTA + next episode tease)"
                    echo "5. Show notes (timestamps, links, resources)"
                    echo ""
                    echo "Reference: content/distribution/podcast.md"
                    ;;
                *)
                    echo "Generate content adapted for: ${ch}"
                    echo "Follow the conventions in the relevant distribution subagent."
                    ;;
            esac

            echo ""
            echo "## Quality Checklist"
            echo ""
            echo "- [ ] Hook is in the first line/sentence/second"
            echo "- [ ] Tone matches platform expectations"
            echo "- [ ] CTA is clear and singular"
            echo "- [ ] No cross-posting smell (platform-native language)"
            echo "- [ ] Story angle is consistent with brief"
        } > "$prompt_file"

        # Write a status marker
        echo "pending" > "${ch_dir}/.status"
        completed=$((completed + 1))
    done

    # Write run summary
    {
        echo "# Fan-Out Run Summary"
        echo "# Executed: $(timestamp)"
        echo ""
        echo "plan: ${plan_file}"
        echo "output_dir: ${output_dir}"
        echo "channels_prepared: ${completed}"
        echo "channels_failed: ${failed}"
        echo "status: prompts_ready"
        echo ""
        echo "# Each channel directory contains a prompt.md file ready for AI processing."
        echo "# Process with the content agent: @content run fan-out from ${output_dir}"
    } > "${output_dir}/summary.md"

    print_success "Fan-out prepared: ${completed} channels"
    echo ""
    echo "  Output dir: ${output_dir}"
    echo "  Channels:   ${completed} prepared, ${failed} failed"
    echo ""
    echo "Each channel directory contains a prompt.md ready for AI processing."
    echo "Process all channels: @content run fan-out from ${output_dir}"

    return 0
}

cmd_channels() {
    echo "Available distribution channels:"
    echo ""
    printf "  %-18s %-30s %s\n" "CHANNEL" "SUBAGENT" "OUTPUTS"
    printf "  %-18s %-30s %s\n" "-------" "--------" "-------"
    for ch in $ALL_CHANNELS; do
        local subagent
        subagent=$(channel_subagent "$ch")
        local outputs
        outputs=$(channel_outputs "$ch")
        printf "  %-18s %-30s %s\n" "$ch" "$subagent" "$outputs"
    done
    echo ""
    echo "Total: 8 channels"
    return 0
}

cmd_formats() {
    echo "Available media formats:"
    echo ""
    printf "  %-15s %s\n" "FORMAT" "PRODUCTION SUBAGENT"
    printf "  %-15s %s\n" "------" "-------------------"
    for fmt in audio character image script video; do
        local subagent
        subagent=$(format_subagent "$fmt")
        printf "  %-15s %s\n" "$fmt" "$subagent"
    done
    echo ""
    echo "Channel format requirements:"
    echo ""
    printf "  %-18s %s\n" "CHANNEL" "REQUIRED FORMATS"
    printf "  %-18s %s\n" "-------" "----------------"
    for ch in $ALL_CHANNELS; do
        local formats
        formats=$(channel_formats "$ch")
        printf "  %-18s %s\n" "$ch" "$formats"
    done
    return 0
}

cmd_status() {
    local plan_file="$1"

    if [[ ! -f "$plan_file" ]]; then
        print_error "Plan file not found: $plan_file"
        return 1
    fi

    local plan_id
    plan_id=$(grep '^id:' "$plan_file" | sed 's/^id: *//')
    local output_dir="${OUTPUTS_DIR}/${plan_id}"

    if [[ ! -d "$output_dir" ]]; then
        print_info "Plan has not been executed yet"
        print_info "Run: content-fanout-helper.sh run ${plan_file}"
        return 0
    fi

    echo "Fan-out status: ${plan_id}"
    echo ""

    local total=0
    local pending=0
    local complete=0

    for ch_dir in "${output_dir}"/*/; do
        [[ -d "$ch_dir" ]] || continue
        local ch
        ch=$(basename "$ch_dir")
        local status="unknown"

        if [[ -f "${ch_dir}/.status" ]]; then
            status=$(cat "${ch_dir}/.status")
        fi

        total=$((total + 1))
        case "$status" in
            pending) pending=$((pending + 1)); printf "  [ ] %s\n" "$ch" ;;
            complete) complete=$((complete + 1)); printf "  [x] %s\n" "$ch" ;;
            *) printf "  [?] %s (%s)\n" "$ch" "$status" ;;
        esac
    done

    echo ""
    echo "  Total: ${total} | Complete: ${complete} | Pending: ${pending}"

    return 0
}

cmd_template() {
    local template_type="${1:-default}"
    ensure_dirs

    local template_file="${TEMPLATES_DIR}/brief-${template_type}.md"

    case "$template_type" in
        default)
            {
                echo "# Story Brief"
                echo ""
                echo "topic: "
                echo "angle: contrarian"
                echo "audience: "
                echo "channels: youtube, short-form, social-x, social-linkedin, social-reddit, blog, email, podcast"
                echo "tone: direct, conversational, data-backed"
                echo "cta: "
                echo "notes: "
            } > "$template_file"
            ;;
        video)
            {
                echo "# Story Brief (Video-First)"
                echo ""
                echo "topic: "
                echo "angle: contrarian"
                echo "audience: "
                echo "channels: youtube, short-form"
                echo "tone: energetic, visual, fast-paced"
                echo "cta: "
                echo "notes: Include B-roll directions and visual cues"
            } > "$template_file"
            ;;
        blog)
            {
                echo "# Story Brief (Blog/SEO)"
                echo ""
                echo "topic: "
                echo "angle: educational"
                echo "audience: "
                echo "channels: blog, email, social-linkedin"
                echo "tone: authoritative, helpful, SEO-aware"
                echo "cta: "
                echo "notes: Target keyword: [keyword]. Include internal link opportunities."
            } > "$template_file"
            ;;
        social)
            {
                echo "# Story Brief (Social-First)"
                echo ""
                echo "topic: "
                echo "angle: hot-take"
                echo "audience: "
                echo "channels: social-x, social-linkedin, social-reddit, short-form"
                echo "tone: punchy, opinionated, shareable"
                echo "cta: "
                echo "notes: Optimise for engagement and shares"
            } > "$template_file"
            ;;
        *)
            print_error "Unknown template type: $template_type"
            print_info "Available: default, video, blog, social"
            return 1
            ;;
    esac

    print_success "Template written: ${template_file}"
    echo ""
    cat "$template_file"

    return 0
}

cmd_estimate() {
    local brief_file="$1"

    parse_brief "$brief_file" || return 1

    local channels
    channels=$(parse_channels "$BRIEF_CHANNELS") || return 1

    echo "Fan-out estimate for: ${BRIEF_TOPIC}"
    echo ""

    local total_tokens=0
    local total_minutes=0
    local channel_count=0

    printf "  %-18s %-8s %-8s %s\n" "CHANNEL" "TOKENS" "MINUTES" "OUTPUTS"
    printf "  %-18s %-8s %-8s %s\n" "-------" "------" "-------" "-------"

    for ch in $channels; do
        local tokens=0
        local minutes=0

        # Estimates based on typical output sizes
        case "$ch" in
            youtube)         tokens=4000; minutes=8 ;;
            short-form)      tokens=1500; minutes=3 ;;
            social-x)        tokens=1000; minutes=2 ;;
            social-linkedin) tokens=1200; minutes=3 ;;
            social-reddit)   tokens=800;  minutes=2 ;;
            blog)            tokens=3000; minutes=6 ;;
            email)           tokens=1500; minutes=3 ;;
            podcast)         tokens=2500; minutes=5 ;;
            *)               tokens=1500; minutes=3 ;;
        esac

        local outputs
        outputs=$(channel_outputs "$ch" 2>/dev/null || echo "Channel-specific content")
        printf "  %-18s %-8s %-8s %s\n" "$ch" "~${tokens}" "~${minutes}" "$outputs"
        total_tokens=$((total_tokens + tokens))
        total_minutes=$((total_minutes + minutes))
        channel_count=$((channel_count + 1))
    done

    echo ""
    echo "  Total estimated tokens:  ~${total_tokens}"
    echo "  Total estimated time:    ~${total_minutes} minutes (sequential)"
    echo "  Parallel time (3 slots): ~$(( (total_minutes + 2) / 3 )) minutes"
    echo ""
    echo "  Channels: ${channel_count}"
    echo "  Story research (one-time): ~30 minutes"

    return 0
}

cmd_help() {
    echo "Content Fan-Out Helper v${FANOUT_VERSION}"
    echo ""
    echo "Orchestrates the diamond pipeline: one story -> 10+ outputs across channels."
    echo ""
    echo "${HELP_LABEL_USAGE}"
    echo "  content-fanout-helper.sh [command] [args]"
    echo ""
    echo "${HELP_LABEL_COMMANDS}"
    echo "  plan <brief-file>       Generate a fan-out plan from a story brief"
    echo "  run <plan-file>         Execute a fan-out plan (generate all channel prompts)"
    echo "  channels                List available distribution channels"
    echo "  formats                 List available media formats and channel requirements"
    echo "  status <plan-file>      Show progress of a fan-out run"
    echo "  template [type]         Generate a story brief template (default|video|blog|social)"
    echo "  estimate <brief-file>   Estimate time and token cost for a fan-out"
    echo "  help                    Show this help message"
    echo ""
    echo "${HELP_LABEL_EXAMPLES}"
    echo "  # Generate a brief template"
    echo "  content-fanout-helper.sh template default"
    echo ""
    echo "  # Edit the brief, then plan"
    echo "  content-fanout-helper.sh plan ~/my-story-brief.md"
    echo ""
    echo "  # Execute the plan"
    echo "  content-fanout-helper.sh run ~/.aidevops/.agent-workspace/work/content-fanout/plans/my-topic.plan"
    echo ""
    echo "  # Check progress"
    echo "  content-fanout-helper.sh status ~/.aidevops/.agent-workspace/work/content-fanout/plans/my-topic.plan"
    echo ""
    echo "  # Estimate before running"
    echo "  content-fanout-helper.sh estimate ~/my-story-brief.md"
    echo ""
    echo "Pipeline: Brief -> Plan -> Run -> AI Processing -> Outputs"
    echo "See: .agents/content.md for the full diamond pipeline architecture."

    return 0
}

# ─── Main ─────────────────────────────────────────────────────────────

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        plan)
            [[ $# -lt 1 ]] && { print_error "Usage: content-fanout-helper.sh plan <brief-file>"; return 1; }
            cmd_plan "$1"
            ;;
        run)
            [[ $# -lt 1 ]] && { print_error "Usage: content-fanout-helper.sh run <plan-file>"; return 1; }
            cmd_run "$1"
            ;;
        channels)
            cmd_channels
            ;;
        formats)
            cmd_formats
            ;;
        status)
            [[ $# -lt 1 ]] && { print_error "Usage: content-fanout-helper.sh status <plan-file>"; return 1; }
            cmd_status "$1"
            ;;
        template)
            cmd_template "${1:-default}"
            ;;
        estimate)
            [[ $# -lt 1 ]] && { print_error "Usage: content-fanout-helper.sh estimate <brief-file>"; return 1; }
            cmd_estimate "$1"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            print_error "${ERROR_UNKNOWN_COMMAND}: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
