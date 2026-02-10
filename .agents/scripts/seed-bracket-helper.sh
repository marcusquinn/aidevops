#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2012,SC2153
set -euo pipefail

# Seed Bracket Helper Script
# Automates seed bracketing for AI video generation via Higgsfield API.
# Tests sequential seed ranges, tracks job results, scores outputs,
# and identifies production-ready winners.
#
# Seed bracketing increases success rate from ~15% to 70%+ by systematically
# testing seed ranges and scoring outputs against quality criteria.
#
# Usage: ./seed-bracket-helper.sh [command] [options]
# Commands:
#   generate    - Submit batch generation jobs with sequential seeds
#   status      - Check job status for a bracket run
#   score       - Score a completed job output (1-10 per criterion)
#   report      - Show results and winners from a bracket run
#   presets     - List content-type presets (seed ranges, models)
#   help        - Show this help message
#
# Content-type seed ranges:
#   people      1000-1999   Characters, faces, talking heads
#   action      2000-2999   Movement, sports, dynamic scenes
#   landscape   3000-3999   Environments, scenery, architecture
#   product     4000-4999   Objects, demos, product shots
#   youtube     2000-3000   Hybrid action/people for YouTube
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

readonly BRACKET_DIR="${HOME}/.aidevops/.agent-workspace/work/seed-brackets"
readonly HIGGSFIELD_BASE_URL="https://platform.higgsfield.ai"

# Scoring weights (from content/production/video.md)
readonly WEIGHT_COMPOSITION=25
readonly WEIGHT_QUALITY=25
readonly WEIGHT_STYLE=20
readonly WEIGHT_MOTION=20
readonly WEIGHT_ACCURACY=10

# Score thresholds
readonly THRESHOLD_WINNER=80   # 8.0+ on 10-point scale = production-ready
readonly THRESHOLD_ACCEPTABLE=65  # 6.5-7.9 = acceptable with tweaks
# Below 6.5 = discard

# =============================================================================
# Credential Loading
# =============================================================================

load_credentials() {
    local cred_file="${HOME}/.config/aidevops/credentials.sh"
    if [[ -f "$cred_file" ]]; then
        # shellcheck source=/dev/null
        source "$cred_file"
    fi

    if [[ -z "${HIGGSFIELD_API_KEY:-}" || -z "${HIGGSFIELD_SECRET:-}" ]]; then
        print_error "Higgsfield credentials not found."
        print_info "Set HIGGSFIELD_API_KEY and HIGGSFIELD_SECRET in:"
        print_info "  ~/.config/aidevops/credentials.sh"
        print_info "Or run: aidevops secret set HIGGSFIELD_API_KEY"
        return 1
    fi
    return 0
}

# =============================================================================
# Bracket Run Management
# =============================================================================

# Create a new bracket run directory and metadata file
# Arguments:
#   $1 - content type (people|action|landscape|product|youtube|custom)
#   $2 - seed start
#   $3 - seed end
#   $4 - model name
#   $5 - prompt text
# Output: bracket run ID on stdout
create_bracket_run() {
    local content_type="$1"
    local seed_start="$2"
    local seed_end="$3"
    local model="$4"
    local prompt="$5"

    local run_id
    run_id="bracket-$(date -u +%Y%m%dT%H%M%SZ)-${content_type}"
    local run_dir="${BRACKET_DIR}/${run_id}"

    mkdir -p "$run_dir"

    # Write metadata as simple key=value (parseable by bash)
    cat > "${run_dir}/metadata.sh" <<METADATA
# Seed Bracket Run Metadata
RUN_ID="${run_id}"
CONTENT_TYPE="${content_type}"
SEED_START=${seed_start}
SEED_END=${seed_end}
MODEL="${model}"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STATUS="running"
METADATA

    # Store prompt separately (may contain special characters)
    printf '%s' "$prompt" > "${run_dir}/prompt.txt"

    # Initialize results CSV
    echo "seed,job_id,status,score_composition,score_quality,score_style,score_motion,score_accuracy,total_score,result_url" \
        > "${run_dir}/results.csv"

    echo "$run_id"
    return 0
}

