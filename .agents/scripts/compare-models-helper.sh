#!/usr/bin/env bash
# shellcheck disable=SC2034

# Compare Models Helper - AI Model Capability Comparison
# Compare pricing, context windows, and capabilities across AI model providers.
#
# Usage: compare-models-helper.sh [command] [options]
#
# Commands:
#   list          List all tracked models
#   compare       Compare specific models side-by-side
#   recommend     Recommend models for a task type
#   pricing       Show pricing table
#   context       Show context window comparison
#   capabilities  Show capability matrix
#   providers     List supported providers
#   discover      Detect available providers and models from local config
#   help          Show this help
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# =============================================================================
# Model Database (embedded reference data)
# =============================================================================
# Format: model_id|provider|display_name|context_window|input_price_per_1m|output_price_per_1m|tier|capabilities|best_for
# Prices in USD per 1M tokens. Last updated: 2025-02-08.
# Sources: Anthropic, OpenAI, Google official pricing pages.

readonly MODEL_DATA="claude-opus-4|Anthropic|Claude Opus 4|200000|15.00|75.00|high|code,reasoning,architecture,vision,tools|Architecture decisions, novel problems, complex multi-step reasoning
claude-sonnet-4|Anthropic|Claude Sonnet 4|200000|3.00|15.00|medium|code,reasoning,vision,tools|Code implementation, review, most development tasks
claude-haiku-3.5|Anthropic|Claude 3.5 Haiku|200000|0.80|4.00|low|code,reasoning,vision,tools|Triage, classification, simple transforms, formatting
gpt-4.1|OpenAI|GPT-4.1|1048576|2.00|8.00|medium|code,reasoning,vision,tools,search|Coding, instruction following, long context
gpt-4.1-mini|OpenAI|GPT-4.1 Mini|1048576|0.40|1.60|low|code,reasoning,vision,tools|Cost-efficient coding and general tasks
gpt-4.1-nano|OpenAI|GPT-4.1 Nano|1048576|0.10|0.40|low|code,reasoning,tools|Fast classification, simple transforms
gpt-4o|OpenAI|GPT-4o|128000|2.50|10.00|medium|code,reasoning,vision,tools,search|General purpose, multimodal
gpt-4o-mini|OpenAI|GPT-4o Mini|128000|0.15|0.60|low|code,reasoning,vision,tools|Budget general purpose
o3|OpenAI|o3|200000|10.00|40.00|high|code,reasoning,math,science,tools|Complex reasoning, math, science
o4-mini|OpenAI|o4-mini|200000|1.10|4.40|medium|code,reasoning,math,tools|Cost-efficient reasoning
gemini-2.5-pro|Google|Gemini 2.5 Pro|1048576|1.25|10.00|medium|code,reasoning,vision,tools|Large context analysis, complex reasoning
gemini-2.5-flash|Google|Gemini 2.5 Flash|1048576|0.15|0.60|low|code,reasoning,vision,tools|Fast, cheap, large context
gemini-2.0-flash|Google|Gemini 2.0 Flash|1048576|0.10|0.40|low|code,reasoning,vision,tools|Budget large context processing
deepseek-r1|DeepSeek|DeepSeek R1|131072|0.55|2.19|low|code,reasoning,math|Deep reasoning, math, open-source
deepseek-v3|DeepSeek|DeepSeek V3|131072|0.27|1.10|low|code,reasoning|General purpose, cost-efficient
llama-4-maverick|Meta|Llama 4 Maverick|1048576|0.20|0.60|low|code,reasoning,vision,tools|Open-source, large context
llama-4-scout|Meta|Llama 4 Scout|512000|0.15|0.40|low|code,reasoning,vision,tools|Open-source, efficient"

# =============================================================================
# aidevops Tier Mapping
# =============================================================================
# Maps aidevops internal tiers to recommended models

readonly TIER_MAP="haiku|claude-haiku-3.5|Triage, classification, simple transforms
flash|gemini-2.5-flash|Large context reads, summarization, bulk processing
sonnet|claude-sonnet-4|Code implementation, review, most development tasks
pro|gemini-2.5-pro|Large codebase analysis, complex reasoning with big context
opus|claude-opus-4|Architecture decisions, complex multi-step reasoning"