# Get the latest bracket run ID
# Output: run ID on stdout, or empty if none
get_latest_run() {
    if [[ ! -d "$BRACKET_DIR" ]]; then
        echo ""
        return 1
    fi

    local latest
    latest=$(ls -1d "${BRACKET_DIR}"/bracket-* 2>/dev/null | sort -r | head -1)
    if [[ -n "$latest" ]]; then
        basename "$latest"
        return 0
    fi
    return 1
}

# Load metadata for a bracket run
# Arguments:
#   $1 - run ID
# Sets global variables from metadata.sh
load_run_metadata() {
    local run_id="$1"
    local meta_file="${BRACKET_DIR}/${run_id}/metadata.sh"

    if [[ ! -f "$meta_file" ]]; then
        print_error "Bracket run not found: ${run_id}"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$meta_file"
    return 0
}

# =============================================================================
# Content Type Presets
# =============================================================================

# Get default seed range for a content type
# Arguments:
#   $1 - content type
# Output: "start end" on stdout
get_seed_range() {
    local content_type="$1"

    case "$content_type" in
        people)    echo "1000 1010" ;;
        action)    echo "2000 2010" ;;
        landscape) echo "3000 3010" ;;
        product)   echo "4000 4010" ;;
        youtube)   echo "2000 2010" ;;
        *)         echo "1000 1010" ;;
    esac
    return 0
}

# Get default model for a content type
# Arguments:
#   $1 - content type
# Output: model name on stdout
get_default_model() {
    local content_type="$1"

    case "$content_type" in
        people|action|youtube) echo "dop-turbo" ;;
        landscape)             echo "dop-standard" ;;
        product)               echo "dop-turbo" ;;
        *)                     echo "dop-turbo" ;;
    esac
    return 0
}

# =============================================================================
# API Interaction
# =============================================================================

# Submit a single generation job to Higgsfield
# Arguments:
#   $1 - prompt
#   $2 - seed
#   $3 - model
# Output: job ID on stdout
submit_generation() {
    local prompt="$1"
    local seed="$2"
    local model="$3"

    local response
    response=$(curl -s -X POST "${HIGGSFIELD_BASE_URL}/v1/image2video/dop" \
        --header "hf-api-key: ${HIGGSFIELD_API_KEY}" \
        --header "hf-secret: ${HIGGSFIELD_SECRET}" \
        --header "${CONTENT_TYPE_JSON}" \
        --data "{
            \"params\": {
                \"prompt\": $(printf '%s' "$prompt" | jq -Rs .),
                \"seed\": ${seed},
                \"model\": \"${model}\"
            }
        }" 2>>"${AIDEVOPS_LOG_FILE:-/dev/null}")

    local job_id
    job_id=$(echo "$response" | jq -r '.jobs[0].id // .id // empty' 2>/dev/null || echo "")

    if [[ -z "$job_id" ]]; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.detail // .message // .error // "Unknown error"' 2>/dev/null || echo "API error")
        print_error "Failed to submit seed ${seed}: ${error_msg}"
        echo "FAILED"
        return 1
    fi

    echo "$job_id"
    return 0
}

# Check job status
# Arguments:
#   $1 - job ID
# Output: "status result_url" on stdout
check_job_status() {
    local job_id="$1"

    local response
    response=$(curl -s -X GET "${HIGGSFIELD_BASE_URL}/api/generation-results?id=${job_id}" \
        --header "hf-api-key: ${HIGGSFIELD_API_KEY}" \
        --header "hf-secret: ${HIGGSFIELD_SECRET}" \
        2>>"${AIDEVOPS_LOG_FILE:-/dev/null}")

    local status
    status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

    local result_url=""
    if [[ "$status" == "completed" ]]; then
        result_url=$(echo "$response" | jq -r '.results[0].url // empty' 2>/dev/null || echo "")
    fi

    echo "${status} ${result_url}"
    return 0
}

# =============================================================================
# Commands
# =============================================================================

# Generate: Submit batch generation jobs with sequential seeds
cmd_generate() {
    local content_type=""
    local seed_start=""
    local seed_end=""
    local model=""
    local prompt=""
    local prompt_file=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)     content_type="${2:-}"; shift 2 ;;
            --start)    seed_start="${2:-}"; shift 2 ;;
            --end)      seed_end="${2:-}"; shift 2 ;;
            --model)    model="${2:-}"; shift 2 ;;
            --prompt)   prompt="${2:-}"; shift 2 ;;
            --file)     prompt_file="${2:-}"; shift 2 ;;
            --dry-run)  dry_run=true; shift ;;
            *)
                # Positional: prompt seed_start seed_end model
                if [[ -z "$prompt" ]]; then
                    prompt="$1"
                elif [[ -z "$seed_start" ]]; then
                    seed_start="$1"
                elif [[ -z "$seed_end" ]]; then
                    seed_end="$1"
                elif [[ -z "$model" ]]; then
                    model="$1"
                fi
                shift
                ;;
        esac
    done

    # Load prompt from file if specified
    if [[ -n "$prompt_file" ]]; then
        if [[ ! -f "$prompt_file" ]]; then
            print_error "Prompt file not found: ${prompt_file}"
            return 1
        fi
        prompt=$(cat "$prompt_file")
    fi

    # Validate prompt
    if [[ -z "$prompt" ]]; then
        print_error "Prompt is required. Use --prompt 'text' or --file path/to/prompt.txt"
        return 1
    fi

    # Apply defaults from content type
    content_type="${content_type:-people}"
    local default_range
    default_range=$(get_seed_range "$content_type")
    seed_start="${seed_start:-${default_range%% *}}"
    seed_end="${seed_end:-${default_range##* }}"
    model="${model:-$(get_default_model "$content_type")}"

    # Validate seed range
    if [[ "$seed_start" -gt "$seed_end" ]]; then
        print_error "Seed start (${seed_start}) must be <= seed end (${seed_end})"
        return 1
    fi

    local seed_count=$(( seed_end - seed_start + 1 ))

    print_info "Seed Bracket Generation"
    echo "  Content type: ${content_type}"
    echo "  Seed range:   ${seed_start}-${seed_end} (${seed_count} seeds)"
    echo "  Model:        ${model}"
    echo "  Prompt:       ${prompt:0:80}..."
    echo ""

    if [[ "$dry_run" == true ]]; then
        print_info "Dry run - no jobs submitted"
        echo ""
        echo "Would submit ${seed_count} generation jobs:"
        local seed
        for seed in $(seq "$seed_start" "$seed_end"); do
            echo "  Seed ${seed} -> ${model}"
        done
        return 0
    fi

    # Load credentials
    load_credentials || return 1

    # Validate jq is available
    if ! command -v jq &>/dev/null; then
        print_error "jq is required for JSON parsing. Install with: brew install jq"
        return 1
    fi

    # Create bracket run
    local run_id
    run_id=$(create_bracket_run "$content_type" "$seed_start" "$seed_end" "$model" "$prompt")
    local run_dir="${BRACKET_DIR}/${run_id}"

    print_info "Bracket run: ${run_id}"
    echo ""

    # Submit jobs
    local seed submitted=0 failed=0
    for seed in $(seq "$seed_start" "$seed_end"); do
        printf "  Seed %d... " "$seed"

        local job_id
        job_id=$(submit_generation "$prompt" "$seed" "$model") || true

        if [[ "$job_id" == "FAILED" || -z "$job_id" ]]; then
            echo "${seed},FAILED,failed,,,,,,,," >> "${run_dir}/results.csv"
            echo "FAILED"
            failed=$((failed + 1))
        else
            echo "${seed},${job_id},pending,,,,,,,," >> "${run_dir}/results.csv"
            echo "queued (${job_id})"
            submitted=$((submitted + 1))
        fi

        # Rate limiting: small delay between requests
        sleep 1
    done

    echo ""
    print_success "Submitted ${submitted}/${seed_count} jobs (${failed} failed)"
    print_info "Run ID: ${run_id}"
    print_info "Check status: seed-bracket-helper.sh status ${run_id}"
    print_info "Score outputs: seed-bracket-helper.sh score ${run_id} <seed> <comp> <qual> <style> <motion> <acc>"
    return 0
}