# =============================================================================
# Task-to-Model Recommendations
# =============================================================================

readonly TASK_RECOMMENDATIONS="code review|claude-sonnet-4|o4-mini|gemini-2.5-flash
code implementation|claude-sonnet-4|gpt-4.1|gemini-2.5-pro
architecture design|claude-opus-4|o3|gemini-2.5-pro
bug fixing|claude-sonnet-4|gpt-4.1|o4-mini
refactoring|claude-sonnet-4|gpt-4.1|gemini-2.5-pro
documentation|claude-sonnet-4|gpt-4o|gemini-2.5-flash
testing|claude-sonnet-4|gpt-4.1|o4-mini
classification|claude-haiku-3.5|gpt-4.1-nano|gemini-2.5-flash
summarization|gemini-2.5-flash|gpt-4o-mini|claude-haiku-3.5
large codebase analysis|gemini-2.5-pro|gpt-4.1|claude-sonnet-4
math reasoning|o3|deepseek-r1|gemini-2.5-pro
security audit|claude-opus-4|o3|claude-sonnet-4
data extraction|gemini-2.5-flash|gpt-4o-mini|claude-haiku-3.5
commit messages|claude-haiku-3.5|gpt-4.1-nano|gemini-2.5-flash
pr description|claude-sonnet-4|gpt-4o|gemini-2.5-flash"

# =============================================================================
# Helper Functions
# =============================================================================

# Get a field from a model data line
# Usage: get_field "model_line" field_number
get_field() {
    local line="$1"
    local field="$2"
    echo "$line" | cut -d'|' -f"$field"
    return 0
}

# Find model by partial name match
find_model() {
    local query="$1"
    local lower_query
    lower_query=$(echo "$query" | tr '[:upper:]' '[:lower:]')
    echo "$MODEL_DATA" | while IFS= read -r line; do
        local model_id
        model_id=$(get_field "$line" 1)
        local display_name
        display_name=$(get_field "$line" 3)
        local lower_id
        lower_id=$(echo "$model_id" | tr '[:upper:]' '[:lower:]')
        local lower_name
        lower_name=$(echo "$display_name" | tr '[:upper:]' '[:lower:]')
        if [[ "$lower_id" == *"$lower_query"* ]] || [[ "$lower_name" == *"$lower_query"* ]]; then
            echo "$line"
        fi
    done
    return 0
}

# Format number with padding
pad_right() {
    local str="$1"
    local width="$2"
    printf "%-${width}s" "$str"
    return 0
}

# Format price for display
format_price() {
    local price="$1"
    printf "\$%s" "$price"
    return 0
}

# Format context window for display
format_context() {
    local ctx="$1"
    if [[ "$ctx" -ge 1000000 ]]; then
        echo "1M"
    elif [[ "$ctx" -ge 500000 ]]; then
        echo "512K"
    elif [[ "$ctx" -ge 200000 ]]; then
        echo "200K"
    elif [[ "$ctx" -ge 131072 ]]; then
        echo "131K"
    elif [[ "$ctx" -ge 128000 ]]; then
        echo "128K"
    else
        echo "${ctx}"
    fi
    return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_list() {
    echo ""
    echo "Tracked AI Models"
    echo "================="
    echo ""
    printf "%-22s %-10s %-8s %-12s %-12s %-7s %s\n" \
        "Model" "Provider" "Context" "Input/1M" "Output/1M" "Tier" "Best For"
    printf "%-22s %-10s %-8s %-12s %-12s %-7s %s\n" \
        "-----" "--------" "-------" "--------" "---------" "----" "--------"

    echo "$MODEL_DATA" | while IFS= read -r line; do
        local model_id provider display ctx input output tier caps best
        model_id=$(get_field "$line" 1)
        provider=$(get_field "$line" 2)
        ctx=$(get_field "$line" 4)
        input=$(get_field "$line" 5)
        output=$(get_field "$line" 6)
        tier=$(get_field "$line" 7)
        best=$(get_field "$line" 9)
        local ctx_fmt
        ctx_fmt=$(format_context "$ctx")
        # Truncate best_for for table display
        local best_short="${best:0:40}"
        printf "%-22s %-10s %-8s %-12s %-12s %-7s %s\n" \
            "$model_id" "$provider" "$ctx_fmt" "\$$input" "\$$output" "$tier" "$best_short"
    done

    echo ""
    echo "Prices: USD per 1M tokens. Last updated: 2025-02-08."
    echo "Run 'compare-models-helper.sh help' for more commands."
    return 0
}

cmd_compare() {
    local models=("$@")
    if [[ ${#models[@]} -lt 1 ]]; then
        print_error "Usage: compare-models-helper.sh compare <model1> [model2] ..."
        return 1
    fi

    echo ""
    echo "Model Comparison"
    echo "================"
    echo ""

    local found_any=false
    local results=()

    for query in "${models[@]}"; do
        local matches
        matches=$(find_model "$query")
        if [[ -z "$matches" ]]; then
            print_warning "No model found matching: $query"
        else
            while IFS= read -r match; do
                results+=("$match")
                found_any=true
            done <<< "$matches"
        fi
    done

    if [[ "$found_any" != "true" ]]; then
        print_error "No models found. Run 'compare-models-helper.sh list' to see available models."
        return 1
    fi

    printf "%-22s %-10s %-8s %-12s %-12s %-7s\n" \
        "Model" "Provider" "Context" "Input/1M" "Output/1M" "Tier"
    printf "%-22s %-10s %-8s %-12s %-12s %-7s\n" \
        "-----" "--------" "-------" "--------" "---------" "----"

    for line in "${results[@]}"; do
        local model_id provider ctx input output tier
        model_id=$(get_field "$line" 1)
        provider=$(get_field "$line" 2)
        ctx=$(get_field "$line" 4)
        input=$(get_field "$line" 5)
        output=$(get_field "$line" 6)
        tier=$(get_field "$line" 7)
        local ctx_fmt
        ctx_fmt=$(format_context "$ctx")
        printf "%-22s %-10s %-8s %-12s %-12s %-7s\n" \
            "$model_id" "$provider" "$ctx_fmt" "\$$input" "\$$output" "$tier"
    done

    echo ""
    echo "Capabilities:"
    for line in "${results[@]}"; do
        local model_id caps best
        model_id=$(get_field "$line" 1)
        caps=$(get_field "$line" 8)
        best=$(get_field "$line" 9)
        echo "  $model_id: $caps"
        echo "    Best for: $best"
    done

    # Cost comparison
    if [[ ${#results[@]} -ge 2 ]]; then
        echo ""
        echo "Cost Analysis (per 1M tokens):"
        local cheapest_input="" cheapest_input_price=999999
        local cheapest_output="" cheapest_output_price=999999
        for line in "${results[@]}"; do
            local model_id input output
            model_id=$(get_field "$line" 1)
            input=$(get_field "$line" 5)
            output=$(get_field "$line" 6)
            # Use awk for float comparison
            if awk "BEGIN{exit !($input < $cheapest_input_price)}"; then
                cheapest_input="$model_id"
                cheapest_input_price="$input"
            fi
            if awk "BEGIN{exit !($output < $cheapest_output_price)}"; then
                cheapest_output="$model_id"
                cheapest_output_price="$output"
            fi
        done
        echo "  Cheapest input:  $cheapest_input (\$$cheapest_input_price/1M)"
        echo "  Cheapest output: $cheapest_output (\$$cheapest_output_price/1M)"
    fi

    return 0
}

cmd_recommend() {
    local task_desc="$1"
    if [[ -z "$task_desc" ]]; then
        print_error "Usage: compare-models-helper.sh recommend <task description>"
        return 1
    fi

    local lower_task
    lower_task=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]')

    echo ""
    echo "Model Recommendation"
    echo "===================="
    echo "Task: $task_desc"
    echo ""

    local found=false
    while IFS= read -r line; do
        local task_pattern recommended runner_up budget
        task_pattern=$(echo "$line" | cut -d'|' -f1)
        recommended=$(echo "$line" | cut -d'|' -f2)
        runner_up=$(echo "$line" | cut -d'|' -f3)
        budget=$(echo "$line" | cut -d'|' -f4)

        if [[ "$lower_task" == *"$task_pattern"* ]] || [[ "$task_pattern" == *"$lower_task"* ]]; then
            echo "  Recommended: $recommended"
            echo "  Runner-up:   $runner_up"
            echo "  Budget:      $budget"
            echo ""

            # Show pricing for recommended models
            for model in "$recommended" "$runner_up" "$budget"; do
                local match
                match=$(find_model "$model" | head -1)
                if [[ -n "$match" ]]; then
                    local input output ctx
                    input=$(get_field "$match" 5)
                    output=$(get_field "$match" 6)
                    ctx=$(get_field "$match" 4)
                    local ctx_fmt
                    ctx_fmt=$(format_context "$ctx")
                    echo "  $model: \$$input/\$$output per 1M tokens, ${ctx_fmt} context"
                fi
            done
            found=true
        fi
    done <<< "$TASK_RECOMMENDATIONS"

    if [[ "$found" != "true" ]]; then
        echo "No exact task match. Showing general recommendations:"
        echo ""
        echo "  High capability: claude-opus-4 or o3"
        echo "  Balanced:        claude-sonnet-4 or gpt-4.1"
        echo "  Budget:          gemini-2.5-flash or gpt-4.1-nano"
        echo "  Large context:   gemini-2.5-pro or gpt-4.1 (1M tokens)"
        echo ""
        echo "Available task types:"
        echo "$TASK_RECOMMENDATIONS" | cut -d'|' -f1 | while IFS= read -r t; do
            echo "  - $t"
        done
    fi

    return 0
}

cmd_pricing() {
    echo ""
    echo "AI Model Pricing (USD per 1M tokens)"
    echo "====================================="
    echo ""
    echo "Sorted by input price (cheapest first):"
    echo ""
    printf "%-22s %-10s %-12s %-12s %-7s\n" \
        "Model" "Provider" "Input/1M" "Output/1M" "Tier"
    printf "%-22s %-10s %-12s %-12s %-7s\n" \
        "-----" "--------" "--------" "---------" "----"

    echo "$MODEL_DATA" | sort -t'|' -k5 -n | while IFS= read -r line; do
        local model_id provider input output tier
        model_id=$(get_field "$line" 1)
        provider=$(get_field "$line" 2)
        input=$(get_field "$line" 5)
        output=$(get_field "$line" 6)
        tier=$(get_field "$line" 7)
        printf "%-22s %-10s %-12s %-12s %-7s\n" \
            "$model_id" "$provider" "\$$input" "\$$output" "$tier"
    done

    echo ""
    echo "Last updated: 2025-02-08. Run /compare-models for live pricing check."
    return 0
}

cmd_context() {
    echo ""
    echo "Context Window Comparison"
    echo "========================="
    echo ""
    echo "Sorted by context window (largest first):"
    echo ""
    printf "%-22s %-10s %-12s %-12s\n" \
        "Model" "Provider" "Context" "Tokens"
    printf "%-22s %-10s %-12s %-12s\n" \
        "-----" "--------" "-------" "------"

    echo "$MODEL_DATA" | sort -t'|' -k4 -rn | while IFS= read -r line; do
        local model_id provider ctx
        model_id=$(get_field "$line" 1)
        provider=$(get_field "$line" 2)
        ctx=$(get_field "$line" 4)
        local ctx_fmt
        ctx_fmt=$(format_context "$ctx")
        printf "%-22s %-10s %-12s %-12s\n" \
            "$model_id" "$provider" "$ctx_fmt" "$ctx"
    done

    return 0
}

cmd_capabilities() {
    echo ""
    echo "Model Capability Matrix"
    echo "======================="
    echo ""
    printf "%-22s %-5s %-5s %-5s %-5s %-5s %-5s %-5s\n" \
        "Model" "Code" "Reas." "Vis." "Tools" "Math" "Srch." "Arch."
    printf "%-22s %-5s %-5s %-5s %-5s %-5s %-5s %-5s\n" \
        "-----" "----" "-----" "----" "-----" "----" "-----" "-----"

    echo "$MODEL_DATA" | while IFS= read -r line; do
        local model_id caps tier
        model_id=$(get_field "$line" 1)
        caps=$(get_field "$line" 8)
        tier=$(get_field "$line" 7)

        local has_code="--" has_reason="--" has_vision="--" has_tools="--"
        local has_math="--" has_search="--" has_arch="--"

        [[ "$caps" == *"code"* ]] && has_code="Y"
        [[ "$caps" == *"reasoning"* ]] && has_reason="Y"
        [[ "$caps" == *"vision"* ]] && has_vision="Y"
        [[ "$caps" == *"tools"* ]] && has_tools="Y"
        [[ "$caps" == *"math"* ]] && has_math="Y"
        [[ "$caps" == *"search"* ]] && has_search="Y"
        [[ "$caps" == *"architecture"* ]] && has_arch="Y"

        printf "%-22s %-5s %-5s %-5s %-5s %-5s %-5s %-5s\n" \
            "$model_id" "$has_code" "$has_reason" "$has_vision" "$has_tools" \
            "$has_math" "$has_search" "$has_arch"
    done

    echo ""
    echo "Y = supported, -- = not listed"
    echo ""
    echo "aidevops Tier Mapping:"
    echo "$TIER_MAP" | while IFS= read -r line; do
        local tier model purpose
        tier=$(echo "$line" | cut -d'|' -f1)
        model=$(echo "$line" | cut -d'|' -f2)
        purpose=$(echo "$line" | cut -d'|' -f3)
        printf "  %-8s -> %-22s (%s)\n" "$tier" "$model" "$purpose"
    done

    return 0
}

cmd_providers() {
    echo ""
    echo "Supported Providers"
    echo "==================="
    echo ""

    local providers
    providers=$(echo "$MODEL_DATA" | cut -d'|' -f2 | sort -u)

    echo "$providers" | while IFS= read -r provider; do
        local count
        count=$(echo "$MODEL_DATA" | grep -c "|${provider}|")
        echo "  $provider ($count models)"
        echo "$MODEL_DATA" | grep "|${provider}|" | while IFS= read -r line; do
            local model_id tier
            model_id=$(get_field "$line" 1)
            tier=$(get_field "$line" 7)
            echo "    - $model_id ($tier)"
        done
        echo ""
    done

    return 0
}

cmd_help() {
    echo ""
    echo "Compare Models Helper - AI Model Capability Comparison"
    echo "======================================================="
    echo ""
    echo "Usage: compare-models-helper.sh [command] [options]"
    echo ""
    echo "Commands:"
    echo "  list          List all tracked models with pricing"
    echo "  compare       Compare specific models side-by-side"
    echo "  recommend     Recommend models for a task type"
    echo "  pricing       Show pricing table (sorted by cost)"
    echo "  context       Show context window comparison"
    echo "  capabilities  Show capability matrix"
    echo "  providers     List supported providers and their models"
    echo "  discover      Detect available providers from local config"
    echo "  help          Show this help"
    echo ""
    echo "Examples:"
    echo "  compare-models-helper.sh list"
    echo "  compare-models-helper.sh compare sonnet gpt-4o gemini-pro"
    echo "  compare-models-helper.sh recommend \"code review\""
    echo "  compare-models-helper.sh pricing"
    echo "  compare-models-helper.sh capabilities"
    echo "  compare-models-helper.sh discover"
    echo "  compare-models-helper.sh discover --probe"
    echo "  compare-models-helper.sh discover --list-models"
    echo "  compare-models-helper.sh discover --json"
    echo ""
    echo "Discover options:"
    echo "  --probe        Verify API keys by calling provider endpoints"
    echo "  --list-models  List live models from each verified provider"
    echo "  --json         Output discovery results as JSON"
    echo ""
    echo "Data is embedded in this script. Last updated: 2025-02-08."
    echo "For live pricing, use /compare-models (with web fetch)."
    return 0
}

# =============================================================================
# Provider API Key Detection
# =============================================================================
# Maps provider names to their environment variable names.
# NEVER prints actual key values — only checks existence.

readonly PROVIDER_ENV_KEYS="Anthropic|ANTHROPIC_API_KEY
OpenAI|OPENAI_API_KEY
Google|GOOGLE_API_KEY,GEMINI_API_KEY
OpenRouter|OPENROUTER_API_KEY
Groq|GROQ_API_KEY
DeepSeek|DEEPSEEK_API_KEY
Together|TOGETHER_API_KEY
Fireworks|FIREWORKS_API_KEY"

# Check if a provider API key is available from any source
# Returns 0 if found, 1 if not. Sets FOUND_SOURCE to the source name.
# Usage: check_provider_key "ANTHROPIC_API_KEY"
check_provider_key() {
    local key_name="$1"
    FOUND_SOURCE=""

    # 1. Check environment variable
    if [[ -n "${!key_name:-}" ]]; then
        FOUND_SOURCE="env"
        return 0
    fi

    # 2. Check gopass (encrypted secrets)
    if command -v gopass &>/dev/null; then
        if gopass ls "aidevops/${key_name}" &>/dev/null 2>&1; then
            FOUND_SOURCE="gopass"
            return 0
        fi
    fi

    # 3. Check credentials.sh (plaintext fallback)
    local creds_file="${HOME}/.config/aidevops/credentials.sh"
    if [[ -f "$creds_file" ]]; then
        if grep -q "^export ${key_name}=" "$creds_file" 2>/dev/null || \
           grep -q "^${key_name}=" "$creds_file" 2>/dev/null; then
            FOUND_SOURCE="credentials.sh"
            return 0
        fi
    fi

    return 1
}

# Probe a provider API to verify the key works
# Returns 0 if API responds successfully, 1 otherwise
# Usage: probe_provider "Anthropic" "ANTHROPIC_API_KEY"
probe_provider() {
    local provider="$1"
    local key_name="$2"

    # Get the key value from the appropriate source
    local key_value=""
    if [[ -n "${!key_name:-}" ]]; then
        key_value="${!key_name}"
    elif command -v gopass &>/dev/null && gopass ls "aidevops/${key_name}" &>/dev/null 2>&1; then
        key_value=$(gopass show "aidevops/${key_name}" 2>/dev/null) || return 1
    else
        return 1
    fi

    [[ -z "$key_value" ]] && return 1

    local http_code=""
    case "$provider" in
        Anthropic)
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "x-api-key: ${key_value}" \
                -H "anthropic-version: 2023-06-01" \
                "https://api.anthropic.com/v1/models" 2>/dev/null) || return 1
            ;;
        OpenAI)
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "Authorization: Bearer ${key_value}" \
                "https://api.openai.com/v1/models" 2>/dev/null) || return 1
            ;;
        Google)
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                "https://generativelanguage.googleapis.com/v1beta/models?key=${key_value}" 2>/dev/null) || return 1
            ;;
        OpenRouter)
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "Authorization: Bearer ${key_value}" \
                "https://openrouter.ai/api/v1/models" 2>/dev/null) || return 1
            ;;
        Groq)
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "Authorization: Bearer ${key_value}" \
                "https://api.groq.com/openai/v1/models" 2>/dev/null) || return 1
            ;;
        DeepSeek)
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "Authorization: Bearer ${key_value}" \
                "https://api.deepseek.com/v1/models" 2>/dev/null) || return 1
            ;;
        *)
            return 1
            ;;
    esac

    [[ "$http_code" == "200" ]] && return 0
    return 1
}