# Status: Check job status for a bracket run
cmd_status() {
    local run_id="${1:-}"

    if [[ -z "$run_id" ]]; then
        run_id=$(get_latest_run) || {
            print_error "No bracket runs found. Run 'generate' first."
            return 1
        }
    fi

    load_run_metadata "$run_id" || return 1
    load_credentials || return 1

    local run_dir="${BRACKET_DIR}/${run_id}"

    print_info "Bracket Run: ${run_id}"
    echo "  Content type: ${CONTENT_TYPE}"
    echo "  Seed range:   ${SEED_START}-${SEED_END}"
    echo "  Model:        ${MODEL}"
    echo "  Created:      ${CREATED_AT}"
    echo ""

    # Read results and check each pending job
    local pending=0 completed=0 failed_count=0
    local tmp_results
    tmp_results=$(mktemp)
    trap 'rm -f "${tmp_results:-}"' RETURN

    # Copy header
    head -1 "${run_dir}/results.csv" > "$tmp_results"

    # Process each result line (skip header)
    local line_num=0
    while IFS=',' read -r seed job_id status score_comp score_qual score_style score_motion score_acc total_score result_url; do
        line_num=$((line_num + 1))
        [[ $line_num -eq 1 ]] && continue  # Skip header

        if [[ "$status" == "pending" || "$status" == "processing" ]]; then
            # Check current status
            local status_result
            status_result=$(check_job_status "$job_id")
            local new_status="${status_result%% *}"
            local new_url="${status_result#* }"
            [[ "$new_url" == "$new_status" ]] && new_url=""

            printf "  Seed %s: %s" "$seed" "$new_status"
            if [[ -n "$new_url" ]]; then
                echo " -> ${new_url}"
                echo "${seed},${job_id},completed,${score_comp},${score_qual},${score_style},${score_motion},${score_acc},${total_score},${new_url}" >> "$tmp_results"
                completed=$((completed + 1))
            else
                echo ""
                echo "${seed},${job_id},${new_status},${score_comp},${score_qual},${score_style},${score_motion},${score_acc},${total_score},${result_url}" >> "$tmp_results"
                if [[ "$new_status" == "failed" ]]; then
                    failed_count=$((failed_count + 1))
                else
                    pending=$((pending + 1))
                fi
            fi
        elif [[ "$status" == "completed" ]]; then
            printf "  Seed %s: completed" "$seed"
            [[ -n "$total_score" ]] && printf " (score: %s)" "$total_score"
            echo ""
            echo "${seed},${job_id},${status},${score_comp},${score_qual},${score_style},${score_motion},${score_acc},${total_score},${result_url}" >> "$tmp_results"
            completed=$((completed + 1))
        else
            printf "  Seed %s: %s\n" "$seed" "$status"
            echo "${seed},${job_id},${status},${score_comp},${score_qual},${score_style},${score_motion},${score_acc},${total_score},${result_url}" >> "$tmp_results"
            failed_count=$((failed_count + 1))
        fi
    done < "${run_dir}/results.csv"

    # Update results file
    cp "$tmp_results" "${run_dir}/results.csv"

    echo ""
    echo "  Completed: ${completed} | Pending: ${pending} | Failed: ${failed_count}"

    if [[ $pending -eq 0 && $completed -gt 0 ]]; then
        print_success "All jobs complete. Score outputs with: seed-bracket-helper.sh score ${run_id} <seed> <scores...>"
    fi
    return 0
}

# Score: Score a completed job output
cmd_score() {
    local run_id="${1:-}"
    local seed="${2:-}"
    local score_comp="${3:-}"
    local score_qual="${4:-}"
    local score_style="${5:-}"
    local score_motion="${6:-}"
    local score_acc="${7:-}"

    if [[ -z "$run_id" ]]; then
        run_id=$(get_latest_run) || {
            print_error "No bracket runs found."
            return 1
        }
        # Shift args since run_id was auto-detected
        seed="${1:-}"
        score_comp="${2:-}"
        score_qual="${3:-}"
        score_style="${4:-}"
        score_motion="${5:-}"
        score_acc="${6:-}"
    fi

    if [[ -z "$seed" || -z "$score_comp" || -z "$score_qual" || -z "$score_style" || -z "$score_motion" || -z "$score_acc" ]]; then
        print_error "Usage: score [run_id] <seed> <composition> <quality> <style> <motion> <accuracy>"
        print_info "All scores are 1-10. Example: score 4005 8 9 7 8 9"
        return 1
    fi

    # Validate scores are 1-10
    local score_name score_val
    for score_name in composition quality style motion accuracy; do
        case "$score_name" in
            composition) score_val="$score_comp" ;;
            quality)     score_val="$score_qual" ;;
            style)       score_val="$score_style" ;;
            motion)      score_val="$score_motion" ;;
            accuracy)    score_val="$score_acc" ;;
        esac
        if [[ "$score_val" -lt 1 || "$score_val" -gt 10 ]] 2>/dev/null; then
            print_error "Score for ${score_name} must be 1-10 (got: ${score_val})"
            return 1
        fi
    done

    local run_dir="${BRACKET_DIR}/${run_id}"
    if [[ ! -d "$run_dir" ]]; then
        print_error "Bracket run not found: ${run_id}"
        return 1
    fi

    # Calculate weighted total (out of 100)
    local total
    total=$(( (score_comp * WEIGHT_COMPOSITION + score_qual * WEIGHT_QUALITY + score_style * WEIGHT_STYLE + score_motion * WEIGHT_MOTION + score_acc * WEIGHT_ACCURACY) / 10 ))

    # Update the results CSV for this seed
    local tmp_results
    tmp_results=$(mktemp)
    trap 'rm -f "${tmp_results:-}"' RETURN

    local found=false
    local line_num=0
    while IFS=',' read -r csv_seed csv_job_id csv_status csv_comp csv_qual csv_style csv_motion csv_acc csv_total csv_url; do
        line_num=$((line_num + 1))
        if [[ $line_num -eq 1 ]]; then
            echo "${csv_seed},${csv_job_id},${csv_status},${csv_comp},${csv_qual},${csv_style},${csv_motion},${csv_acc},${csv_total},${csv_url}" >> "$tmp_results"
            continue
        fi

        if [[ "$csv_seed" == "$seed" ]]; then
            echo "${csv_seed},${csv_job_id},scored,${score_comp},${score_qual},${score_style},${score_motion},${score_acc},${total},${csv_url}" >> "$tmp_results"
            found=true
        else
            echo "${csv_seed},${csv_job_id},${csv_status},${csv_comp},${csv_qual},${csv_style},${csv_motion},${csv_acc},${csv_total},${csv_url}" >> "$tmp_results"
        fi
    done < "${run_dir}/results.csv"

    if [[ "$found" != true ]]; then
        print_error "Seed ${seed} not found in run ${run_id}"
        return 1
    fi

    cp "$tmp_results" "${run_dir}/results.csv"

    # Display result
    local rating
    if [[ $total -ge $THRESHOLD_WINNER ]]; then
        rating="${GREEN}WINNER${NC} - Production-ready"
    elif [[ $total -ge $THRESHOLD_ACCEPTABLE ]]; then
        rating="${YELLOW}ACCEPTABLE${NC} - Minor tweaks needed"
    else
        rating="${RED}REJECT${NC} - Try different seed range"
    fi

    print_success "Scored seed ${seed}"
    echo "  Composition: ${score_comp}/10 (weight: ${WEIGHT_COMPOSITION}%)"
    echo "  Quality:     ${score_qual}/10 (weight: ${WEIGHT_QUALITY}%)"
    echo "  Style:       ${score_style}/10 (weight: ${WEIGHT_STYLE}%)"
    echo "  Motion:      ${score_motion}/10 (weight: ${WEIGHT_MOTION}%)"
    echo "  Accuracy:    ${score_acc}/10 (weight: ${WEIGHT_ACCURACY}%)"
    echo ""
    echo -e "  Total: ${total}/100 - ${rating}"
    return 0
}