# List models available from a provider API
# Outputs model IDs, one per line
# Usage: list_provider_models "Anthropic" "ANTHROPIC_API_KEY"
list_provider_models() {
    local provider="$1"
    local key_name="$2"

    local key_value=""
    if [[ -n "${!key_name:-}" ]]; then
        key_value="${!key_name}"
    elif command -v gopass &>/dev/null && gopass ls "aidevops/${key_name}" &>/dev/null 2>&1; then
        key_value=$(gopass show "aidevops/${key_name}" 2>/dev/null) || return 1
    else
        return 1
    fi

    [[ -z "$key_value" ]] && return 1

    case "$provider" in
        Anthropic)
            curl -s -H "x-api-key: ${key_value}" \
                -H "anthropic-version: 2023-06-01" \
                "https://api.anthropic.com/v1/models" 2>/dev/null | \
                jq -r '.data[].id // empty' 2>/dev/null | sort
            ;;
        OpenAI)
            curl -s -H "Authorization: Bearer ${key_value}" \
                "https://api.openai.com/v1/models" 2>/dev/null | \
                jq -r '.data[].id // empty' 2>/dev/null | sort
            ;;
        Google)
            curl -s "https://generativelanguage.googleapis.com/v1beta/models?key=${key_value}" 2>/dev/null | \
                jq -r '.models[].name // empty' 2>/dev/null | sed 's|^models/||' | sort
            ;;
        OpenRouter)
            curl -s -H "Authorization: Bearer ${key_value}" \
                "https://openrouter.ai/api/v1/models" 2>/dev/null | \
                jq -r '.data[].id // empty' 2>/dev/null | sort
            ;;
        Groq)
            curl -s -H "Authorization: Bearer ${key_value}" \
                "https://api.groq.com/openai/v1/models" 2>/dev/null | \
                jq -r '.data[].id // empty' 2>/dev/null | sort
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