# Report: Show results and winners from a bracket run
cmd_report() {
    local run_id="${1:-}"

    if [[ -z "$run_id" ]]; then
        run_id=$(get_latest_run) || {
            print_error "No bracket runs found."
            return 1
        }
    fi

    load_run_metadata "$run_id" || return 1

    local run_dir="${BRACKET_DIR}/${run_id}"

    print_info "Bracket Report: ${run_id}"
    echo "  Content type: ${CONTENT_TYPE}"
    echo "  Seed range:   ${SEED_START}-${SEED_END}"
    echo "  Model:        ${MODEL}"
    echo "  Created:      ${CREATED_AT}"
    echo ""

    # Parse results
    local winners="" acceptable="" rejects="" unscored=""
    local total_scored=0

    local line_num=0
    while IFS=',' read -r seed job_id status score_comp score_qual score_style score_motion score_acc total_score result_url; do
        line_num=$((line_num + 1))
        [[ $line_num -eq 1 ]] && continue  # Skip header

        if [[ "$status" == "scored" && -n "$total_score" ]]; then
            total_scored=$((total_scored + 1))
            if [[ "$total_score" -ge $THRESHOLD_WINNER ]]; then
                winners="${winners}  ${GREEN}Seed ${seed}${NC}: ${total_score}/100 (C:${score_comp} Q:${score_qual} S:${score_style} M:${score_motion} A:${score_acc})\n"
            elif [[ "$total_score" -ge $THRESHOLD_ACCEPTABLE ]]; then
                acceptable="${acceptable}  ${YELLOW}Seed ${seed}${NC}: ${total_score}/100 (C:${score_comp} Q:${score_qual} S:${score_style} M:${score_motion} A:${score_acc})\n"
            else
                rejects="${rejects}  ${RED}Seed ${seed}${NC}: ${total_score}/100\n"
            fi
        else
            unscored="${unscored}  Seed ${seed}: ${status}\n"
        fi
    done < "${run_dir}/results.csv"

    if [[ -n "$winners" ]]; then
        echo -e "${GREEN}Winners (${THRESHOLD_WINNER}+/100):${NC}"
        echo -e "$winners"
    fi

    if [[ -n "$acceptable" ]]; then
        echo -e "${YELLOW}Acceptable (${THRESHOLD_ACCEPTABLE}-${THRESHOLD_WINNER}/100):${NC}"
        echo -e "$acceptable"
    fi

    if [[ -n "$rejects" ]]; then
        echo -e "${RED}Rejected (<${THRESHOLD_ACCEPTABLE}/100):${NC}"
        echo -e "$rejects"
    fi

    if [[ -n "$unscored" ]]; then
        echo "Unscored:"
        echo -e "$unscored"
    fi

    echo "Summary: ${total_scored} scored"

    if [[ $total_scored -gt 0 && -z "$winners" ]]; then
        echo ""
        print_info "No winners found. Recommendations:"
        echo "  1. Shift seed range by +/- 100 and test again"
        echo "  2. If still no winners after 2 ranges, revise the prompt"
        echo "  3. Try a different model (e.g., dop-standard vs dop-turbo)"
    fi
    return 0
}

# Presets: List content-type presets
cmd_presets() {
    print_info "Content-Type Presets"
    echo ""
    printf "  %-12s %-12s %-15s %s\n" "TYPE" "SEED RANGE" "DEFAULT MODEL" "DESCRIPTION"
    printf "  %-12s %-12s %-15s %s\n" "----" "----------" "-------------" "-----------"
    printf "  %-12s %-12s %-15s %s\n" "people"    "1000-1999" "dop-turbo"    "Characters, faces, talking heads"
    printf "  %-12s %-12s %-15s %s\n" "action"    "2000-2999" "dop-turbo"    "Movement, sports, dynamic scenes"
    printf "  %-12s %-12s %-15s %s\n" "landscape" "3000-3999" "dop-standard" "Environments, scenery, architecture"
    printf "  %-12s %-12s %-15s %s\n" "product"   "4000-4999" "dop-turbo"    "Objects, demos, product shots"
    printf "  %-12s %-12s %-15s %s\n" "youtube"   "2000-3000" "dop-turbo"    "Hybrid action/people for YouTube"
    echo ""
    print_info "Scoring Weights:"
    echo "  Composition: ${WEIGHT_COMPOSITION}%  (framing, balance, visual hierarchy)"
    echo "  Quality:     ${WEIGHT_QUALITY}%  (resolution, artifacts, smoothness)"
    echo "  Style:       ${WEIGHT_STYLE}%  (matches intended aesthetic)"
    echo "  Motion:      ${WEIGHT_MOTION}%  (natural movement, physics)"
    echo "  Accuracy:    ${WEIGHT_ACCURACY}%  (prompt adherence, details)"
    echo ""
    print_info "Score Thresholds:"
    echo "  ${THRESHOLD_WINNER}+/100:  Production-ready (winner)"
    echo "  ${THRESHOLD_ACCEPTABLE}-${THRESHOLD_WINNER}/100: Acceptable (minor tweaks)"
    echo "  <${THRESHOLD_ACCEPTABLE}/100:  Reject (try different range)"
    return 0
}