cmd_discover() {
    local probe_flag=false
    local list_flag=false
    local json_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --probe) probe_flag=true; shift ;;
            --list-models) list_flag=true; probe_flag=true; shift ;;
            --json) json_flag=true; shift ;;
            *) shift ;;
        esac
    done

    echo ""
    echo "Model Provider Discovery"
    echo "========================"
    echo ""

    local total_providers=0
    local available_providers=0
    local available_models=0
    local json_entries=()

    while IFS= read -r line; do
        local provider key_names
        provider=$(echo "$line" | cut -d'|' -f1)
        key_names=$(echo "$line" | cut -d'|' -f2)

        total_providers=$((total_providers + 1))
        local found=false
        local source=""
        local active_key=""

        # Check each possible key name for this provider
        IFS=',' read -ra keys <<< "$key_names"
        for key_name in "${keys[@]}"; do
            if check_provider_key "$key_name"; then
                found=true
                source="$FOUND_SOURCE"
                active_key="$key_name"
                break
            fi
        done

        if [[ "$found" == "true" ]]; then
            available_providers=$((available_providers + 1))
            local status="configured"
            local status_icon="Y"

            # Optionally probe the API
            if [[ "$probe_flag" == "true" ]]; then
                if probe_provider "$provider" "$active_key"; then
                    status="verified"
                    status_icon="V"
                else
                    status="key-invalid"
                    status_icon="!"
                fi
            fi

            # Count models from embedded database for this provider
            local model_count
            model_count=$(echo "$MODEL_DATA" | grep -c "|${provider}|" || true)
            available_models=$((available_models + model_count))

            if [[ "$json_flag" == "true" ]]; then
                json_entries+=("{\"provider\":\"${provider}\",\"status\":\"${status}\",\"source\":\"${source}\",\"models\":${model_count}}")
            else
                printf "  %s %-12s  %-12s  (source: %s, %d tracked models)\n" \
                    "$status_icon" "$provider" "$status" "$source" "$model_count"
            fi

            # Optionally list live models from API
            if [[ "$list_flag" == "true" && "$status" == "verified" ]]; then
                local live_models
                live_models=$(list_provider_models "$provider" "$active_key" 2>/dev/null)
                if [[ -n "$live_models" ]]; then
                    local live_count
                    live_count=$(echo "$live_models" | wc -l | tr -d ' ')
                    echo "    Live models ($live_count):"
                    echo "$live_models" | head -20 | while IFS= read -r m; do
                        echo "      - $m"
                    done
                    local remaining=$((live_count - 20))
                    if [[ "$remaining" -gt 0 ]]; then
                        echo "      ... and $remaining more"
                    fi
                fi
            fi
        else
            if [[ "$json_flag" == "true" ]]; then
                json_entries+=("{\"provider\":\"${provider}\",\"status\":\"not-configured\",\"source\":null,\"models\":0}")
            else
                printf "  - %-12s  not configured\n" "$provider"
            fi
        fi
    done <<< "$PROVIDER_ENV_KEYS"

    if [[ "$json_flag" == "true" ]]; then
        echo "[$(IFS=,; echo "${json_entries[*]}")]"
    else
        echo ""
        echo "Summary: $available_providers/$total_providers providers configured, $available_models tracked models available"
        echo ""

        if [[ "$probe_flag" != "true" ]]; then
            echo "Tip: Use --probe to verify API keys are valid"
            echo "     Use --list-models to enumerate live models from each provider"
        fi

        # Show models grouped by availability
        echo ""
        echo "Available Models (from configured providers):"
        echo ""
        printf "  %-22s %-10s %-8s %-12s %-12s %-7s\n" \
            "Model" "Provider" "Context" "Input/1M" "Output/1M" "Tier"
        printf "  %-22s %-10s %-8s %-12s %-12s %-7s\n" \
            "-----" "--------" "-------" "--------" "---------" "----"

        echo "$MODEL_DATA" | while IFS= read -r model_line; do
            local model_provider
            model_provider=$(get_field "$model_line" 2)

            # Check if this provider is available
            local provider_available=false
            while IFS= read -r pline; do
                local pname pkeys
                pname=$(echo "$pline" | cut -d'|' -f1)
                pkeys=$(echo "$pline" | cut -d'|' -f2)
                if [[ "$pname" == "$model_provider" ]]; then
                    IFS=',' read -ra pkey_arr <<< "$pkeys"
                    for pk in "${pkey_arr[@]}"; do
                        if check_provider_key "$pk"; then
                            provider_available=true
                            break
                        fi
                    done
                    break
                fi
            done <<< "$PROVIDER_ENV_KEYS"

            if [[ "$provider_available" == "true" ]]; then
                local mid mctx minput moutput mtier
                mid=$(get_field "$model_line" 1)
                mctx=$(get_field "$model_line" 4)
                minput=$(get_field "$model_line" 5)
                moutput=$(get_field "$model_line" 6)
                mtier=$(get_field "$model_line" 7)
                local ctx_fmt
                ctx_fmt=$(format_context "$mctx")
                printf "  %-22s %-10s %-8s %-12s %-12s %-7s\n" \
                    "$mid" "$model_provider" "$ctx_fmt" "\$$minput" "\$$moutput" "$mtier"
            fi
        done

        echo ""
        echo "Unavailable Models (provider not configured):"
        echo ""

        local has_unavailable=false
        echo "$MODEL_DATA" | while IFS= read -r model_line; do
            local model_provider
            model_provider=$(get_field "$model_line" 2)

            local provider_available=false
            while IFS= read -r pline; do
                local pname pkeys
                pname=$(echo "$pline" | cut -d'|' -f1)
                pkeys=$(echo "$pline" | cut -d'|' -f2)
                if [[ "$pname" == "$model_provider" ]]; then
                    IFS=',' read -ra pkey_arr <<< "$pkeys"
                    for pk in "${pkey_arr[@]}"; do
                        if check_provider_key "$pk"; then
                            provider_available=true
                            break
                        fi
                    done
                    break
                fi
            done <<< "$PROVIDER_ENV_KEYS"

            if [[ "$provider_available" != "true" ]]; then
                local mid
                mid=$(get_field "$model_line" 1)
                echo "  - $mid ($model_provider)"
            fi
        done
    fi

    echo ""
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        list)
            cmd_list
            ;;
        compare)
            cmd_compare "$@"
            ;;
        recommend)
            cmd_recommend "${*:-}"
            ;;
        pricing)
            cmd_pricing
            ;;
        context)
            cmd_context
            ;;
        capabilities)
            cmd_capabilities
            ;;
        providers)
            cmd_providers
            ;;
        discover)
            cmd_discover "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            print_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
    return $?
}

main "$@"