# List: Show all bracket runs
cmd_list() {
    if [[ ! -d "$BRACKET_DIR" ]]; then
        print_info "No bracket runs found."
        return 0
    fi

    local runs
    runs=$(ls -1d "${BRACKET_DIR}"/bracket-* 2>/dev/null | sort -r) || true

    if [[ -z "$runs" ]]; then
        print_info "No bracket runs found."
        return 0
    fi

    print_info "Bracket Runs:"
    echo ""
    printf "  %-45s %-12s %-12s %s\n" "RUN ID" "TYPE" "SEEDS" "STATUS"
    printf "  %-45s %-12s %-12s %s\n" "------" "----" "-----" "------"

    local run_dir
    while IFS= read -r run_dir; do
        local run_id
        run_id=$(basename "$run_dir")
        local meta_file="${run_dir}/metadata.sh"

        if [[ -f "$meta_file" ]]; then
            # shellcheck source=/dev/null
            source "$meta_file"
            printf "  %-45s %-12s %-12s %s\n" "$run_id" "${CONTENT_TYPE:-?}" "${SEED_START:-?}-${SEED_END:-?}" "${STATUS:-?}"
        fi
    done <<< "$runs"
    return 0
}

# Help: Show usage information
cmd_help() {
    echo "Seed Bracket Helper - AI Video Generation Seed Testing"
    echo ""
    echo "Usage: $(basename "$0") <command> [options]"
    echo ""
    echo "${HELP_LABEL_COMMANDS}"
    echo "  generate    Submit batch generation jobs with sequential seeds"
    echo "  status      Check job status for a bracket run"
    echo "  score       Score a completed job output (1-10 per criterion)"
    echo "  report      Show results and winners from a bracket run"
    echo "  list        Show all bracket runs"
    echo "  presets     List content-type presets (seed ranges, models)"
    echo "  help        Show this help message"
    echo ""
    echo "Generate Options:"
    echo "  --type <type>     Content type: people|action|landscape|product|youtube"
    echo "  --start <seed>    Starting seed number (default: from type preset)"
    echo "  --end <seed>      Ending seed number (default: start + 10)"
    echo "  --model <model>   Model name (default: from type preset)"
    echo "  --prompt <text>   Prompt text for generation"
    echo "  --file <path>     Load prompt from file"
    echo "  --dry-run         Show what would be submitted without calling API"
    echo ""
    echo "Positional Generate:"
    echo "  $(basename "$0") generate \"prompt text\" 1000 1010 dop-turbo"
    echo ""
    echo "Score Usage:"
    echo "  $(basename "$0") score [run_id] <seed> <composition> <quality> <style> <motion> <accuracy>"
    echo "  All scores are 1-10. Weights: composition 25%, quality 25%, style 20%, motion 20%, accuracy 10%"
    echo ""
    echo "${HELP_LABEL_EXAMPLES}"
    echo "  # Generate 11 product video variants"
    echo "  $(basename "$0") generate --type product --prompt 'Product rotating on white background'"
    echo ""
    echo "  # Check status of latest run"
    echo "  $(basename "$0") status"
    echo ""
    echo "  # Score seed 4005 from latest run"
    echo "  $(basename "$0") score 4005 8 9 7 8 9"
    echo ""
    echo "  # View report with winners"
    echo "  $(basename "$0") report"
    echo ""
    echo "  # Dry run to preview without API calls"
    echo "  $(basename "$0") generate --type youtube --prompt 'Creator talking to camera' --dry-run"
    return 0
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    # Ensure bracket directory exists
    mkdir -p "$BRACKET_DIR" 2>/dev/null || true

    case "$command" in
        generate)  cmd_generate "$@" ;;
        status)    cmd_status "$@" ;;
        score)     cmd_score "$@" ;;
        report)    cmd_report "$@" ;;
        list)      cmd_list "$@" ;;
        presets)   cmd_presets "$@" ;;
        help|--help|-h) cmd_help ;;
        *)
            print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
