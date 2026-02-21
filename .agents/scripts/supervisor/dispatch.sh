#!/usr/bin/env bash
# dispatch.sh - Task dispatch and model resolution functions
#
# Functions for dispatching tasks to workers, resolving models,
# quality gates, and building dispatch commands

#######################################
# Detect terminal environment for dispatch mode
# Returns: "tabby", "headless", or "interactive"
#######################################
detect_dispatch_mode() {
	if [[ "${SUPERVISOR_DISPATCH_MODE:-}" == "headless" ]]; then
		echo "headless"
		return 0
	fi
	if [[ "${SUPERVISOR_DISPATCH_MODE:-}" == "tabby" ]]; then
		echo "tabby"
		return 0
	fi
	if [[ "${TERM_PROGRAM:-}" == "Tabby" ]]; then
		echo "tabby"
		return 0
	fi
	echo "headless"
	return 0
}

#######################################
# Detect if claude CLI has OAuth authentication (t1163)
#
# Claude Code CLI can authenticate via OAuth (subscription/Max plan) without
# needing ANTHROPIC_API_KEY. This makes it zero marginal cost for Anthropic
# models when a subscription is active.
#
# Detection strategy:
#   1. Check claude CLI exists in PATH
#   2. Check for OAuth credential indicators:
#      a. ~/.claude/credentials.json or ~/.claude/.credentials (stored tokens)
#      b. System keychain entries (macOS Keychain, Linux secret-service)
#      c. claude -p probe succeeds without ANTHROPIC_API_KEY set
#   3. Cache result for 5 minutes (file-based)
#
# Returns: 0 if OAuth available, 1 if not
# Outputs: "oauth" on stdout if available, empty otherwise
#######################################
detect_claude_oauth() {
	# Fast path: check cache
	local cache_dir="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}/health"
	mkdir -p "$cache_dir" 2>/dev/null || true
	local cache_file="$cache_dir/claude-oauth"

	if [[ -f "$cache_file" ]]; then
		local cached_at cached_result
		IFS='|' read -r cached_at cached_result <"$cache_file" 2>/dev/null || true
		local now
		now=$(date +%s 2>/dev/null) || now=0
		local age=$((now - ${cached_at:-0}))
		if [[ "$age" -lt 300 ]]; then
			if [[ "$cached_result" == "oauth" ]]; then
				echo "oauth"
				return 0
			fi
			return 1
		fi
	fi

	# Check 1: claude CLI must exist
	if ! command -v claude &>/dev/null; then
		echo "$(date +%s)|none" >"$cache_file" 2>/dev/null || true
		return 1
	fi

	# Check 2: Look for OAuth credential indicators
	# Claude Code stores OAuth tokens in its internal state directory
	# The presence of settings.json with oauthAccount or the credentials
	# being managed by the app indicates OAuth is configured
	local has_oauth_indicator=false

	# Check for Claude Code's internal auth state
	# Claude Code v2+ stores auth in ~/.claude/ directory
	local claude_dir="${HOME}/.claude"
	if [[ -d "$claude_dir" ]]; then
		# Check settings.json for OAuth account indicators
		if [[ -f "$claude_dir/settings.json" ]]; then
			# If settings exist and claude is installed, it likely has OAuth
			# (Claude Code requires login on first use — no API key mode by default)
			has_oauth_indicator=true
		fi
		# Check for explicit credential files
		if [[ -f "$claude_dir/credentials.json" ]] || [[ -f "$claude_dir/.credentials" ]]; then
			has_oauth_indicator=true
		fi
	fi

	# Check 3: If no file indicators, try a lightweight probe
	# Only if ANTHROPIC_API_KEY is NOT set (to confirm OAuth works independently)
	if [[ "$has_oauth_indicator" == false ]]; then
		echo "$(date +%s)|none" >"$cache_file" 2>/dev/null || true
		return 1
	fi

	# Verify OAuth actually works by checking claude can start without API key
	# Use --version as a lightweight check (doesn't need auth)
	# The real test is whether -p mode works, but that's expensive
	# Trust the file indicators + CLI presence as sufficient signal
	echo "$(date +%s)|oauth" >"$cache_file" 2>/dev/null || true
	echo "oauth"
	return 0
}

#######################################
# Resolve the AI CLI tool to use for dispatch (t1163: OAuth-aware routing)
#
# Routing priority:
#   1. SUPERVISOR_CLI env var override (explicit preference)
#   2. OAuth-aware routing (when SUPERVISOR_PREFER_OAUTH=true, default):
#      - For Anthropic models: prefer claude CLI if OAuth available (subscription = zero cost)
#      - For non-Anthropic models: use opencode (multi-provider support)
#   3. opencode as primary CLI
#   4. claude as fallback
#
# Args:
#   $1 (optional): resolved model string (e.g., "anthropic/claude-opus-4-6")
#                  Used for OAuth routing decisions. If empty, defaults to opencode.
#
# Env vars:
#   SUPERVISOR_CLI          — explicit CLI override (opencode|claude)
#   SUPERVISOR_PREFER_OAUTH — prefer claude OAuth for Anthropic models (default: true)
#######################################
resolve_ai_cli() {
	local resolved_model="${1:-}"

	# Allow env var override for explicit CLI preference
	if [[ -n "${SUPERVISOR_CLI:-}" ]]; then
		if [[ "$SUPERVISOR_CLI" != "opencode" && "$SUPERVISOR_CLI" != "claude" ]]; then
			log_error "SUPERVISOR_CLI='$SUPERVISOR_CLI' is not a supported CLI (opencode|claude)"
			return 1
		fi
		if command -v "$SUPERVISOR_CLI" &>/dev/null; then
			echo "$SUPERVISOR_CLI"
			return 0
		fi
		log_error "SUPERVISOR_CLI='$SUPERVISOR_CLI' not found in PATH"
		return 1
	fi

	# OAuth-aware routing (t1163): prefer claude CLI for Anthropic models
	# when OAuth is available (subscription = zero marginal cost)
	local prefer_oauth="${SUPERVISOR_PREFER_OAUTH:-true}"
	if [[ "$prefer_oauth" == "true" ]]; then
		# Determine if the target model is Anthropic
		local is_anthropic=false
		if [[ -z "$resolved_model" || "$resolved_model" == anthropic/* || "$resolved_model" == *claude* ]]; then
			is_anthropic=true
		fi

		if [[ "$is_anthropic" == true ]]; then
			local oauth_status=""
			oauth_status=$(detect_claude_oauth 2>/dev/null) || true
			if [[ "$oauth_status" == "oauth" ]]; then
				if command -v claude &>/dev/null; then
					log_info "OAuth-aware routing: using claude CLI for Anthropic model (subscription, zero marginal cost) (t1163)"
					echo "claude"
					return 0
				fi
			fi
		fi
	fi

	# opencode is the primary CLI for all other cases
	if command -v opencode &>/dev/null; then
		echo "opencode"
		return 0
	fi
	# Fallback: claude CLI without OAuth preference
	if command -v claude &>/dev/null; then
		log_warning "Using claude CLI fallback (no opencode). Install opencode: npm i -g opencode"
		echo "claude"
		return 0
	fi
	log_error "No supported AI CLI found. Install opencode: npm i -g opencode"
	log_error "See: https://opencode.ai/docs/installation/"
	return 1
}

#######################################
# Resolve the best available model for a given task tier
# Uses fallback-chain-helper.sh (t132.4) for configurable multi-provider
# fallback chains with gateway support, falling back to
# model-availability-helper.sh (t132.3) for simple primary/fallback,
# then static defaults.
#
# Tiers:
#   coding  - Best SOTA model for code tasks (default)
#   eval    - Cheap/fast model for evaluation calls
#   health  - Cheapest model for health probes
#######################################
resolve_model() {
	local tier="${1:-coding}"
	local ai_cli="${2:-opencode}"

	# Allow env var override for all tiers
	if [[ -n "${SUPERVISOR_MODEL:-}" ]]; then
		echo "$SUPERVISOR_MODEL"
		return 0
	fi

	# If tier is already a full provider/model string (contains /), return as-is
	if [[ "$tier" == *"/"* ]]; then
		echo "$tier"
		return 0
	fi

	# Try fallback-chain-helper.sh for full chain resolution (t132.4)
	# This walks the configured chain including gateway providers
	local chain_helper="${SCRIPT_DIR}/fallback-chain-helper.sh"
	if [[ -x "$chain_helper" ]]; then
		local resolved
		resolved=$("$chain_helper" resolve "$tier" --quiet 2>/dev/null) || true
		if [[ -n "$resolved" ]]; then
			echo "$resolved"
			return 0
		fi
		log_verbose "fallback-chain-helper.sh could not resolve tier '$tier', trying availability helper"
	fi

	# Try model-availability-helper.sh for availability-aware resolution (t132.3)
	# IMPORTANT: When using OpenCode CLI with Anthropic OAuth, the availability
	# helper sees anthropic as "no-key" (no standalone ANTHROPIC_API_KEY) and
	# resolves to opencode/* models that route through OpenCode's Zen proxy.
	# Only accept anthropic/* results to enforce Anthropic-only routing.
	local availability_helper="${SCRIPT_DIR}/model-availability-helper.sh"
	if [[ -x "$availability_helper" ]]; then
		local resolved
		resolved=$("$availability_helper" resolve "$tier" --quiet 2>/dev/null) || true
		if [[ -n "$resolved" && "$resolved" == anthropic/* ]]; then
			echo "$resolved"
			return 0
		fi
		# Fallback: availability helper returned non-anthropic or empty, use static defaults
		log_verbose "model-availability-helper.sh resolved '$resolved' (non-anthropic or empty), using static default"
	fi

	# Static fallback: map tier names to concrete models (t132.5)
	case "$tier" in
	opus | coding)
		echo "anthropic/claude-opus-4-6"
		;;
	sonnet | eval | health)
		echo "anthropic/claude-sonnet-4-6"
		;;
	haiku | flash)
		echo "anthropic/claude-haiku-4-5"
		;;
	pro)
		echo "anthropic/claude-sonnet-4-6"
		;;
	*)
		# Unknown tier — treat as coding tier default
		echo "anthropic/claude-opus-4-6"
		;;
	esac

	return 0
}

#######################################
# Read model: field from subagent YAML frontmatter (t132.5)
# Searches deployed agents dir and repo .agents/ dir
# Returns the model value or empty string if not found
#######################################
resolve_model_from_frontmatter() {
	local subagent_name="$1"
	local repo="${2:-.}"

	# Search paths for subagent files
	local -a search_paths=(
		"${HOME}/.aidevops/agents"
		"${repo}/.agents"
	)

	local agents_dir subagent_file model_value
	for agents_dir in "${search_paths[@]}"; do
		[[ -d "$agents_dir" ]] || continue

		# Try exact path first (e.g., "tools/ai-assistants/models/opus.md")
		subagent_file="${agents_dir}/${subagent_name}"
		[[ -f "$subagent_file" ]] || subagent_file="${agents_dir}/${subagent_name}.md"

		if [[ -f "$subagent_file" ]]; then
			# Extract model: from YAML frontmatter (between --- delimiters)
			model_value=$(sed -n '/^---$/,/^---$/{ /^model:/{ s/^model:[[:space:]]*//; p; q; } }' "$subagent_file" 2>/dev/null) || true
			if [[ -n "$model_value" ]]; then
				echo "$model_value"
				return 0
			fi
		fi

		# Try finding by name in subdirectories
		# shellcheck disable=SC2044
		local found_file
		found_file=$(find "$agents_dir" -name "${subagent_name}.md" -type f 2>/dev/null | head -1) || true
		if [[ -n "$found_file" && -f "$found_file" ]]; then
			model_value=$(sed -n '/^---$/,/^---$/{ /^model:/{ s/^model:[[:space:]]*//; p; q; } }' "$found_file" 2>/dev/null) || true
			if [[ -n "$model_value" ]]; then
				echo "$model_value"
				return 0
			fi
		fi
	done

	return 1
}

#######################################
# Classify task complexity for model routing (t132.5, t246)
# Returns a tier name: haiku, sonnet, or opus.
#
# Tier heuristics (aligned with model-routing.md decision flowchart):
#   haiku  — trivial: rename, reformat, classify, triage, commit messages,
#            simple text transforms, tag/label operations
#   sonnet — simple-to-moderate: docs updates, config changes, cross-refs,
#            adding comments, updating references, writing tests, bug fixes,
#            simple script additions, markdown changes
#   opus   — complex: architecture, novel features, multi-file refactors,
#            security audits, system design, anything requiring deep reasoning
#
# Accepts optional $2 for TODO.md tags (e.g., "#docs #optimization") to
# provide additional routing hints when description alone is ambiguous.
#######################################
classify_task_complexity() {
	local description="$1"
	local tags="${2:-}"
	local desc_lower
	desc_lower=$(echo "$description" | tr '[:upper:]' '[:lower:]')
	local tags_lower
	tags_lower=$(echo "$tags" | tr '[:upper:]' '[:lower:]')

	# --- Tag-based hints (highest priority when present) ---
	# Tags are explicit human intent — trust them over keyword matching
	if [[ "$tags_lower" == *"#trivial"* ]]; then
		echo "haiku"
		return 0
	fi
	if [[ "$tags_lower" == *"#simple"* || "$tags_lower" == *"#docs"* ]]; then
		echo "sonnet"
		return 0
	fi
	if [[ "$tags_lower" == *"#complex"* || "$tags_lower" == *"#architecture"* ]]; then
		echo "opus"
		return 0
	fi

	# --- Pre-check: disambiguate patterns that match both sonnet and opus ---
	# "extract modules" matches sonnet "extract.*function" when description also
	# mentions functions. Check for module-level operations first (opus-tier).
	if [[ "$desc_lower" =~ module && ("$desc_lower" =~ extract || "$desc_lower" =~ move.*into) ]]; then
		echo "opus"
		return 0
	fi

	# --- Haiku tier: trivial mechanical tasks (no reasoning needed) ---
	# Aligned with model-registry-helper.sh route patterns
	local haiku_patterns=(
		"^rename "
		"rename.*variable"
		"rename.*function"
		"rename.*file"
		"reformat"
		"re-format"
		"classify"
		"triage"
		"commit.message"
		"simple.*(text|transform)"
		"extract.field"
		"sort.*list"
		"prioriti[sz]e"
		"tag.*label"
		"label.*tag"
		"fix.*whitespace"
		"fix.*indent"
		"remove.*unused.*import"
		"update.*copyright"
	)

	for pattern in "${haiku_patterns[@]}"; do
		if [[ "$desc_lower" =~ $pattern ]]; then
			echo "haiku"
			return 0
		fi
	done

	# --- Sonnet tier: simple-to-moderate dev tasks ---
	# Standard work that doesn't require deep architectural reasoning
	local sonnet_patterns=(
		"update.*readme"
		"update.*docs"
		"update.*documentation"
		"add.*comment"
		"add.*reference"
		"update.*reference"
		"fix.*typo"
		"update.*version"
		"bump.*version"
		"update.*changelog"
		"add.*to.*index"
		"update.*index"
		"wire.*up.*command"
		"add.*slash.*command"
		"update.*agents\.md"
		"progressive.*disclosure"
		"cross-reference"
		"add.*test"
		"write.*test"
		"unit.*test"
		"fix.*bug"
		"fix.*error"
		"fix.*issue"
		"bugfix"
		"hotfix"
		"update.*config"
		"update.*setting"
		"add.*flag"
		"add.*option"
		"add.*parameter"
		"update.*script"
		"add.*helper"
		"add.*logging"
		"add.*validation"
		"improve.*error.*message"
		"update.*template"
		"markdown.*change"
		"update.*markdown"
		"add.*entry"
		"add.*section"
		"move.*file"
		"move.*function"
		"extract.*function"
		"inline.*function"
		"add.*env.*var"
		"update.*env"
		"clean.*up"
		"remove.*deprecated"
		"update.*dependency"
		"upgrade.*dependency"
	)

	for pattern in "${sonnet_patterns[@]}"; do
		if [[ "$desc_lower" =~ $pattern ]]; then
			echo "sonnet"
			return 0
		fi
	done

	# --- Opus tier: complex tasks requiring deep reasoning ---
	local opus_patterns=(
		"architect"
		"design.*system"
		"system.*design"
		"security.*audit"
		"refactor.*major"
		"major.*refactor"
		"migration"
		"novel"
		"from.*scratch"
		"implement.*new.*system"
		"multi.*provider"
		"cross.*model"
		"quality.*gate"
		"fallback.*chain"
		"trade.?off"
		"evaluat.*option"
		"evaluat.*approach"
		"complex.*(plan|design|decision)"
		"implement.*new.*(framework|engine|pipeline|protocol)"
		"redesign"
		"state.*machine"
		"concurren"
		"parallel.*processing"
		"distributed"
		"consensus"
		"orchestrat"
		"pre.commit.*hook"
		"ci.*check"
		"ci.*workflow"
		"github.*action"
		"edge.*case"
		"enforce"
		"guard"
		"wire.*into"
		"end.to.end"
		"multi.file"
		"modular"
		"extract.*module"
		"supervisor"
		"parse.*diff"
		"parse.*staged"
	)

	for pattern in "${opus_patterns[@]}"; do
		if [[ "$desc_lower" =~ $pattern ]]; then
			echo "opus"
			return 0
		fi
	done

	# Default: opus for safety (complex tasks fail on weaker models,
	# but the quality gate can escalate haiku/sonnet tasks if needed)
	echo "opus"
	return 0
}

#######################################
# Resolve the model for a task (t132.5, t246, t1011, t1100, t1149)
# Priority: 0) Contest mode (model:contest) — dispatch to top-3 models (t1011)
#           1) Task's explicit model (if not default) — from --model or model: in TODO.md
#           2) Subagent frontmatter model:
#           3) Pattern-tracker recommendation (data-driven, requires 3+ samples, ≥75% success)
#           4) Task complexity classification (auto-route from description + tags)
#           4.5) Cost-efficiency check (t1149): if classify returned opus but pattern data
#                shows sonnet ≥80% success for this task type, downgrade to sonnet
#           4.7) Budget-aware tier adjustment (t1100) — degrade if approaching budget cap
#           5) resolve_model() with tier/fallback chain
# Returns the resolved provider/model string (or "CONTEST" for contest mode)
#######################################
resolve_task_model() {
	local task_id="$1"
	local task_model="${2:-}"
	local task_repo="${3:-.}"
	local ai_cli="${4:-opencode}"

	local default_model="anthropic/claude-opus-4-6"

	# 0) Contest mode detection (t1011)
	# If task has explicit model:contest, signal the caller to use contest dispatch
	if [[ "$task_model" == "contest" ]]; then
		log_info "Model for $task_id: CONTEST mode (explicit model:contest)"
		echo "CONTEST"
		return 0
	fi

	# 1) If task has an explicit non-default model, use it
	if [[ -n "$task_model" && "$task_model" != "$default_model" ]]; then
		# Could be a tier name or full model string — resolve_model handles both
		local resolved
		resolved=$(resolve_model "$task_model" "$ai_cli")
		if [[ -n "$resolved" ]]; then
			log_info "Model for $task_id: $resolved (from task config)"
			echo "$resolved"
			return 0
		fi
	fi

	# 2) Try to find a model-specific subagent definition matching the task
	#    Look for tools/ai-assistants/models/*.md files that match the task's
	#    model tier or the task description keywords
	local model_agents_dir="${HOME}/.aidevops/agents/tools/ai-assistants/models"
	if [[ -d "$model_agents_dir" ]]; then
		# If task_model is a tier name, check for a matching model agent
		if [[ -n "$task_model" && ! "$task_model" == *"/"* ]]; then
			local tier_agent="${model_agents_dir}/${task_model}.md"
			if [[ -f "$tier_agent" ]]; then
				local frontmatter_model
				frontmatter_model=$(resolve_model_from_frontmatter "tools/ai-assistants/models/${task_model}" "$task_repo") || true
				if [[ -n "$frontmatter_model" ]]; then
					local resolved
					resolved=$(resolve_model "$frontmatter_model" "$ai_cli")
					log_info "Model for $task_id: $resolved (from subagent frontmatter: ${task_model}.md)"
					echo "$resolved"
					return 0
				fi
			fi
		fi
	fi

	# Fetch task description for classification (used by steps 3 and 4)
	local task_desc
	task_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")

	# Derive task type from tags/description — used by steps 3 and 4.5 (t1149)
	local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
	local inferred_task_type=""
	if [[ -n "$task_desc" ]]; then
		local task_tags_for_type
		task_tags_for_type=$(echo "$task_desc" | grep -oE '#[a-zA-Z][a-zA-Z0-9_-]*' | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' || echo "")
		local desc_lower_for_type
		desc_lower_for_type=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]')
		# Map tags/keywords to VALID_TASK_TYPES
		if [[ "$task_tags_for_type" == *"#feature"* || "$desc_lower_for_type" =~ add.*feature|implement.*feature|new.*feature ]]; then
			inferred_task_type="feature"
		elif [[ "$task_tags_for_type" == *"#bugfix"* || "$task_tags_for_type" == *"#fix"* || "$desc_lower_for_type" =~ fix.*bug|bugfix|hotfix ]]; then
			inferred_task_type="bugfix"
		elif [[ "$task_tags_for_type" == *"#refactor"* || "$desc_lower_for_type" =~ refactor ]]; then
			inferred_task_type="refactor"
		elif [[ "$task_tags_for_type" == *"#docs"* || "$desc_lower_for_type" =~ update.*doc|add.*doc ]]; then
			inferred_task_type="docs"
		elif [[ "$task_tags_for_type" == *"#test"* || "$desc_lower_for_type" =~ add.*test|write.*test ]]; then
			inferred_task_type="testing"
		elif [[ "$task_tags_for_type" == *"#architecture"* || "$desc_lower_for_type" =~ architect ]]; then
			inferred_task_type="architecture"
		elif [[ "$task_tags_for_type" == *"#security"* || "$desc_lower_for_type" =~ security ]]; then
			inferred_task_type="security"
		elif [[ "$task_tags_for_type" == *"#enhancement"* || "$task_tags_for_type" == *"#self-improvement"* ]]; then
			inferred_task_type="feature"
		fi
	fi

	# 3) Pattern-tracker recommendation (t246, t1149: data-driven routing)
	#    If we have 3+ samples for a task type with ≥75% success rate on a
	#    cheaper tier, use that tier. This learns from actual dispatch outcomes.
	if [[ -n "$task_desc" && -x "$pattern_helper" ]]; then
		local pattern_args=("recommend" "--json")
		[[ -n "$inferred_task_type" ]] && pattern_args+=("--task-type" "$inferred_task_type")

		local pattern_json
		pattern_json=$("$pattern_helper" "${pattern_args[@]}" 2>/dev/null || echo "")
		if [[ -n "$pattern_json" && "$pattern_json" != "{}" ]]; then
			local recommended_tier
			recommended_tier=$(echo "$pattern_json" | sed -n 's/.*"recommended_tier"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || echo "")
			local sample_count
			sample_count=$(echo "$pattern_json" | sed -n 's/.*"total_samples"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' 2>/dev/null || echo "0")
			local success_rate
			success_rate=$(echo "$pattern_json" | sed -n 's/.*"success_rate"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' 2>/dev/null || echo "0")

			if [[ -n "$recommended_tier" && "$sample_count" -ge 3 && "$success_rate" -ge 75 ]]; then
				if [[ "$recommended_tier" != "opus" ]]; then
					local resolved
					resolved=$(resolve_model "$recommended_tier" "$ai_cli")
					log_info "Model for $task_id: $resolved (pattern-tracker: ${recommended_tier}, ${success_rate}% success over ${sample_count} samples${inferred_task_type:+, type: $inferred_task_type})"
					echo "$resolved"
					return 0
				fi
			fi
		fi
	fi

	# 4) Auto-classify task complexity from description + tags (t246)
	#    Route trivial tasks to haiku, simple tasks to sonnet (~5x cheaper)
	#    Keep complex tasks (architecture, novel features) on opus
	if [[ -n "$task_desc" ]]; then
		# Extract tags from description (e.g., "#docs #optimization")
		local task_tags
		task_tags=$(echo "$task_desc" | grep -oE '#[a-zA-Z][a-zA-Z0-9_-]*' | tr '\n' ' ' || echo "")

		local suggested_tier
		suggested_tier=$(classify_task_complexity "$task_desc" "$task_tags")
		if [[ "$suggested_tier" != "opus" ]]; then
			local resolved
			resolved=$(resolve_model "$suggested_tier" "$ai_cli")
			log_info "Model for $task_id: $resolved (auto-classified as $suggested_tier)"
			echo "$resolved"
			return 0
		fi

		# 4.5) Cost-efficiency check (t1149): classify_task_complexity returned opus,
		#      but check if pattern data shows sonnet achieves ≥80% success for this
		#      task type. If so, downgrade to sonnet (~5x cheaper) unless the task
		#      contains hard architecture/novel-problem indicators that require opus.
		#      Threshold: 80% (higher than step 3's 75% — we're overriding opus here).
		local desc_lower_ce
		desc_lower_ce=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]')
		local hard_opus_indicators=false
		# Hard indicators: tasks that genuinely need opus reasoning depth
		if [[ "$desc_lower_ce" =~ architect.*system|design.*new.*system|security.*audit|from.*scratch|novel.*algorithm|consensus.*protocol|distributed.*system ]]; then
			hard_opus_indicators=true
		fi

		if [[ "$hard_opus_indicators" == false && -x "$pattern_helper" ]]; then
			# Query sonnet-specific success rate for this task type
			local sonnet_args=("recommend" "--json")
			[[ -n "$inferred_task_type" ]] && sonnet_args+=("--task-type" "$inferred_task_type")

			local ce_pattern_json
			ce_pattern_json=$("$pattern_helper" "${sonnet_args[@]}" 2>/dev/null || echo "")
			if [[ -n "$ce_pattern_json" && "$ce_pattern_json" != "{}" ]]; then
				local ce_recommended_tier
				ce_recommended_tier=$(echo "$ce_pattern_json" | sed -n 's/.*"recommended_tier"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || echo "")
				local ce_sample_count
				ce_sample_count=$(echo "$ce_pattern_json" | sed -n 's/.*"total_samples"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' 2>/dev/null || echo "0")
				local ce_success_rate
				ce_success_rate=$(echo "$ce_pattern_json" | sed -n 's/.*"success_rate"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' 2>/dev/null || echo "0")

				# Downgrade opus→sonnet when: ≥3 samples, ≥80% success, recommended tier is sonnet or cheaper
				if [[ -n "$ce_recommended_tier" && "$ce_sample_count" -ge 3 && "$ce_success_rate" -ge 80 ]]; then
					if [[ "$ce_recommended_tier" == "sonnet" || "$ce_recommended_tier" == "haiku" || "$ce_recommended_tier" == "flash" ]]; then
						local resolved
						resolved=$(resolve_model "$ce_recommended_tier" "$ai_cli")
						log_info "Model for $task_id: $resolved (cost-efficiency: pattern data shows ${ce_success_rate}% success at ${ce_recommended_tier} over ${ce_sample_count} samples — downgraded from opus)"
						echo "$resolved"
						return 0
					fi
				fi
			fi
		fi
	fi

	# 4.6) Auto-contest detection (t1011): if we reached here (no strong signal),
	# check if contest mode should be triggered. Only for genuinely uncertain cases
	# where pattern data is insufficient or inconclusive.
	# Env var SUPERVISOR_CONTEST_AUTO=true enables this (default: false to avoid 3x cost)
	if [[ "${SUPERVISOR_CONTEST_AUTO:-false}" == "true" ]]; then
		local contest_helper="${SCRIPT_DIR}/contest-helper.sh"
		if [[ -x "$contest_helper" ]]; then
			local contest_reason
			contest_reason=$("$contest_helper" should-contest "$task_id" 2>/dev/null) || true
			if [[ -n "$contest_reason" && "$contest_reason" != "strong_signal" ]]; then
				log_info "Model for $task_id: CONTEST mode (auto-detected: $contest_reason)"
				echo "CONTEST"
				return 0
			fi
		fi
	fi

	# 4.7) Budget-aware tier adjustment (t1100)
	# Check budget state and potentially degrade the tier to stay within budget.
	# Token-billed: degrade opus->sonnet when approaching daily cap.
	# Subscription: prefer subscription providers when allowance is available.
	local budget_helper="${SCRIPT_DIR}/../budget-tracker-helper.sh"
	if [[ -x "$budget_helper" ]]; then
		# Determine the tier we're about to use (default: coding/opus)
		local pre_budget_tier="coding"

		# Check if a subscription provider has allowance (zero marginal cost)
		local preferred_provider
		preferred_provider=$("$budget_helper" budget-preferred-provider "$pre_budget_tier" 2>/dev/null) || preferred_provider=""
		if [[ -n "$preferred_provider" ]]; then
			local resolved
			resolved=$(resolve_model "$pre_budget_tier" "$ai_cli")
			log_info "Model for $task_id: $resolved (budget: preferred provider $preferred_provider has allowance)"
			echo "$resolved"
			return 0
		fi

		# Check if the default provider's budget requires tier degradation
		local adjusted_tier
		adjusted_tier=$("$budget_helper" budget-check-tier "anthropic" "$pre_budget_tier" 2>/dev/null) || adjusted_tier="$pre_budget_tier"
		if [[ "$adjusted_tier" != "$pre_budget_tier" ]]; then
			local resolved
			resolved=$(resolve_model "$adjusted_tier" "$ai_cli")
			log_info "Model for $task_id: $resolved (budget: degraded from $pre_budget_tier to $adjusted_tier)"
			echo "$resolved"
			return 0
		fi
	fi

	# 5) Fall back to resolve_model with default tier
	local resolved
	resolved=$(resolve_model "coding" "$ai_cli")
	log_info "Model for $task_id: $resolved (default coding tier)"
	echo "$resolved"
	return 0
}

#######################################
# Record requested_tier and actual_tier to the tasks DB (t1117)
# Enables post-hoc cost analysis: which tasks were dispatched at a higher
# tier than requested (escalation waste) or lower (budget degradation).
#
# $1: task_id
# $2: requested_tier — tier from TODO.md model: tag (e.g., "sonnet", "opus")
#                      Empty string means no explicit model: tag was set.
# $3: actual_model   — resolved provider/model string (e.g., "anthropic/claude-opus-4-6")
#
# Returns: 0 always (non-blocking — DB write failure must not abort dispatch)
#######################################
record_dispatch_model_tiers() {
	local task_id="$1"
	local requested_tier="$2"
	local actual_model="$3"

	# Derive actual_tier from the resolved model string
	local actual_tier=""
	if command -v model_to_tier &>/dev/null; then
		actual_tier=$(model_to_tier "$actual_model" 2>/dev/null || echo "")
	fi
	# Fallback: inline pattern match if model_to_tier not yet available
	if [[ -z "$actual_tier" ]]; then
		case "$actual_model" in
		*haiku*) actual_tier="haiku" ;;
		*sonnet*) actual_tier="sonnet" ;;
		*opus*) actual_tier="opus" ;;
		*flash*) actual_tier="flash" ;;
		*pro*) actual_tier="pro" ;;
		*o3*) actual_tier="opus" ;;
		*) actual_tier="unknown" ;;
		esac
	fi

	# Normalise requested_tier: if it's a full model string, extract tier name
	if [[ "$requested_tier" == *"/"* ]] && command -v model_to_tier &>/dev/null; then
		requested_tier=$(model_to_tier "$requested_tier" 2>/dev/null || echo "$requested_tier")
	fi

	# Store to DB (non-blocking)
	if [[ -n "${SUPERVISOR_DB:-}" ]]; then
		local escaped_id
		escaped_id=$(sql_escape "$task_id")
		db "$SUPERVISOR_DB" "UPDATE tasks SET requested_tier = '$(sql_escape "$requested_tier")', actual_tier = '$(sql_escape "$actual_tier")' WHERE id = '$escaped_id';" 2>/dev/null || true
	fi

	# Log tier delta for immediate visibility
	if [[ -n "$requested_tier" && "$requested_tier" != "$actual_tier" ]]; then
		log_info "Model tiers for $task_id: requested=$requested_tier actual=$actual_tier (delta logged for t1114/t1109)"
	else
		log_verbose "Model tiers for $task_id: requested=${requested_tier:-default} actual=$actual_tier"
	fi

	return 0
}

#######################################
# Get the next higher-tier model for escalation (t132.6)
# Maps current model to the next tier in the escalation chain:
#   haiku -> sonnet -> opus (Anthropic)
#   flash -> pro (Google)
# Returns the next tier name, or empty string if already at max tier.
#######################################
get_next_tier() {
	local current_model="$1"

	# Normalize: extract the tier from a full model string
	local tier=""
	case "$current_model" in
	*haiku*) tier="haiku" ;;
	*sonnet*) tier="sonnet" ;;
	*opus*) tier="opus" ;;
	*flash*) tier="flash" ;;
	*pro*) tier="pro" ;;
	*grok*) tier="grok" ;;
	*) tier="" ;;
	esac

	# Escalation chains
	case "$tier" in
	haiku) echo "sonnet" ;;
	sonnet) echo "opus" ;;
	opus) echo "" ;; # Already at max Anthropic tier
	flash) echo "pro" ;;
	pro) echo "" ;;  # Already at max Google tier
	grok) echo "" ;; # No escalation path for Grok
	*)
		# Unknown model — try escalating to opus as a safe default
		if [[ "$current_model" != *"opus"* ]]; then
			echo "opus"
		else
			echo ""
		fi
		;;
	esac

	return 0
}

#######################################
# Prompt-repeat retry strategy (t1097)
#
# Before escalating to a higher-tier model, retry the same task at the same
# model tier with a reinforced/doubled prompt. Many failures are due to the
# model not following instructions closely enough — a stronger prompt with
# explicit emphasis on the failure reason often succeeds without the cost of
# a higher-tier model.
#
# The strategy is:
#   1. Check if prompt-repeat is enabled (SUPERVISOR_PROMPT_REPEAT_ENABLED)
#   2. Check if this task has already had a prompt-repeat attempt
#   3. Consult pattern tracker: does this task type benefit from prompt-repeat?
#   4. If eligible, build a reinforced prompt and dispatch at same tier
#
# Pattern tracker integration: tasks tagged with SUCCESS_PATTERN where the
# detail contains "prompt_repeat" indicate this strategy works for that type.
# Tasks with FAILURE_PATTERN + "prompt_repeat" indicate it doesn't help.
# With 3+ samples and >50% success rate, prompt-repeat is recommended.
#######################################

#######################################
# Check if a task is eligible for prompt-repeat retry (t1097)
#
# Eligibility criteria:
#   1. SUPERVISOR_PROMPT_REPEAT_ENABLED is true (default: true)
#   2. Task has not already had a prompt-repeat attempt (DB flag)
#   3. Failure reason is retryable (not auth, merge conflict, OOM, etc.)
#   4. Pattern tracker data doesn't show prompt-repeat is ineffective
#      for this task type (>3 samples with <25% success = skip)
#
# Args: $1 = task_id, $2 = failure_reason
# Returns: 0 if eligible, 1 if not
# Outputs: reason string on stdout (for logging)
#######################################
should_prompt_repeat() {
	local task_id="$1"
	local failure_reason="$2"

	# 1. Global toggle
	if [[ "${SUPERVISOR_PROMPT_REPEAT_ENABLED:-true}" != "true" ]]; then
		echo "disabled"
		return 1
	fi

	# 2. Skip non-retryable failures — prompt changes won't fix these
	case "$failure_reason" in
	auth_error | merge_conflict | out_of_memory | billing_credits_exhausted | \
		backend_quota_error | backend_infrastructure_error | max_retries)
		echo "non_retryable:$failure_reason"
		return 1
		;;
	esac

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# 3. Check if prompt-repeat was already attempted for this task
	local prompt_repeat_done
	prompt_repeat_done=$(db "$SUPERVISOR_DB" "
		SELECT COALESCE(prompt_repeat_done, 0)
		FROM tasks WHERE id = '$escaped_id';
	" 2>/dev/null || echo "0")

	if [[ "$prompt_repeat_done" -ge 1 ]]; then
		echo "already_attempted"
		return 1
	fi

	# 4. Consult pattern tracker — check if prompt-repeat works for this task type
	local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
	if [[ -x "$pattern_helper" ]]; then
		# Query success/failure counts for prompt_repeat patterns
		local stats_output pr_success pr_failure
		stats_output=$("$pattern_helper" stats 2>/dev/null)
		pr_success=$(echo "$stats_output" |
			grep -c 'prompt_repeat.*SUCCESS\|SUCCESS.*prompt_repeat' 2>/dev/null || echo "0")
		pr_failure=$(echo "$stats_output" |
			grep -c 'prompt_repeat.*FAILURE\|FAILURE.*prompt_repeat' 2>/dev/null || echo "0")

		local pr_total=$((pr_success + pr_failure))

		# If we have enough data and success rate is very low, skip
		if [[ "$pr_total" -ge 3 ]]; then
			local pr_rate=0
			if [[ "$pr_total" -gt 0 ]]; then
				pr_rate=$(((pr_success * 100) / pr_total))
			fi
			if [[ "$pr_rate" -lt 25 ]]; then
				echo "pattern_data_negative:${pr_rate}pct_over_${pr_total}"
				return 1
			fi
		fi
	fi

	echo "eligible"
	return 0
}

#######################################
# Mark a task as having had a prompt-repeat attempt (t1097)
#
# Sets the prompt_repeat_done flag in the DB so the task won't get
# another prompt-repeat on subsequent retries (escalation takes over).
#
# Args: $1 = task_id
#######################################
mark_prompt_repeat_done() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	db "$SUPERVISOR_DB" "
		UPDATE tasks SET prompt_repeat_done = 1
		WHERE id = '$escaped_id';
	" 2>/dev/null || true

	return 0
}

#######################################
# Build a reinforced prompt for prompt-repeat retry (t1097)
#
# Takes the original task description and failure reason, and constructs
# a prompt that:
#   1. Doubles down on the task requirements
#   2. Explicitly states what went wrong in the previous attempt
#   3. Adds emphasis on completion signals and PR creation
#   4. Keeps the same model tier (no escalation)
#
# Args:
#   $1 = task_id
#   $2 = failure_reason (from evaluate_worker)
#   $3 = task_description
#   $4 = previous_error (from DB error field)
#
# Outputs: reinforced prompt string on stdout
#######################################
build_prompt_repeat_prompt() {
	local task_id="$1"
	local failure_reason="$2"
	local task_desc="${3:-}"
	local previous_error="${4:-}"

	local prompt="/full-loop $task_id --headless"
	if [[ -n "$task_desc" ]]; then
		prompt="/full-loop $task_id --headless -- $task_desc"
	fi

	# Build failure-specific guidance
	local failure_guidance=""
	case "$failure_reason" in
	clean_exit_no_signal)
		failure_guidance="The previous worker completed without emitting FULL_LOOP_COMPLETE or creating a PR. You MUST:
1. Complete ALL implementation steps
2. Run ShellCheck on any .sh files before pushing
3. Create a PR via 'gh pr create' with task ID in the title
4. Emit FULL_LOOP_COMPLETE in your final output
Do NOT exit without creating a PR. If you run low on context, commit and push what you have, then create a draft PR."
		;;
	trivial_output_*)
		failure_guidance="The previous worker produced almost no output — it likely failed to engage with the task. Read the task description carefully, break it into subtasks with TodoWrite, and implement each one. Commit after each subtask."
		;;
	work_in_progress)
		failure_guidance="The previous worker started but didn't finish. Check the existing branch for partial work, continue from where it left off, and ensure you create a PR when done."
		;;
	*)
		failure_guidance="The previous attempt failed with: ${failure_reason}. Address this specific issue in your approach. Ensure you complete the full implementation and create a PR."
		;;
	esac

	prompt="$prompt

## PROMPT-REPEAT RETRY (t1097)
This is a reinforced retry at the SAME model tier. The previous attempt failed.
You have ONE chance to get this right before the system escalates to a more expensive model.

### What went wrong previously
Failure reason: ${failure_reason}
${previous_error:+Previous error detail: ${previous_error}}

### Critical requirements (REINFORCED)
${failure_guidance}

### Mandatory completion checklist
- [ ] Read and understand the task fully before writing code
- [ ] Break task into subtasks with TodoWrite
- [ ] Implement each subtask, committing after each one
- [ ] Run ShellCheck on .sh files before pushing
- [ ] Push to remote and create PR with task ID in title
- [ ] Emit FULL_LOOP_COMPLETE when done

## MANDATORY Worker Restrictions (t173)
- Do NOT edit, commit, or push TODO.md — the supervisor owns all TODO.md updates.
- Do NOT edit todo/PLANS.md or todo/tasks/* — these are supervisor-managed.
- Report status via exit code, log output, and PR creation only.
- Put task notes in commit messages or PR body, never in TODO.md."

	echo "$prompt"
	return 0
}

#######################################
# Execute a prompt-repeat retry for a task (t1097)
#
# Dispatches the task with a reinforced prompt at the same model tier.
# This is called from the pulse cycle's retry handler, BEFORE model
# escalation. If prompt-repeat succeeds, the task completes without
# burning a more expensive model. If it fails, normal escalation proceeds.
#
# Args:
#   $1 = task_id
#
# Returns: 0 if dispatch succeeded, 1 if failed
# Side effects: marks prompt_repeat_done, creates new log file, dispatches worker
#######################################
do_prompt_repeat() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Get task details
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT repo, description, worktree, log_file, error, model, retries, max_retries
		FROM tasks WHERE id = '$escaped_id';
	")

	if [[ -z "$task_row" ]]; then
		log_error "do_prompt_repeat: task not found: $task_id"
		return 1
	fi

	local trepo tdesc tworktree _tlog terror tmodel tretries tmax_retries
	IFS='|' read -r trepo tdesc tworktree _tlog terror tmodel tretries tmax_retries <<<"$task_row"

	# Mark prompt-repeat as attempted (prevents infinite loop)
	mark_prompt_repeat_done "$task_id"

	# Build reinforced prompt
	local reinforced_prompt
	reinforced_prompt=$(build_prompt_repeat_prompt "$task_id" "${terror:-unknown}" "$tdesc" "$terror")

	# Resolve AI CLI
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_error "do_prompt_repeat: AI CLI not available"
		return 1
	}

	# Pre-dispatch health check
	local health_model health_exit=0
	health_model=$(resolve_model "health" "$ai_cli")
	check_model_health "$ai_cli" "$health_model" || health_exit=$?
	if [[ "$health_exit" -ne 0 ]]; then
		log_warn "do_prompt_repeat: provider unhealthy (exit $health_exit) — skipping prompt-repeat"
		return 1
	fi

	# Determine working directory (reuse existing worktree)
	local work_dir="$trepo"
	if [[ -n "$tworktree" && -d "$tworktree" ]]; then
		work_dir="$tworktree"
	fi

	# Set up log file
	local log_dir="$SUPERVISOR_DIR/logs"
	mkdir -p "$log_dir"
	local new_log_file
	new_log_file="$log_dir/${task_id}-prompt-repeat-$(date +%Y%m%d%H%M%S).log"

	# Pre-create log file with metadata
	{
		echo "=== PROMPT-REPEAT METADATA (t1097) ==="
		echo "task_id=$task_id"
		echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "retry=$tretries/$tmax_retries"
		echo "work_dir=$work_dir"
		echo "previous_error=${terror:-none}"
		echo "strategy=prompt_repeat_same_tier"
		echo "model=$tmodel"
		echo "=== END PROMPT-REPEAT METADATA ==="
		echo ""
	} >"$new_log_file" 2>/dev/null || true

	# Transition to dispatched
	cmd_transition "$task_id" "dispatched" --log-file "$new_log_file"

	log_info "Prompt-repeat retry for $task_id (same model: $tmodel)"

	# Build dispatch command — use same model, reinforced prompt (t1160.1)
	local session_title="${task_id}-prompt-repeat"
	if [[ -n "$tdesc" ]]; then
		local short_desc="${tdesc%% -- *}"
		short_desc="${short_desc%% #*}"
		short_desc="${short_desc%% ~*}"
		if [[ ${#short_desc} -gt 30 ]]; then
			short_desc="${short_desc:0:27}..."
		fi
		session_title="${task_id}-pr: ${short_desc}"
	fi
	# Ensure PID directory exists
	mkdir -p "$SUPERVISOR_DIR/pids"

	# Generate worker-specific MCP config (t221, t1162)
	# Must be generated BEFORE build_cli_cmd so Claude CLI gets --mcp-config flag
	local worker_mcp_config=""
	worker_mcp_config=$(generate_worker_mcp_config "$task_id" "$ai_cli" "$work_dir") || true

	# Build CLI command with MCP config for Claude (t1162)
	local -a build_cmd_args=(
		--cli "$ai_cli"
		--action run
		--output nul
		--model "$tmodel"
		--title "$session_title"
		--prompt "$reinforced_prompt"
	)
	# For Claude CLI, pass MCP config as CLI flag; for OpenCode, it's an env var
	if [[ "$ai_cli" == "claude" && -n "$worker_mcp_config" ]]; then
		build_cmd_args+=(--mcp-config "$worker_mcp_config")
	fi
	local -a cmd_parts=()
	while IFS= read -r -d '' part; do
		cmd_parts+=("$part")
	done < <(build_cli_cmd "${build_cmd_args[@]}")

	# Write dispatch script
	# t1190: Use timestamped filename to prevent overwrite race condition.
	local pr_dispatch_ts
	pr_dispatch_ts=$(date +%Y%m%d%H%M%S)
	local dispatch_script="${SUPERVISOR_DIR}/pids/${task_id}-prompt-repeat-${pr_dispatch_ts}.sh"
	{
		echo '#!/usr/bin/env bash'
		echo "echo 'WORKER_STARTED task_id=${task_id} strategy=prompt_repeat pid=\$\$ timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "cd '${work_dir}' || { echo 'WORKER_FAILED: cd to work_dir failed: ${work_dir}'; exit 1; }"
		echo "export FULL_LOOP_HEADLESS=true"
		# t1162: For OpenCode, set XDG_CONFIG_HOME; for Claude, MCP config is in CLI flags
		if [[ "$ai_cli" != "claude" && -n "$worker_mcp_config" ]]; then
			echo "export XDG_CONFIG_HOME='${worker_mcp_config}'"
		fi
		printf 'exec '
		printf '%q ' "${cmd_parts[@]}"
		printf '\n'
	} >"$dispatch_script"
	chmod +x "$dispatch_script"

	# Wrapper script with cleanup handlers (t253)
	# t1190: Use timestamped filename to prevent overwrite race condition.
	local wrapper_script="${SUPERVISOR_DIR}/pids/${task_id}-prompt-repeat-wrapper-${pr_dispatch_ts}.sh"
	{
		echo '#!/usr/bin/env bash'
		# t1190: Wrapper-level sentinel written before running dispatch script.
		echo "echo 'WRAPPER_STARTED task_id=${task_id} strategy=prompt_repeat wrapper_pid=\$\$ dispatch_script=${dispatch_script} timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ) >> '${new_log_file}' 2>/dev/null || true"
		echo '_kill_descendants_recursive() {'
		echo '  local parent_pid="$1"'
		echo '  local children'
		echo '  children=$(pgrep -P "$parent_pid" 2>/dev/null || true)'
		echo '  if [[ -n "$children" ]]; then'
		echo '    for child in $children; do'
		echo '      _kill_descendants_recursive "$child"'
		echo '    done'
		echo '  fi'
		echo '  kill -TERM "$parent_pid" 2>/dev/null || true'
		echo '}'
		echo 'cleanup_children() {'
		echo '  local wrapper_pid=$$'
		echo '  local children'
		echo '  children=$(pgrep -P "$wrapper_pid" 2>/dev/null || true)'
		echo '  if [[ -n "$children" ]]; then'
		echo '    for child in $children; do'
		echo '      _kill_descendants_recursive "$child"'
		echo '    done'
		echo '    sleep 0.5'
		echo '    for child in $children; do'
		echo '      pkill -9 -P "$child" 2>/dev/null || true'
		echo '      kill -9 "$child" 2>/dev/null || true'
		echo '    done'
		echo '  fi'
		echo '}'
		echo 'trap cleanup_children EXIT INT TERM'
		echo ''
		# t1196: Heartbeat — write a timestamped line to the log every N seconds.
		local heartbeat_interval="${SUPERVISOR_HEARTBEAT_INTERVAL:-300}"
		echo "# t1196: Heartbeat background process"
		echo "_heartbeat_log='${new_log_file}'"
		echo "_heartbeat_interval='${heartbeat_interval}'"
		echo '( while true; do'
		echo '    sleep "$_heartbeat_interval" || break'
		echo '    echo "HEARTBEAT: $(date -u +%Y-%m-%dT%H:%M:%SZ) worker still running" >> "$_heartbeat_log" 2>/dev/null || true'
		echo '  done ) &'
		echo '_heartbeat_pid=$!'
		echo ''
		echo "'${dispatch_script}' >> '${new_log_file}' 2>&1"
		echo "rc=\$?"
		echo "kill \$_heartbeat_pid 2>/dev/null || true"
		echo "echo \"EXIT:\${rc}\" >> '${new_log_file}'"
		echo "if [ \$rc -ne 0 ]; then"
		echo "  echo \"WORKER_DISPATCH_ERROR: prompt-repeat script exited with code \${rc}\" >> '${new_log_file}'"
		echo "fi"
	} >"$wrapper_script"
	chmod +x "$wrapper_script"

	# Dispatch
	# t1190: Redirect wrapper stderr to log file (not /dev/null) for diagnosis.
	if command -v setsid &>/dev/null; then
		nohup setsid bash "${wrapper_script}" >>"${new_log_file}" 2>&1 &
	else
		nohup bash "${wrapper_script}" >>"${new_log_file}" 2>&1 &
	fi
	local worker_pid=$!
	disown "$worker_pid" 2>/dev/null || true

	echo "$worker_pid" >"$SUPERVISOR_DIR/pids/${task_id}.pid"

	# Transition to running
	cmd_transition "$task_id" "running" --session "pid:$worker_pid"

	log_success "Prompt-repeat dispatched for $task_id (PID: $worker_pid, same model: $tmodel)"

	# Record pattern for tracking
	local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
	if [[ -x "$pattern_helper" ]]; then
		"$pattern_helper" record \
			--type "WORKING_SOLUTION" \
			--task "$task_id" \
			--model "${tmodel:-unknown}" \
			--detail "prompt_repeat_attempted for ${terror:-unknown}" \
			2>/dev/null || true
	fi

	echo "$worker_pid"
	return 0
}

#######################################
# Check output quality of a completed worker (t132.6)
# Heuristic quality checks on worker output to decide if escalation is needed.
# Returns: "pass" if quality is acceptable, "fail:<reason>" if not.
#
# Checks performed:
#   1. Empty/trivial output (log too small)
#   2. Error patterns in log (panics, crashes, unhandled exceptions)
#   3. No substantive file changes (git diff empty)
#   4. ShellCheck violations for .sh files (if applicable)
#   5. Very low token-to-substance ratio
#######################################
check_output_quality() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT log_file, worktree, branch, repo, pr_url
        FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		echo "pass" # Can't check, assume OK
		return 0
	fi

	local tlog tworktree _tbranch trepo tpr_url
	IFS='|' read -r tlog tworktree _tbranch trepo tpr_url <<<"$task_row"

	# Check 1: Log file size — very small logs suggest trivial/empty output
	if [[ -n "$tlog" && -f "$tlog" ]]; then
		local log_size
		log_size=$(wc -c <"$tlog" 2>/dev/null | tr -d ' ')
		# Less than 2KB of log output is suspicious for a coding task
		if [[ "$log_size" -lt 2048 ]]; then
			# But check if it's a legitimate small task (e.g., docs-only)
			local has_pr_signal
			has_pr_signal=$(grep -c 'WORKER_PR_CREATED\|WORKER_COMPLETE\|PR_URL' "$tlog" 2>/dev/null || echo "0")
			if [[ "$has_pr_signal" -eq 0 ]]; then
				echo "fail:trivial_output_${log_size}b"
				return 0
			fi
		fi

		# Check 2: Error patterns in log
		local error_count
		error_count=$(grep -ciE 'panic|fatal|unhandled.*exception|segfault|SIGKILL|out of memory|OOM' "$tlog" 2>/dev/null || echo "0")
		if [[ "$error_count" -gt 2 ]]; then
			echo "fail:error_patterns_${error_count}"
			return 0
		fi

		# Check 3: Token-to-substance ratio
		# If the log is very large (>500KB) but has no PR or meaningful output markers,
		# the worker may have been spinning without producing results
		if [[ "$log_size" -gt 512000 ]]; then
			local substance_markers
			substance_markers=$(grep -ciE 'WORKER_COMPLETE|WORKER_PR_CREATED|PR_URL|commit|merged|created file|wrote file' "$tlog" 2>/dev/null || echo "0")
			if [[ "$substance_markers" -lt 3 ]]; then
				echo "fail:low_substance_ratio_${log_size}b_${substance_markers}markers"
				return 0
			fi
		fi
	fi

	# Check 4: If we have a worktree/branch, check for substantive changes
	if [[ -n "$tworktree" && -d "$tworktree" ]]; then
		local diff_stat
		diff_stat=$(git -C "$tworktree" diff --stat "main..HEAD" 2>/dev/null || echo "")
		if [[ -z "$diff_stat" ]]; then
			# No changes at all on the branch
			echo "fail:no_file_changes"
			return 0
		fi

		# Check 5: ShellCheck for .sh files (quick heuristic)
		local changed_sh_files
		changed_sh_files=$(git -C "$tworktree" diff --name-only "main..HEAD" 2>/dev/null | grep '\.sh$' || true)
		if [[ -n "$changed_sh_files" ]]; then
			local shellcheck_errors=0
			while IFS= read -r sh_file; do
				[[ -z "$sh_file" ]] && continue
				local full_path="${tworktree}/${sh_file}"
				[[ -f "$full_path" ]] || continue
				local sc_count
				sc_count=$(bash -n "$full_path" 2>&1 | wc -l | tr -d ' ')
				shellcheck_errors=$((shellcheck_errors + sc_count))
			done <<<"$changed_sh_files"
			if [[ "$shellcheck_errors" -gt 5 ]]; then
				echo "fail:syntax_errors_${shellcheck_errors}"
				return 0
			fi
		fi
	fi

	# Check 6: If PR was created, verify it has substantive content
	if [[ -n "$tpr_url" && "$tpr_url" != "no_pr" && "$tpr_url" != "task_only" ]]; then
		# PR exists — that's a strong positive signal
		echo "pass"
		return 0
	fi

	# All checks passed
	echo "pass"
	return 0
}

#######################################
# Run quality gate and escalate if needed (t132.6)
# Called after evaluate_worker() returns "complete".
# Returns: "pass" if quality OK or escalation not possible,
#          "escalate:<new_model>" if re-dispatch needed.
#######################################
run_quality_gate() {
	local task_id="$1"
	local batch_id="${2:-}"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Check if quality gate is skipped for this batch
	if [[ -n "$batch_id" ]]; then
		local skip_gate
		skip_gate=$(db "$SUPERVISOR_DB" "SELECT skip_quality_gate FROM batches WHERE id = '$(sql_escape "$batch_id")';" 2>/dev/null || echo "0")
		if [[ "$skip_gate" -eq 1 ]]; then
			log_info "Quality gate skipped for batch $batch_id"
			echo "pass"
			return 0
		fi
	fi

	# Check escalation depth
	local task_escalation
	task_escalation=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT escalation_depth, max_escalation, model
        FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_escalation" ]]; then
		echo "pass"
		return 0
	fi

	local current_depth max_depth current_model
	IFS='|' read -r current_depth max_depth current_model <<<"$task_escalation"

	# Already at max escalation depth
	if [[ "$current_depth" -ge "$max_depth" ]]; then
		log_info "Quality gate: $task_id at max escalation depth ($current_depth/$max_depth), accepting result"
		echo "pass"
		return 0
	fi

	# Run quality checks
	local quality_result
	quality_result=$(check_output_quality "$task_id")

	if [[ "$quality_result" == "pass" ]]; then
		log_info "Quality gate: $task_id passed quality checks"
		echo "pass"
		return 0
	fi

	# Quality failed — try to escalate
	local fail_reason="${quality_result#fail:}"
	local next_tier
	next_tier=$(get_next_tier "$current_model")

	if [[ -z "$next_tier" ]]; then
		log_warn "Quality gate: $task_id failed ($fail_reason) but no higher tier available from $current_model"
		echo "pass"
		return 0
	fi

	# Resolve the next tier to a full model string
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null || echo "opencode")
	local next_model
	next_model=$(resolve_model "$next_tier" "$ai_cli")

	log_warn "Quality gate: $task_id failed ($fail_reason), escalating from $current_model to $next_model (depth $((current_depth + 1))/$max_depth)"

	# Update escalation depth and model, then transition to queued via state machine
	db "$SUPERVISOR_DB" "
        UPDATE tasks SET
            escalation_depth = $((current_depth + 1)),
            model = '$(sql_escape "$next_model")'
        WHERE id = '$escaped_id';
    "
	cmd_transition "$task_id" "queued" --error "Quality gate escalation: $fail_reason" 2>/dev/null || true

	echo "escalate:${next_model}"
	return 0
}

#######################################
# Dispatch deduplication guard (t1206)
# Prevents re-dispatching tasks that failed with the same error in a short window.
# Guards against token waste from repeated identical failures (e.g., t1032.1 failed
# twice within 2 minutes with the same error; t1030 failed twice within 22 minutes).
#
# Rules enforced:
#   1. 10-minute cooldown after any failure before re-dispatch of the same task
#   2. After 2 consecutive identical failures, move task to 'blocked' with diagnostic note
#   3. Log a warning when the same task fails with the same error code twice in succession
#
# Usage: check_dispatch_dedup_guard <task_id>
# Returns:
#   0 = proceed with dispatch
#   1 = blocked (task transitioned to blocked state, caller should return 1)
#   2 = cooldown active (defer dispatch, caller should return 3 to pulse)
#######################################
check_dispatch_dedup_guard() {
	local task_id="$1"
	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Fetch dedup guard fields from DB
	local guard_row
	guard_row=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT COALESCE(last_failure_at, ''),
		       COALESCE(consecutive_failure_count, 0),
		       COALESCE(error, '')
		FROM tasks WHERE id = '$escaped_id';
	" 2>/dev/null) || guard_row=""

	if [[ -z "$guard_row" ]]; then
		return 0
	fi

	local last_failure_at consecutive_count last_error
	IFS='|' read -r last_failure_at consecutive_count last_error <<<"$guard_row"

	# No prior failure recorded — proceed
	if [[ -z "$last_failure_at" ]]; then
		return 0
	fi

	# Calculate seconds since last failure
	local now_epoch last_failure_epoch elapsed_secs
	now_epoch=$(date -u +%s 2>/dev/null) || now_epoch=0
	# Convert ISO timestamp to epoch (macOS/BSD compatible)
	last_failure_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_failure_at" '+%s' 2>/dev/null ||
		date -u -d "$last_failure_at" '+%s' 2>/dev/null ||
		echo 0)
	elapsed_secs=$((now_epoch - last_failure_epoch))

	local cooldown_secs="${SUPERVISOR_FAILURE_COOLDOWN_SECS:-600}" # 10 minutes default
	local max_consecutive="${SUPERVISOR_MAX_CONSECUTIVE_FAILURES:-2}"

	# Rule 2: Block after max_consecutive identical failures
	if [[ "$consecutive_count" -ge "$max_consecutive" ]]; then
		local block_reason="Dispatch dedup guard: $consecutive_count consecutive identical failures (error: ${last_error:-unknown}) — manual intervention required (t1206)"
		log_warn "  $task_id: BLOCKED by dedup guard — $consecutive_count consecutive identical failures with error '${last_error:-unknown}'"
		cmd_transition "$task_id" "blocked" --error "$block_reason" 2>/dev/null || true
		update_todo_on_blocked "$task_id" "$block_reason" 2>/dev/null || true
		send_task_notification "$task_id" "blocked" "$block_reason" 2>/dev/null || true
		store_failure_pattern "$task_id" "blocked" "$block_reason" "dispatch-dedup-guard" 2>/dev/null || true
		return 1
	fi

	# Rule 1: Enforce cooldown window
	if [[ "$elapsed_secs" -lt "$cooldown_secs" ]]; then
		local remaining=$((cooldown_secs - elapsed_secs))
		log_warn "  $task_id: dispatch dedup cooldown active — last failure ${elapsed_secs}s ago (cooldown: ${cooldown_secs}s, ${remaining}s remaining, error: ${last_error:-unknown}) (t1206)"
		return 2
	fi

	return 0
}

#######################################
# Update dispatch dedup guard fields after a failure (t1206)
# Called from pulse.sh retry handler to track failure timestamps and counts.
# Increments consecutive_failure_count if error matches previous error,
# resets to 1 if error changed (different failure mode = fresh start).
#
# Usage: update_failure_dedup_state <task_id> <error_detail>
#######################################
update_failure_dedup_state() {
	local task_id="$1"
	local error_detail="${2:-}"
	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Fetch current state
	local current_row
	current_row=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT COALESCE(consecutive_failure_count, 0),
		       COALESCE(error, '')
		FROM tasks WHERE id = '$escaped_id';
	" 2>/dev/null) || current_row="0|"

	local current_count current_error
	IFS='|' read -r current_count current_error <<<"$current_row"

	# Normalise error strings for comparison (strip trailing detail after first colon)
	local new_error_key current_error_key
	new_error_key="${error_detail%%:*}"
	current_error_key="${current_error%%:*}"

	local new_count
	local max_consecutive="${SUPERVISOR_MAX_CONSECUTIVE_FAILURES:-2}"
	if [[ "$new_error_key" == "$current_error_key" && -n "$current_error_key" ]]; then
		# Same error type — increment consecutive count
		new_count=$((current_count + 1))
		if [[ "$new_count" -ge "$max_consecutive" ]]; then
			log_warn "  $task_id: consecutive failure #${new_count} with same error '${new_error_key}' — dedup guard will block next dispatch (threshold: $max_consecutive) (t1206)"
		fi
	else
		# Different error — reset counter (new failure mode)
		new_count=1
	fi

	local now_iso
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	db "$SUPERVISOR_DB" "
		UPDATE tasks
		SET last_failure_at = '$(sql_escape "$now_iso")',
		    consecutive_failure_count = $new_count
		WHERE id = '$escaped_id';
	" 2>/dev/null || true

	return 0
}

#######################################
# Reset dispatch dedup guard state after successful task completion (t1206)
# Clears last_failure_at and consecutive_failure_count so a re-queued task
# is not deferred by a stale cooldown from a pre-success failure.
#
# Usage: reset_failure_dedup_state <task_id>
#######################################
reset_failure_dedup_state() {
	local task_id="$1"
	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	db "$SUPERVISOR_DB" "
		UPDATE tasks
		SET last_failure_at = NULL,
		    consecutive_failure_count = 0
		WHERE id = '$escaped_id';
	" 2>/dev/null || true

	return 0
}

#######################################
# Pre-dispatch CLI health check (t1113)
#
# Verifies the AI CLI binary exists, is executable, and can produce output
# before spawning a worker. This prevents wasting retries on environment
# issues where the CLI was invoked but never produced output (the
# "worker_never_started:no_sentinel" failure pattern).
#
# Strategy:
#   1. Check binary exists in PATH (command -v)
#   2. Run a lightweight version/help check to verify it can execute
#   3. Cache result for the pulse duration (pulse-level flag)
#
# $1: ai_cli - the CLI binary name (e.g., "opencode", "claude")
#
# Exit codes:
#   0 = CLI healthy, proceed with dispatch
#   1 = CLI not found or not executable
#
# Outputs: diagnostic message on failure (for dispatch log)
#######################################
check_cli_health() {
	local ai_cli="$1"

	# Pulse-level fast path: if CLI was already verified in this pulse, skip
	if [[ -n "${_PULSE_CLI_VERIFIED:-}" ]]; then
		log_verbose "CLI health: pulse-verified OK (skipping check)"
		return 0
	fi

	# File-based cache: avoid re-checking within 5 minutes
	local cache_dir="$SUPERVISOR_DIR/health"
	mkdir -p "$cache_dir"
	local cli_cache_file="$cache_dir/cli-${ai_cli}"
	if [[ -f "$cli_cache_file" ]]; then
		local cached_at
		cached_at=$(cat "$cli_cache_file" 2>/dev/null || echo "0")
		local now
		now=$(date +%s)
		local age=$((now - cached_at))
		if [[ "$age" -lt 300 ]]; then
			log_verbose "CLI health: cached OK ($age seconds ago)"
			_PULSE_CLI_VERIFIED="true"
			return 0
		fi
	fi

	# Check 1: binary exists in PATH
	if ! command -v "$ai_cli" &>/dev/null; then
		log_error "CLI health check FAILED: '$ai_cli' not found in PATH"
		log_error "PATH=$PATH"
		echo "cli_not_found:${ai_cli}"
		return 1
	fi

	# Check 2: binary is executable and can produce version output
	local version_output=""
	local version_exit=1

	# Use timeout to prevent hanging on broken installations
	local timeout_cmd=""
	if command -v gtimeout &>/dev/null; then
		timeout_cmd="gtimeout"
	elif command -v timeout &>/dev/null; then
		timeout_cmd="timeout"
	fi

	# t1160.1: Build version command via build_cli_cmd abstraction
	local -a version_cmd=()
	eval "version_cmd=($(build_cli_cmd --cli "$ai_cli" --action version --output array))"
	if [[ -n "$timeout_cmd" ]]; then
		version_output=$("$timeout_cmd" 10 "${version_cmd[@]}" 2>&1) || version_exit=$?
	else
		version_output=$("${version_cmd[@]}" 2>&1) || version_exit=$?
	fi

	# If version command succeeded (exit 0) or produced output, CLI is working
	if [[ "$version_exit" -eq 0 ]] || [[ -n "$version_output" && "$version_exit" -ne 124 && "$version_exit" -ne 137 ]]; then
		# Cache the healthy result
		date +%s >"$cli_cache_file" 2>/dev/null || true
		_PULSE_CLI_VERIFIED="true"
		log_info "CLI health: OK ($ai_cli: ${version_output:0:80})"
		return 0
	fi

	# Version check failed
	if [[ "$version_exit" -eq 124 || "$version_exit" -eq 137 ]]; then
		log_error "CLI health check FAILED: '$ai_cli' timed out (10s)"
		echo "cli_timeout:${ai_cli}"
	else
		log_error "CLI health check FAILED: '$ai_cli' exited with code $version_exit"
		log_error "Output: ${version_output:0:200}"
		echo "cli_error:${ai_cli}:exit_${version_exit}"
	fi
	return 1
}

#######################################
# Pre-dispatch model health check (t132.3, t233)
# Two-tier probe strategy:
#   1. Fast path: model-availability-helper.sh (direct HTTP, ~1-2s, cached)
#   2. Slow path: Full AI CLI probe (spawns session, ~8-15s)
# Exit codes (t233 — propagated from model-availability-helper.sh):
#   0 = healthy
#   1 = unavailable (provider down, generic error)
#   2 = rate limited (defer dispatch, retry soon)
#   3 = API key invalid/missing (block, don't retry)
# Result is cached for 5 minutes to avoid repeated probes.
#######################################
check_model_health() {
	local ai_cli="$1"
	local model="${2:-}"
	_save_cleanup_scope
	trap '_run_cleanups' RETURN

	# Pulse-level fast path: if health was already verified in this pulse
	# invocation, skip the probe entirely (avoids 8s per task)
	if [[ -n "${_PULSE_HEALTH_VERIFIED:-}" ]]; then
		log_info "Model health: pulse-verified OK (skipping probe)"
		return 0
	fi

	# Fast path: use model-availability-helper.sh for lightweight HTTP probe (t132.3)
	# This checks the provider's /models endpoint (~1-2s) instead of spawning
	# a full AI CLI session (~8-15s). Falls through to slow path on failure.
	local availability_helper="${SCRIPT_DIR}/model-availability-helper.sh"
	if [[ -x "$availability_helper" ]]; then
		local provider_name=""
		if [[ -n "$model" && "$model" == *"/"* ]]; then
			provider_name="${model%%/*}"
		else
			provider_name="anthropic" # Default provider
		fi

		local avail_exit=0
		"$availability_helper" check "$provider_name" --quiet 2>/dev/null || avail_exit=$?

		case "$avail_exit" in
		0)
			_PULSE_HEALTH_VERIFIED="true"
			log_info "Model health: OK via availability helper (fast path)"
			return 0
			;;
		2)
			# t233: propagate rate-limit exit code so callers can defer dispatch
			# without burning retries (previously collapsed to exit 1)
			log_warn "Model health check: rate limited (via availability helper) — deferring dispatch"
			return 2
			;;
		3)
			# t233: propagate invalid-key exit code so callers can block dispatch
			# (previously collapsed to exit 1)
			log_warn "Model health check: API key invalid/missing (via availability helper) — blocking dispatch"
			return 3
			;;
		*)
			# When using OpenCode, the availability helper may fail because OpenCode
			# manages API keys internally (no standalone ANTHROPIC_API_KEY env var).
			# In this case, skip the slow CLI probe entirely and trust OpenCode.
			# If the model is truly unavailable, dispatch will fail and retry handles it.
			if [[ "$ai_cli" == "opencode" ]]; then
				log_info "Model health: skipping probe for OpenCode-managed provider (no direct API key)"
				_PULSE_HEALTH_VERIFIED="true"
				return 0
			fi
			log_verbose "Availability helper returned $avail_exit, falling through to CLI probe"
			;;
		esac
	fi

	# Slow path: file-based cache check (legacy, kept for environments without the helper)
	local cache_dir="$SUPERVISOR_DIR/health"
	mkdir -p "$cache_dir"
	local cache_key="${ai_cli}-${model//\//_}"
	local cache_file="$cache_dir/${cache_key}"

	if [[ -f "$cache_file" ]]; then
		local cached_at
		cached_at=$(cat "$cache_file")
		local now
		now=$(date +%s)
		local age=$((now - cached_at))
		if [[ "$age" -lt 300 ]]; then
			log_info "Model health: cached OK ($age seconds ago)"
			_PULSE_HEALTH_VERIFIED="true"
			return 0
		fi
	fi

	# Slow path: spawn AI CLI for a trivial prompt
	local timeout_cmd=""
	if command -v gtimeout &>/dev/null; then
		timeout_cmd="gtimeout"
	elif command -v timeout &>/dev/null; then
		timeout_cmd="timeout"
	fi

	local probe_result=""
	local probe_exit=1

	# t1160.1: Build probe command via build_cli_cmd abstraction
	local -a probe_cmd=()
	eval "probe_cmd=($(build_cli_cmd --cli "$ai_cli" --action probe --output array --model "$model"))"
	if [[ -n "$timeout_cmd" ]]; then
		probe_result=$("$timeout_cmd" 15 "${probe_cmd[@]}" 2>&1)
		probe_exit=$?
	else
		local probe_pid probe_tmpfile
		probe_tmpfile=$(mktemp)
		push_cleanup "rm -f '${probe_tmpfile}'"
		("${probe_cmd[@]}" >"$probe_tmpfile" 2>&1) &
		probe_pid=$!
		local waited=0
		while kill -0 "$probe_pid" 2>/dev/null && [[ "$waited" -lt 15 ]]; do
			sleep 1
			waited=$((waited + 1))
		done
		if kill -0 "$probe_pid" 2>/dev/null; then
			kill "$probe_pid" 2>/dev/null || true
			wait "$probe_pid" 2>/dev/null || true
			probe_exit=124
		else
			wait "$probe_pid" 2>/dev/null || true
			probe_exit=$?
		fi
		probe_result=$(cat "$probe_tmpfile" 2>/dev/null || true)
		rm -f "$probe_tmpfile"
	fi

	# Check for known failure patterns (t233: distinguish quota/rate-limit from generic failures)
	if echo "$probe_result" | grep -qiE 'CreditsError|Insufficient balance'; then
		log_warn "Model health check FAILED: billing/credits exhausted (slow path)"
		return 3 # t233: credits = invalid key equivalent (won't resolve without human action)
	fi
	if echo "$probe_result" | grep -qiE 'Quota protection|over[_ -]?usage|quota reset|429|too many requests|rate.limit'; then
		log_warn "Model health check FAILED: quota/rate limited (slow path)"
		return 2 # t233: rate-limited = defer dispatch, retry soon
	fi
	if echo "$probe_result" | grep -qiE 'endpoints failed|"status":[[:space:]]*503|HTTP 503|503 Service|service unavailable'; then
		log_warn "Model health check FAILED: provider error detected (slow path)"
		return 1
	fi

	if [[ "$probe_exit" -eq 124 ]]; then
		log_warn "Model health check FAILED: timeout (15s)"
		return 1
	fi

	if [[ -z "$probe_result" && "$probe_exit" -ne 0 ]]; then
		log_warn "Model health check FAILED: empty response (exit $probe_exit)"
		return 1
	fi

	# Healthy - cache the result
	date +%s >"$cache_file"
	_PULSE_HEALTH_VERIFIED="true"
	log_info "Model health: OK (cached for 5m)"
	return 0
}

#######################################
# Generate a worker-specific MCP config with heavy indexers disabled (t221, t1162)
#
# Workers inherit the global MCP config which may have osgrep enabled.
# osgrep indexes the entire codebase on startup, consuming ~4 CPU cores
# per worker. With 3-4 concurrent workers, that's 12-16 cores wasted on
# indexing that workers don't need (they have rg/grep/read tools).
#
# CLI-aware behavior (t1162):
#   opencode: Copies ~/.config/opencode/opencode.json to a per-worker temp
#             directory with heavy indexers disabled. Returns XDG_CONFIG_HOME
#             path. Caller sets XDG_CONFIG_HOME env var.
#   claude:   Generates a standalone mcpServers JSON file for --mcp-config
#             --strict-mcp-config flags. Sources MCP servers from the user's
#             Claude settings (~/.claude/settings.json) and project .mcp.json,
#             filtering out heavy indexers. Returns the JSON file path.
#
# Args:
#   $1 = task_id (used for directory naming)
#   $2 = ai_cli (optional, default: "opencode") — "opencode" or "claude"
# Outputs: config path on stdout (XDG_CONFIG_HOME for opencode, JSON file for claude)
# Returns: 0 on success, 1 on failure (caller should proceed without override)
#######################################
generate_worker_mcp_config() {
	local task_id="$1"
	local ai_cli="${2:-opencode}"
	local repo_root="${3:-}"

	if ! command -v jq &>/dev/null; then
		log_warn "jq not available — cannot generate worker MCP config"
		return 1
	fi

	local worker_config_dir="${SUPERVISOR_DIR}/pids/${task_id}-config"
	mkdir -p "$worker_config_dir"

	if [[ "$ai_cli" == "claude" ]]; then
		_generate_worker_mcp_config_claude "$task_id" "$worker_config_dir" "$repo_root"
	else
		_generate_worker_mcp_config_opencode "$task_id" "$worker_config_dir"
	fi
	return $?
}

#######################################
# Generate worker MCP config for OpenCode CLI (t221)
# Internal helper — called by generate_worker_mcp_config()
#######################################
_generate_worker_mcp_config_opencode() {
	local task_id="$1"
	local worker_config_dir="$2"

	local user_config="$HOME/.config/opencode/opencode.json"
	if [[ ! -f "$user_config" ]]; then
		log_warn "No opencode.json found at $user_config — skipping worker MCP override"
		return 1
	fi

	local opencode_dir="${worker_config_dir}/opencode"
	mkdir -p "$opencode_dir"

	# Copy and modify: disable heavy indexing MCPs
	# osgrep: local semantic search, spawns indexer (~4 CPU cores)
	# augment-context-engine: another semantic indexer
	jq '
		# Disable heavy indexing MCP servers for workers
		.mcp["osgrep"].enabled = false |
		.mcp["augment-context-engine"].enabled = false |
		# Also disable their tools to avoid tool-not-found errors
		.tools["osgrep_*"] = false |
		.tools["augment-context-engine_*"] = false
	' "$user_config" >"$opencode_dir/opencode.json"

	# Validate the generated config is valid JSON
	if ! jq empty "$opencode_dir/opencode.json" 2>/dev/null; then
		log_warn "Generated worker OpenCode config is invalid JSON — removing"
		rm -f "$opencode_dir/opencode.json"
		return 1
	fi

	# Return the parent of the opencode/ dir (XDG_CONFIG_HOME points to the
	# directory that *contains* the opencode/ subdirectory)
	echo "$worker_config_dir"
	return 0
}

#######################################
# Generate worker MCP config for Claude CLI (t1162)
# Internal helper — called by generate_worker_mcp_config()
#
# Builds a standalone JSON file with mcpServers for --mcp-config flag.
# Used with --strict-mcp-config to ensure workers ONLY get the specified
# MCP servers, not the user's full global set.
#
# MCP server sources (merged, deduplicated):
#   1. User's Claude settings: ~/.claude/settings.json (mcpServers key)
#   2. Project-level .mcp.json (if present in the repo)
#   3. Deployed MCP templates: ~/.aidevops/agents/configs/mcp-templates/
#      (only servers with claude_code_command entries)
#
# Heavy indexers are filtered out:
#   - osgrep (spawns indexer, ~4 CPU cores)
#   - augment-context-engine (another semantic indexer)
#
# Output format matches Claude CLI --mcp-config expectation:
#   { "mcpServers": { "name": { "command": "...", "args": [...], "env": {...} } } }
#######################################
_generate_worker_mcp_config_claude() {
	local task_id="$1"
	local worker_config_dir="$2"
	local repo_root="${3:-}"

	local config_file="${worker_config_dir}/claude-mcp-config.json"

	# Heavy indexer server names to exclude
	local -a excluded_servers=("osgrep" "augment-context-engine")

	# Start with empty mcpServers object
	local merged_config='{"mcpServers":{}}'

	# Source 1: User's Claude settings (~/.claude/settings.json)
	local claude_settings="$HOME/.claude/settings.json"
	if [[ -f "$claude_settings" ]]; then
		local user_servers
		user_servers=$(jq -r '.mcpServers // empty' "$claude_settings") || true
		if [[ -n "$user_servers" && "$user_servers" != "null" ]]; then
			merged_config=$(echo "$merged_config" | jq --argjson servers "$user_servers" '
				.mcpServers = (.mcpServers + $servers)
			') || true
		fi
	fi

	# Source 2: Project-level .mcp.json (check repo root, then cwd)
	# Workers run in worktrees, so use the passed repo_root for .mcp.json resolution
	local -a mcp_json_paths=()
	if [[ -n "$repo_root" ]]; then
		mcp_json_paths+=("$repo_root/.mcp.json")
	fi
	mcp_json_paths+=("./.mcp.json")
	for mcp_json in "${mcp_json_paths[@]}"; do
		if [[ -f "$mcp_json" ]]; then
			local project_servers
			project_servers=$(jq -r '.mcpServers // empty' "$mcp_json") || true
			if [[ -n "$project_servers" && "$project_servers" != "null" ]]; then
				merged_config=$(echo "$merged_config" | jq --argjson servers "$project_servers" '
					.mcpServers = (.mcpServers + $servers)
				') || true
			fi
			break # Use first found
		fi
	done

	# Filter out heavy indexers in a single pass
	merged_config=$(echo "$merged_config" | jq 'del(.mcpServers[$ARGS.positional[]])' --args "${excluded_servers[@]}") || true

	# Write the config file
	echo "$merged_config" | jq '.' >"$config_file"

	# Validate the generated config is valid JSON with mcpServers key
	if ! jq -e '.mcpServers' "$config_file" &>/dev/null; then
		log_warn "Generated worker Claude MCP config is invalid — removing"
		rm -f "$config_file"
		return 1
	fi

	local server_count
	server_count=$(jq '.mcpServers | length' "$config_file" 2>/dev/null || echo "0")
	log_verbose "Generated Claude worker MCP config: $config_file ($server_count servers, excluded: ${excluded_servers[*]})"

	echo "$config_file"
	return 0
}

#######################################
# Build a CLI-specific command from semantic parameters (t1160.1)
#
# Centralises the opencode-vs-claude if/else branching that was previously
# duplicated across build_dispatch_cmd, build_verify_dispatch_cmd,
# do_prompt_repeat, cmd_reprompt, check_cli_health, and check_model_health.
#
# Output modes:
#   "nul"   — NUL-delimited (\0) tokens on stdout (for process-substitution reads)
#   "array" — space-separated %q-quoted tokens on stdout (for eval into arrays)
#
# Supported actions:
#   "run"     — dispatch a worker with a prompt
#   "version" — CLI version/health check
#   "probe"   — lightweight health probe ("Reply with exactly: OK")
#
# Args (passed as named flags for clarity):
#   --cli <opencode|claude>   (required)
#   --action <run|version|probe>  (required)
#   --output <nul|array>      (default: nul)
#   --model <provider/model>  (optional, for run/probe)
#   --title <session-title>   (optional, for run — opencode only)
#   --prompt <text>           (required for run, ignored for version)
#   --mcp-config <path>       (optional, for run — claude only, t1162)
#                              Path to MCP config JSON for --mcp-config --strict-mcp-config
#
# Returns: 0 on success, 1 on invalid args
#######################################
build_cli_cmd() {
	local cli="" action="" output_mode="nul" model="" title="" prompt="" mcp_config=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--cli)
			cli="$2"
			shift 2
			;;
		--action)
			action="$2"
			shift 2
			;;
		--output)
			output_mode="$2"
			shift 2
			;;
		--model)
			model="$2"
			shift 2
			;;
		--title)
			title="$2"
			shift 2
			;;
		--prompt)
			prompt="$2"
			shift 2
			;;
		--mcp-config)
			mcp_config="$2"
			shift 2
			;;
		*)
			log_error "build_cli_cmd: unknown flag: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$cli" || -z "$action" ]]; then
		log_error "build_cli_cmd: --cli and --action are required"
		return 1
	fi

	# --- Emit helper: handles nul vs array output modes ---
	local -a _tokens=()
	_emit_token() { _tokens+=("$1"); }

	# --- Build tokens based on action + CLI ---
	case "$action" in
	run)
		if [[ -z "$prompt" ]]; then
			log_error "build_cli_cmd: --prompt required for action=run"
			return 1
		fi
		if [[ "$cli" == "opencode" ]]; then
			_emit_token "opencode"
			_emit_token "run"
			_emit_token "--format"
			_emit_token "json"
			if [[ -n "$model" ]]; then
				_emit_token "-m"
				_emit_token "$model"
			fi
			if [[ -n "$title" ]]; then
				_emit_token "--title"
				_emit_token "$title"
			fi
			_emit_token "$prompt"
		else
			# claude CLI
			_emit_token "claude"
			_emit_token "-p"
			_emit_token "$prompt"
			if [[ -n "$model" ]]; then
				# claude CLI uses bare model name (strip provider/ prefix)
				local claude_model="${model#*/}"
				_emit_token "--model"
				_emit_token "$claude_model"
			fi
			_emit_token "--output-format"
			_emit_token "json"
			# t1162: Worker MCP isolation — pass --mcp-config and --strict-mcp-config
			# to ensure workers only get specified MCP servers, not the user's full set
			if [[ -n "$mcp_config" ]]; then
				_emit_token "--mcp-config"
				_emit_token "$mcp_config"
				_emit_token "--strict-mcp-config"
			fi
		fi
		;;
	version)
		if [[ "$cli" == "opencode" ]]; then
			_emit_token "opencode"
			_emit_token "version"
		else
			_emit_token "claude"
			_emit_token "--version"
		fi
		;;
	probe)
		if [[ "$cli" == "opencode" ]]; then
			_emit_token "opencode"
			_emit_token "run"
			_emit_token "--format"
			_emit_token "json"
			if [[ -n "$model" ]]; then
				_emit_token "-m"
				_emit_token "$model"
			fi
			_emit_token "--title"
			_emit_token "health-check"
			_emit_token "Reply with exactly: OK"
		else
			_emit_token "claude"
			_emit_token "-p"
			_emit_token "Reply with exactly: OK"
			_emit_token "--output-format"
			_emit_token "text"
			if [[ -n "$model" ]]; then
				local claude_model="${model#*/}"
				_emit_token "--model"
				_emit_token "$claude_model"
			fi
		fi
		;;
	*)
		log_error "build_cli_cmd: unknown action: $action"
		return 1
		;;
	esac

	# --- Output tokens in requested format ---
	case "$output_mode" in
	nul)
		local t
		for t in "${_tokens[@]}"; do
			printf '%s\0' "$t"
		done
		;;
	array)
		printf '%q ' "${_tokens[@]}"
		;;
	*)
		log_error "build_cli_cmd: unknown output mode: $output_mode"
		return 1
		;;
	esac

	return 0
}

#######################################
# Build the dispatch command for a task
# Outputs the command array elements, one per line
# $5 (optional): memory context to inject into the prompt
# $8 (optional): MCP config path for Claude CLI --mcp-config (t1162)
#######################################
build_dispatch_cmd() {
	local task_id="$1"
	local worktree_path="$2"
	local log_file="$3"
	local ai_cli="$4"
	local memory_context="${5:-}"
	local model="${6:-}"
	local description="${7:-}"
	local mcp_config="${8:-}"

	# Include task description in the prompt so the worker knows what to do
	# even if TODO.md doesn't have an entry for this task (t158)
	# Always pass --headless for supervisor-dispatched workers (t174)
	# Inject explicit TODO.md restriction into worker prompt (t173)
	local prompt="/full-loop $task_id --headless"
	if [[ -n "$description" ]]; then
		prompt="/full-loop $task_id --headless -- $description"
	fi

	# t173: Explicit worker restriction — prevents TODO.md race condition
	# t176: Uncertainty decision framework for headless workers
	prompt="$prompt

## MANDATORY Worker Restrictions (t173)
- Do NOT edit, commit, or push TODO.md — the supervisor owns all TODO.md updates.
- Do NOT edit todo/PLANS.md or todo/tasks/* — these are supervisor-managed.
- Report status via exit code, log output, and PR creation only.
- Put task notes in commit messages or PR body, never in TODO.md.

## Uncertainty Decision Framework (t176)
You are a headless worker with no human at the terminal. Use this framework when uncertain:

**PROCEED autonomously when:**
- Multiple valid approaches exist but all achieve the goal (pick the simplest)
- Style/naming choices are ambiguous (follow existing conventions in the codebase)
- Task description is slightly vague but intent is clear from context
- You need to choose between equivalent libraries/patterns (match project precedent)
- Minor scope questions (e.g., should I also fix this adjacent issue?) — stay focused on the assigned task

**FLAG uncertainty and exit cleanly when:**
- The task description contradicts what you find in the codebase
- Completing the task would require breaking changes to public APIs or shared interfaces
- You discover the task is already done or obsolete
- Required dependencies, credentials, or services are missing and cannot be inferred
- The task requires decisions that would significantly affect architecture or other tasks
- You are unsure whether a file should be created vs modified, and getting it wrong would cause data loss

**When you proceed autonomously**, document your decision in the commit message:
\`feat: add retry logic (chose exponential backoff over linear — matches existing patterns in src/utils/retry.ts)\`

**When you exit due to uncertainty**, include a clear explanation in your final output:
\`BLOCKED: Task says 'update the auth endpoint' but there are 3 auth endpoints (JWT, OAuth, API key). Need clarification on which one.\`

## Worker Efficiency Protocol

Maximise your output per token. Follow these practices to avoid wasted work:

**1. Decompose with TodoWrite (MANDATORY)**
At the START of your session, use the TodoWrite tool to break your task into 3-7 subtasks.
Your LAST subtask must ALWAYS be: 'Push branch and create PR via gh pr create'.
Example for 'add retry logic to API client':
- Research: read existing API client code and error handling patterns
- Implement: add retry with exponential backoff to the HTTP client
- Test: write unit tests for retry behaviour (success, max retries, backoff timing)
- Integrate: update callers if the API surface changed
- Verify: run linters, shellcheck, and existing tests
- Deliver: push branch and create PR via gh pr create

Mark each subtask in_progress when you start it and completed when done.
Only have ONE subtask in_progress at a time.

**2. Commit early, commit often (CRITICAL — prevents lost work)**
After EACH implementation subtask, immediately:
\`\`\`bash
git add -A && git commit -m 'feat: <what you just did> (<task-id>)'
\`\`\`
Do NOT wait until all subtasks are done. If your session ends unexpectedly (context
exhaustion, crash, timeout), uncommitted work is LOST. Committed work survives.

After your FIRST commit, push and create a draft PR immediately:
\`\`\`bash
git push -u origin HEAD
# t288: Include GitHub issue reference in PR body when task has ref:GH# in TODO.md
# Look up: grep -oE 'ref:GH#[0-9]+' TODO.md for your task ID, extract the number
# If found, add 'Ref #NNN' to the PR body so GitHub cross-links the issue
gh_issue=\$(grep -E '^\s*- \[.\] <task-id> ' TODO.md 2>/dev/null | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || true)
pr_body='WIP - incremental commits'
[[ -n \"\$gh_issue\" ]] && pr_body=\"\${pr_body}

Ref #\${gh_issue}\"
gh pr create --draft --title '<task-id>: <description>' --body \"\$pr_body\"
\`\`\`
Subsequent commits just need \`git push\`. The PR already exists.
This ensures the supervisor can detect your PR even if you run out of context.
The \`Ref #NNN\` line cross-links the PR to its GitHub issue for auditability.

When ALL implementation is done, mark the PR as ready for review:
\`\`\`bash
gh pr ready
\`\`\`
If you run out of context before this step, the supervisor will auto-promote
your draft PR after detecting your session has ended.

**3. ShellCheck gate before push (MANDATORY for .sh files — t234)**
Before EVERY \`git push\`, check if your commits include \`.sh\` files:
\`\`\`bash
sh_files=\$(git diff --name-only origin/HEAD..HEAD 2>/dev/null | grep '\\.sh\$' || true)
if [[ -n \"\$sh_files\" ]]; then
  echo \"Running ShellCheck on modified .sh files...\"
  sc_failed=0
  while IFS= read -r f; do
    [[ -f \"\$f\" ]] || continue
    if ! shellcheck -x -S warning \"\$f\"; then
      sc_failed=1
    fi
  done <<< \"\$sh_files\"
  if [[ \"\$sc_failed\" -eq 1 ]]; then
    echo \"ShellCheck violations found — fix before pushing.\"
    # Fix the violations, then git add -A && git commit --amend --no-edit
  fi
fi
\`\`\`
This catches CI failures 5-10 min earlier. Do NOT push .sh files with ShellCheck violations.
If \`shellcheck\` is not installed, skip this gate and note it in the PR body.

**3b. PR title MUST contain task ID (MANDATORY — t318.2)**
When creating a PR, the title MUST start with the task ID: \`<task-id>: <description>\`.
Example: \`t318.2: Verify supervisor worker PRs include task ID\`
The CI pipeline and supervisor both validate this. PRs without task IDs fail the check.
If you used \`gh pr create --draft --title '<task-id>: <description>'\` as instructed above,
this is already handled. This note reinforces: NEVER omit the task ID from the PR title.

**4. Offload research to ai_research tool (saves context for implementation)**
Reading large files (500+ lines) consumes your context budget fast. Instead of reading
entire files yourself, call the \`ai_research\` MCP tool with a focused question:
\`\`\`
ai_research(prompt: \"Find all functions that dispatch workers in supervisor-helper.sh. Return: function name, line number, key variables.\", domain: \"orchestration\")
\`\`\`
The tool spawns a sub-worker via the Anthropic API with its own context window.
You get a concise answer that costs ~100 tokens instead of ~5000 from reading directly.
Rate limit: 10 calls per session. Default model: haiku (cheapest).

**Domain shorthand** — auto-resolves to relevant agent files:
| Domain | Agents loaded |
|--------|--------------|
| git | git-workflow, github-cli, conflict-resolution |
| planning | plans, beads |
| code | code-standards, code-simplifier |
| seo | seo, dataforseo, google-search-console |
| content | content, research, writing |
| wordpress | wp-dev, mainwp |
| browser | browser-automation, playwright |
| deploy | coolify, coolify-cli, vercel |
| security | tirith, encryption-stack |
| mcp | build-mcp, server-patterns |
| agent | build-agent, agent-review |
| framework | architecture, setup |
| release | release, version-bump |
| pr | pr, preflight |
| orchestration | headless-dispatch |
| context | model-routing, toon, mcp-discovery |
| video | video-prompt-design, remotion, wavespeed |
| voice | speech-to-speech, voice-bridge |
| mobile | agent-device, maestro |
| hosting | hostinger, cloudflare, hetzner |
| email | email-testing, email-delivery-test |
| accessibility | accessibility, accessibility-audit |
| containers | orbstack |
| vision | overview, image-generation |

**Parameters**: \`prompt\` (required), \`domain\` (shorthand above), \`agents\` (comma-separated paths relative to ~/.aidevops/agents/), \`files\` (paths with optional line ranges e.g. \"src/foo.ts:10-50\"), \`model\` (haiku|sonnet|opus), \`max_tokens\` (default 500, max 4096).

**When to offload**: Any time you would read >200 lines of a file you don't plan to edit,
or when you need to understand a codebase pattern across multiple files.

**When NOT to offload**: When you need to edit the file (you must read it yourself for
the Edit tool to work), or when the answer is a simple grep/rg query.

**5. Parallel sub-work (MANDATORY when applicable)**
After creating your TodoWrite subtasks, check: do any two subtasks modify DIFFERENT files?
If yes, you SHOULD parallelise where possible. Use \`ai_research\` for read-only research
tasks that don't require file edits.

**Decision heuristic**: If your TodoWrite has 3+ subtasks and any two don't modify the same
files, the independent ones can run in parallel. Common parallelisable patterns:
- Use \`ai_research\` to understand a codebase pattern while you implement in another file
- Run \`ai_research(domain: \"code\")\` to check conventions while writing new code

**Do NOT parallelise when**: subtasks modify the same file, or subtask B depends on
subtask A's output (e.g., B imports a function A creates). When in doubt, run sequentially.

**6. Fail fast, not late**
Before writing any code, verify your assumptions:
- Read the files you plan to modify (stale assumptions waste entire sessions)
- Check that dependencies/imports you plan to use actually exist in the project
- If the task seems already done, EXIT immediately with explanation — don't redo work

**7. Minimise token waste**
- Don't read entire large files — use line ranges from search results
- Don't output verbose explanations in commit messages — be concise
- If an approach fails, try ONE fundamentally different strategy before exiting BLOCKED

**8. Replan when stuck, don't patch**
If your first approach isn't working, step back and consider a fundamentally different
strategy instead of incrementally patching the broken approach. A fresh approach often
succeeds where incremental fixes fail. Only exit with BLOCKED after trying at least one
alternative strategy.

## Completion Self-Check (MANDATORY before FULL_LOOP_COMPLETE)

Before emitting FULL_LOOP_COMPLETE or marking task complete, you MUST:

1. **Requirements checklist**: List every requirement from the task description as a
   numbered checklist. Mark each [DONE] or [TODO]. If ANY are [TODO], do NOT mark
   complete — keep working.

2. **Verification run**: Execute available verification:
   - Run tests if the project has them
   - Run shellcheck on any .sh files you modified
   - Run lint/typecheck if configured
   - Confirm output files exist and have expected content

3. **Generalization check**: Would your solution still work if input values, file
   contents, or dimensions changed? If you hardcoded something that should be
   parameterized, fix it before completing.

4. **Minimal state changes**: Only create or modify files explicitly required by the
   task. Do not leave behind extra files, modified configs, or side effects that were
   not requested.

FULL_LOOP_COMPLETE is IRREVERSIBLE and FINAL. You have unlimited iterations but only
one submission. Extra verification costs nothing; a wrong completion wastes an entire
retry cycle."

	if [[ -n "$memory_context" ]]; then
		prompt="$prompt

$memory_context"
	fi

	# t262: Include truncated description in session title for readability
	local session_title="$task_id"
	if [[ -n "$description" ]]; then
		local short_desc="${description%% -- *}" # strip notes after --
		short_desc="${short_desc%% #*}"          # strip tags
		short_desc="${short_desc%% ~*}"          # strip estimates
		if [[ ${#short_desc} -gt 40 ]]; then
			short_desc="${short_desc:0:37}..."
		fi
		session_title="${task_id}: ${short_desc}"
	fi

	# t1160.1: Delegate CLI-specific command building to build_cli_cmd()
	local -a _build_args=(
		--cli "$ai_cli"
		--action run
		--output nul
		--model "$model"
		--title "$session_title"
		--prompt "$prompt"
	)
	# t1162: Pass MCP config for Claude CLI worker isolation
	if [[ -n "$mcp_config" ]]; then
		_build_args+=(--mcp-config "$mcp_config")
	fi
	build_cli_cmd "${_build_args[@]}"

	return 0
}

#######################################
# build_verify_dispatch_cmd() — lightweight verification prompt (t1008)
# Instead of a full implementation prompt, this builds a focused verification
# prompt that checks whether prior work is complete and functional.
# Cost: ~$0.10-0.20 (sonnet, small context) vs ~$1.00 for full implementation.
#
# Arguments:
#   $1 = task_id
#   $2 = worktree_path
#   $3 = log_file
#   $4 = ai_cli (opencode or claude)
#   $5 = memory_context (optional)
#   $6 = model (resolved model string — overridden to sonnet tier)
#   $7 = description
#   $8 = verify_reason (from was_previously_worked)
#   $9 = mcp_config (optional, path to MCP config JSON for Claude CLI, t1162)
#
# Output: NUL-delimited command array (same format as build_dispatch_cmd)
#######################################
build_verify_dispatch_cmd() {
	local task_id="$1"
	local worktree_path="$2"
	local log_file="$3"
	local ai_cli="$4"
	local memory_context="${5:-}"
	local model="${6:-}"
	local description="${7:-}"
	local verify_reason="${8:-}"
	local mcp_config="${9:-}"

	local prompt="/full-loop $task_id --headless --verify"
	if [[ -n "$description" ]]; then
		prompt="/full-loop $task_id --headless --verify -- $description"
	fi

	# Verification-specific prompt — much shorter than full implementation
	prompt="$prompt

## VERIFICATION MODE (t1008)
This task was previously worked on ($verify_reason). You are a lightweight
verification worker — your job is to CHECK whether the prior work is complete
and functional, NOT to reimplement from scratch.

**Your verification checklist:**
1. Check if the feature/fix described in the task already exists in the codebase
2. Run relevant tests (unit tests, ShellCheck for .sh files, syntax checks)
3. Verify integration — does the code work with its callers/dependencies?
4. Check for any partial work that needs completion

**Outcomes — emit exactly ONE of these signals:**
- If work is COMPLETE and verified: emit \`VERIFY_COMPLETE\` in your final output,
  then create a short verification PR (title: '$task_id: Verify — <description>')
  documenting what you verified and the test results. If no code changes needed,
  just report \`VERIFY_COMPLETE\` with evidence in your output.
- If work is INCOMPLETE but salvageable: emit \`VERIFY_INCOMPLETE\` with a summary
  of what's done and what remains. Then continue implementation from where the
  prior worker left off. Commit early and create a PR.
- If work is NOT STARTED or fundamentally broken: emit \`VERIFY_NOT_STARTED\`.
  Then proceed with full implementation as a normal worker would.

**Cost-saving rules:**
- Do NOT read files you don't need — focus on the specific deliverables
- Do NOT refactor or improve code beyond what the task requires
- If verification takes <5 minutes of checks, that's ideal
- Commit and push any changes immediately

## MANDATORY Worker Restrictions (t173)
- Do NOT edit, commit, or push TODO.md — the supervisor owns all TODO.md updates.
- Do NOT edit todo/PLANS.md or todo/tasks/* — these are supervisor-managed.
- Report status via exit code, log output, and PR creation only.
- Put task notes in commit messages or PR body, never in TODO.md."

	if [[ -n "$memory_context" ]]; then
		prompt="$prompt

$memory_context"
	fi

	local session_title="${task_id}-verify"
	if [[ -n "$description" ]]; then
		local short_desc="${description%% -- *}"
		short_desc="${short_desc%% #*}"
		short_desc="${short_desc%% ~*}"
		if [[ ${#short_desc} -gt 30 ]]; then
			short_desc="${short_desc:0:27}..."
		fi
		session_title="${task_id}-verify: ${short_desc}"
	fi

	# t1160.1: Delegate CLI-specific command building to build_cli_cmd()
	local -a _build_args=(
		--cli "$ai_cli"
		--action run
		--output nul
		--model "$model"
		--title "$session_title"
		--prompt "$prompt"
	)
	# t1162: Pass MCP config for Claude CLI worker isolation
	if [[ -n "$mcp_config" ]]; then
		_build_args+=(--mcp-config "$mcp_config")
	fi
	build_cli_cmd "${_build_args[@]}"

	return 0
}

#######################################
# Dispatch a single task
# Creates worktree, starts worker, updates DB
#######################################
cmd_dispatch() {
	local task_id="" batch_id=""

	# First positional arg is task_id
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--batch)
			[[ $# -lt 2 ]] && {
				log_error "--batch requires a value"
				return 1
			}
			batch_id="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh dispatch <task_id>"
		return 1
	fi

	ensure_db

	# Get task details
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator $'\t' "$SUPERVISOR_DB" "
        SELECT id, repo, description, status, model, retries, max_retries
        FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local _tid trepo tdesc tstatus tmodel tretries tmax_retries
	IFS=$'\t' read -r _tid trepo tdesc tstatus tmodel tretries tmax_retries <<<"$task_row"

	# Validate task is in dispatchable state
	if [[ "$tstatus" != "queued" ]]; then
		log_error "Task $task_id is in '$tstatus' state, must be 'queued' to dispatch"
		return 1
	fi

	# t1239: Pre-dispatch cross-repo validation.
	# Verify the task's registered repo actually contains this task in its TODO.md.
	# This is the last line of defence against cross-repo misregistration — if a task
	# from a private repo (e.g., awardsapp) was registered under the wrong repo path
	# (e.g., aidevops), the worker would run in the wrong codebase. Cancel instead.
	local dispatch_todo_file="${trepo:-.}/TODO.md"
	if [[ -n "$trepo" && -f "$dispatch_todo_file" ]]; then
		local task_in_registered_repo
		task_in_registered_repo=$(grep -cE "^[[:space:]]*- \[.\] $task_id( |$)" "$dispatch_todo_file" 2>/dev/null | head -1 || echo 0)
		if [[ "${task_in_registered_repo:-0}" -eq 0 ]]; then
			log_error "Cross-repo misregistration detected at dispatch: $task_id not found in $(basename "$trepo") TODO.md ($dispatch_todo_file) — cancelling to prevent wrong-repo worker spawn (t1239)"
			db "$SUPERVISOR_DB" "UPDATE tasks SET status='cancelled', error='Cross-repo misregistration: task not found in registered repo TODO.md (t1239)' WHERE id='$(sql_escape "$task_id")';"
			return 1
		fi
	fi

	# Pre-dispatch verification: check if task was already completed in a prior batch.
	# Searches git history for commits referencing this task ID. If a merged PR commit
	# exists, the task is already done — cancel it instead of wasting an Opus session.
	# This prevents the exact bug from backlog-10 where 6 t135 subtasks were dispatched
	# despite being completed months earlier.
	if check_task_already_done "$task_id" "${trepo:-.}"; then
		log_warn "Task $task_id appears already completed in git history — cancelling"
		db "$SUPERVISOR_DB" "UPDATE tasks SET status='cancelled', error='Pre-dispatch: already completed in git history' WHERE id='$(sql_escape "$task_id")';"
		return 0
	fi

	# Pre-dispatch reverification: detect previously-worked tasks (t1008)
	# If a task was dispatched before (dead worker, unclaimed, re-queued, quality
	# escalation), dispatch a lightweight verify worker instead of full implementation.
	# Cost: ~$0.10-0.20 (sonnet) vs ~$1.00 (full session). The verify worker checks
	# if deliverables exist and work; if incomplete, it continues implementation.
	local verify_mode="" verify_reason=""
	if [[ "${SUPERVISOR_SKIP_VERIFY_MODE:-false}" != "true" ]]; then
		# Skip verify mode if the last error was verify_not_started_needs_full —
		# the verify worker already confirmed no prior work exists, so a full
		# implementation dispatch is needed (avoids infinite verify loop).
		local last_error=""
		last_error=$(db "$SUPERVISOR_DB" "SELECT COALESCE(error, '') FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null) || last_error=""
		if [[ "$last_error" == "verify_not_started_needs_full" || "$last_error" == "verify_incomplete_no_pr" ]]; then
			log_info "Task $task_id: skipping verify mode (last error: $last_error) — using full dispatch"
		else
			verify_reason=$(was_previously_worked "$task_id" 2>/dev/null) || true
			if [[ -n "$verify_reason" ]]; then
				verify_mode="true"
				log_info "Task $task_id was previously worked ($verify_reason) — using verify dispatch mode (t1008)"
			fi
		fi
	fi

	# Check if task is claimed by someone else via TODO.md assignee: field (t165)
	local claimed_by=""
	claimed_by=$(check_task_claimed "$task_id" "${trepo:-.}" 2>/dev/null) || true
	if [[ -n "$claimed_by" ]]; then
		# t1024: Check if the claim is stale (no active worker, claimed >2h ago)
		# This prevents tasks from being stuck forever when a worker dies
		local stale_threshold_seconds=7200 # 2 hours
		local is_stale="false"

		# Check if there's an active worker process for this task
		local active_session=""
		local escaped_id
		escaped_id=$(sql_escape "$task_id")
		active_session=$(db "$SUPERVISOR_DB" "SELECT session_id FROM tasks WHERE id = '$escaped_id' AND session_id IS NOT NULL AND status IN ('dispatched','running');" 2>/dev/null) || active_session=""

		if [[ -z "$active_session" ]]; then
			# No active worker — check how long the claim has been held
			local todo_file="${trepo:-.}/TODO.md"
			local task_line=""
			task_line=$(grep -m1 "^[[:space:]]*- \[ \] $task_id " "$todo_file" 2>/dev/null) || task_line=""
			if [[ -n "$task_line" ]]; then
				local started_ts=""
				started_ts=$(echo "$task_line" | sed -n 's/.*started:\([0-9T:Z-]*\).*/\1/p' 2>/dev/null) || started_ts=""
				if [[ -n "$started_ts" ]]; then
					local started_epoch now_epoch
					started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_ts" "+%s" 2>/dev/null) ||
						started_epoch=$(date -d "$started_ts" "+%s" 2>/dev/null) || started_epoch=0
					now_epoch=$(date "+%s")
					if [[ "$started_epoch" -gt 0 ]] && ((now_epoch - started_epoch > stale_threshold_seconds)); then
						is_stale="true"
					fi
				else
					# No started: timestamp but claimed — treat as stale if task is queued in DB
					local db_status=""
					db_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';" 2>/dev/null) || db_status=""
					if [[ "$db_status" == "queued" ]]; then
						is_stale="true"
					fi
				fi
			fi
		fi

		if [[ "$is_stale" == "true" ]]; then
			log_warn "Task $task_id: stale claim by assignee:$claimed_by (no active worker, >2h) — auto-unclaiming (t1024)"
			cmd_unclaim "$task_id" "${trepo:-.}" --force 2>/dev/null || true
		else
			log_warn "Task $task_id is claimed by assignee:$claimed_by — skipping dispatch"
			return 0
		fi
	fi

	# Claim the task before dispatching (t165 — TODO.md primary, GH Issue sync optional)
	# CRITICAL: abort dispatch if claim fails (race condition = another worker claimed first)
	# Pass trepo so claim works from cron (where $PWD != repo dir)
	if ! cmd_claim "$task_id" "${trepo:-.}"; then
		log_error "Failed to claim $task_id — aborting dispatch"
		return 1
	fi

	# Authoritative concurrency check with adaptive load awareness (t151, t172)
	# This is the single source of truth for concurrency enforcement.
	# cmd_next() intentionally does NOT check concurrency to avoid a TOCTOU race
	# where the count becomes stale between cmd_next() and cmd_dispatch() calls
	# within the same pulse loop.
	if [[ -n "$batch_id" ]]; then
		local escaped_batch
		escaped_batch=$(sql_escape "$batch_id")
		local base_concurrency max_load_factor batch_max_concurrency
		base_concurrency=$(db "$SUPERVISOR_DB" "SELECT concurrency FROM batches WHERE id = '$escaped_batch';")
		max_load_factor=$(db "$SUPERVISOR_DB" "SELECT max_load_factor FROM batches WHERE id = '$escaped_batch';")
		batch_max_concurrency=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_concurrency, 0) FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "0")
		local concurrency
		concurrency=$(calculate_adaptive_concurrency "${base_concurrency:-4}" "${max_load_factor:-2}" "${batch_max_concurrency:-0}")
		local active_count
		active_count=$(cmd_running_count "$batch_id")

		if [[ "$active_count" -ge "$concurrency" ]]; then
			log_warn "Concurrency limit reached ($active_count/$concurrency, base:$base_concurrency, adaptive) for batch $batch_id"
			return 2
		fi
	else
		# Global concurrency check with adaptive load awareness (t151)
		local base_global_concurrency="${SUPERVISOR_MAX_CONCURRENCY:-4}"
		local global_concurrency
		global_concurrency=$(calculate_adaptive_concurrency "$base_global_concurrency")
		local global_active
		global_active=$(cmd_running_count)
		if [[ "$global_active" -ge "$global_concurrency" ]]; then
			log_warn "Global concurrency limit reached ($global_active/$global_concurrency, base:$base_global_concurrency)"
			return 2
		fi
	fi

	# Check max retries
	if [[ "$tretries" -ge "$tmax_retries" ]]; then
		log_error "Task $task_id has exceeded max retries ($tretries/$tmax_retries)"
		cmd_transition "$task_id" "failed" --error "Max retries exceeded"
		return 1
	fi

	# Dispatch deduplication guard (t1206): prevent re-dispatch of tasks that failed
	# with the same error within a short window. Avoids token waste on repeating failures.
	local dedup_rc=0
	check_dispatch_dedup_guard "$task_id" || dedup_rc=$?
	if [[ "$dedup_rc" -eq 1 ]]; then
		# Task was transitioned to blocked by the guard — abort dispatch
		return 1
	elif [[ "$dedup_rc" -eq 2 ]]; then
		# Cooldown active — defer to next pulse (return 3 = provider-style deferral)
		return 3
	fi

	# Resolve AI CLI (initial — may be re-resolved after model resolution for OAuth routing)
	local ai_cli
	ai_cli=$(resolve_ai_cli) || return 1

	# Pre-dispatch CLI health check (t1113): verify the AI CLI binary exists and
	# can execute before creating worktrees and spawning workers. This prevents
	# the "worker_never_started:no_sentinel" failure pattern where the CLI is
	# invoked but never produces output due to environment issues (missing binary,
	# broken installation, PATH misconfiguration). Deferring here avoids burning
	# retries on environment problems that won't resolve between retry attempts.
	local cli_health_exit=0 cli_health_detail=""
	cli_health_detail=$(check_cli_health "$ai_cli") || cli_health_exit=$?
	if [[ "$cli_health_exit" -ne 0 ]]; then
		log_error "CLI health check failed for $task_id ($ai_cli): $cli_health_detail — deferring dispatch"
		log_error "Fix: ensure '$ai_cli' is installed and in PATH, then retry"
		return 3 # Defer to next pulse (same as provider unavailable)
	fi

	# Pre-dispatch model availability check (t233 — replaces simple health check)
	# Calls model-availability-helper.sh check before spawning workers.
	# Distinct exit codes prevent wasted dispatch attempts:
	#   exit 0 = healthy, proceed
	#   exit 1 = provider unavailable, defer dispatch
	#   exit 2 = rate limited, defer dispatch (retry next pulse)
	#   exit 3 = API key invalid/credits exhausted, block dispatch
	# Previously: 9 wasted failures from ambiguous_ai_unavailable + backend_quota_error
	# because the health check collapsed all failures to a single exit code.
	local health_model health_exit=0
	health_model=$(resolve_model "health" "$ai_cli")
	check_model_health "$ai_cli" "$health_model" || health_exit=$?
	if [[ "$health_exit" -ne 0 ]]; then
		case "$health_exit" in
		2)
			log_warn "Provider rate-limited for $task_id ($health_model via $ai_cli) — deferring dispatch to next pulse"
			return 3 # Return 3 = provider unavailable (distinct from concurrency limit 2)
			;;
		3)
			log_error "API key invalid/credits exhausted for $task_id ($health_model via $ai_cli) — blocking dispatch"
			log_error "Human action required: check API key or billing. Task will not auto-retry."
			return 3
			;;
		*)
			log_error "Provider unavailable for $task_id ($health_model via $ai_cli) — deferring dispatch"
			return 3
			;;
		esac
	fi

	# Pre-dispatch GitHub auth check — verify the worker can push before
	# creating worktrees and burning compute. Workers spawned via nohup/cron
	# may lack SSH keys; gh auth git-credential only works with HTTPS remotes.
	if ! check_gh_auth; then
		log_error "GitHub auth unavailable for $task_id — check_gh_auth failed"
		log_error "Workers need 'gh auth login' or GH_TOKEN set. Skipping dispatch."
		return 3
	fi

	# Verify repo remote uses HTTPS (not SSH) — workers in cron can't use SSH keys
	local remote_url
	remote_url=$(git -C "${trepo:-.}" remote get-url origin 2>/dev/null || echo "")
	if [[ "$remote_url" == git@* || "$remote_url" == ssh://* ]]; then
		log_warn "Remote URL is SSH ($remote_url) — switching to HTTPS for worker compatibility"
		local https_url
		https_url=$(echo "$remote_url" | sed -E 's|^git@github\.com:|https://github.com/|; s|^ssh://git@github\.com/|https://github.com/|; s|\.git$||').git
		git -C "${trepo:-.}" remote set-url origin "$https_url" 2>/dev/null || true
		log_info "Remote URL updated to $https_url"
	fi

	# Create worktree
	log_info "Creating worktree for $task_id..."
	local worktree_path
	worktree_path=$(create_task_worktree "$task_id" "$trepo") || {
		log_error "Failed to create worktree for $task_id"
		cmd_transition "$task_id" "failed" --error "Worktree creation failed"
		return 1
	}

	# Validate worktree path is an actual directory (guards against stdout
	# pollution from git commands inside create_task_worktree)
	if [[ ! -d "$worktree_path" ]]; then
		log_error "Worktree path is not a directory: '$worktree_path'"
		log_error "This usually means a git command leaked stdout into the path variable"
		cmd_transition "$task_id" "failed" --error "Worktree path invalid: $worktree_path"
		return 1
	fi

	local branch_name="feature/${task_id}"

	# Set up log file
	local log_dir="$SUPERVISOR_DIR/logs"
	mkdir -p "$log_dir"
	local log_file
	log_file="$log_dir/${task_id}-$(date +%Y%m%d%H%M%S).log"

	# Pre-create log file with dispatch metadata (t183)
	# If the worker fails to start (opencode not found, permission error, etc.),
	# the log file still exists with context for diagnosis instead of no_log_file.
	# Compute per-task hung timeout for logging (t1199)
	local dispatch_hung_timeout
	dispatch_hung_timeout=$(get_task_hung_timeout "$task_id" 2>/dev/null || echo "1800")
	log_info "Hung timeout for $task_id: ${dispatch_hung_timeout}s (2x estimate, 4h cap, 30m default)"

	{
		echo "=== DISPATCH METADATA (t183) ==="
		echo "task_id=$task_id"
		echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "worktree=$worktree_path"
		echo "branch=$branch_name"
		echo "model=${resolved_model:-${tmodel:-default}}"
		echo "ai_cli=$(resolve_ai_cli 2>/dev/null || echo unknown)"
		echo "dispatch_mode=$(detect_dispatch_mode 2>/dev/null || echo unknown)"
		echo "dispatch_type=${verify_mode:+verify}"
		echo "verify_reason=${verify_reason:-}"
		echo "hung_timeout_seconds=${dispatch_hung_timeout}"
		echo "cli_health=ok"
		echo "=== END DISPATCH METADATA ==="
		echo ""
	} >"$log_file" 2>/dev/null || true

	# Transition to dispatched
	cmd_transition "$task_id" "dispatched" \
		--worktree "$worktree_path" \
		--branch "$branch_name" \
		--log-file "$log_file"

	# Detect dispatch mode
	local dispatch_mode
	dispatch_mode=$(detect_dispatch_mode)

	# Recall relevant memories before dispatch (t128.6)
	local memory_context=""
	memory_context=$(recall_task_memories "$task_id" "$tdesc" 2>/dev/null || echo "")
	if [[ -n "$memory_context" ]]; then
		log_info "Injecting ${#memory_context} bytes of memory context for $task_id"
	fi

	# Resolve model via frontmatter + fallback chain (t132.5)
	# t1008: For verify-mode dispatches, prefer sonnet tier (cheaper, sufficient for
	# verification checks). The verify worker can escalate to full implementation if
	# it discovers the work is incomplete, but starts cheap.
	local resolved_model
	if [[ "$verify_mode" == "true" ]]; then
		resolved_model=$(resolve_model "coding" "$ai_cli" 2>/dev/null) || resolved_model=""
		log_info "Verify mode: using coding-tier model ($resolved_model) instead of task-specific model"
	else
		resolved_model=$(resolve_task_model "$task_id" "$tmodel" "${trepo:-.}" "$ai_cli")
	fi

	# OAuth-aware CLI re-resolution (t1163): now that we know the target model,
	# re-resolve the CLI to potentially route Anthropic models through claude OAuth.
	# This is a no-op if SUPERVISOR_PREFER_OAUTH=false or OAuth is unavailable.
	if [[ "$resolved_model" != "CONTEST" ]]; then
		local oauth_cli
		oauth_cli=$(resolve_ai_cli "$resolved_model" 2>/dev/null) || oauth_cli="$ai_cli"
		if [[ "$oauth_cli" != "$ai_cli" ]]; then
			log_info "OAuth-aware CLI switch for $task_id: $ai_cli -> $oauth_cli (model: $resolved_model) (t1163)"
			ai_cli="$oauth_cli"
			# Re-check CLI health for the new CLI
			local oauth_health_exit=0
			check_cli_health "$ai_cli" >/dev/null 2>&1 || oauth_health_exit=$?
			if [[ "$oauth_health_exit" -ne 0 ]]; then
				log_warn "OAuth CLI ($ai_cli) health check failed — falling back to opencode (t1163)"
				ai_cli="opencode"
			fi
		fi
	fi

	# Record requested vs actual model tiers for cost analysis (t1117)
	# tmodel is the raw model: tag from TODO.md (requested_tier source)
	# resolved_model is the final model after all resolution steps (actual_tier source)
	if [[ "$resolved_model" != "CONTEST" ]]; then
		record_dispatch_model_tiers "$task_id" "$tmodel" "$resolved_model"
	fi

	# Contest mode intercept (t1011): if model resolves to CONTEST, delegate to
	# contest-helper.sh which dispatches the same task to top-3 models in parallel.
	# The original task stays in 'running' state while contest entries execute.
	if [[ "$resolved_model" == "CONTEST" ]]; then
		log_info "Contest mode activated for $task_id — delegating to contest-helper.sh"
		local contest_helper="${SCRIPT_DIR}/contest-helper.sh"
		if [[ -x "$contest_helper" ]]; then
			local contest_id
			contest_id=$("$contest_helper" create "$task_id" ${batch_id:+--batch "$batch_id"} 2>/dev/null)
			if [[ -n "$contest_id" ]]; then
				"$contest_helper" dispatch "$contest_id" 2>/dev/null || {
					log_error "Contest dispatch failed for $task_id"
					cmd_transition "$task_id" "failed" --error "Contest dispatch failed"
					return 1
				}
				# Keep original task in running state — pulse Phase 2.5 will check contest completion
				db "$SUPERVISOR_DB" "UPDATE tasks SET error = 'contest:${contest_id}' WHERE id = '$(sql_escape "$task_id")';"
				log_success "Contest $contest_id dispatched for $task_id"
				echo "contest:${contest_id}"
				return 0
			else
				log_error "Failed to create contest for $task_id — falling back to default model"
				resolved_model=$(resolve_model "coding" "$ai_cli")
			fi
		else
			log_warn "contest-helper.sh not found — falling back to default model"
			resolved_model=$(resolve_model "coding" "$ai_cli")
		fi
	fi

	# Secondary availability check: verify the resolved model's provider (t233)
	# The initial health check uses the "health" tier (typically anthropic).
	# If the resolved model uses a different provider (e.g., google/gemini for pro tier),
	# we need to verify that provider too. Skip if same provider or if using OpenCode
	# (which manages routing internally).
	if [[ "$ai_cli" != "opencode" && -n "$resolved_model" && "$resolved_model" == *"/"* ]]; then
		local resolved_provider="${resolved_model%%/*}"
		local health_provider="${health_model%%/*}"
		if [[ "$resolved_provider" != "$health_provider" ]]; then
			local availability_helper="${SCRIPT_DIR}/model-availability-helper.sh"
			if [[ -x "$availability_helper" ]]; then
				local resolved_avail_exit=0
				"$availability_helper" check "$resolved_provider" --quiet || resolved_avail_exit=$?
				if [[ "$resolved_avail_exit" -ne 0 ]]; then
					case "$resolved_avail_exit" in
					2)
						log_warn "Resolved model provider '$resolved_provider' is rate-limited (exit $resolved_avail_exit) for $task_id — deferring dispatch"
						;;
					3)
						log_error "Resolved model provider '$resolved_provider' has invalid key/credits (exit $resolved_avail_exit) for $task_id — blocking dispatch"
						;;
					*)
						log_warn "Resolved model provider '$resolved_provider' unavailable (exit $resolved_avail_exit) for $task_id — deferring dispatch"
						;;
					esac
					return 3
				fi
			fi
		fi
	fi

	local dispatch_type="full"
	if [[ "$verify_mode" == "true" ]]; then
		dispatch_type="verify"
	fi
	log_info "Dispatching $task_id via $ai_cli ($dispatch_mode mode, $dispatch_type dispatch)"
	log_info "Worktree: $worktree_path"
	log_info "Model: $resolved_model"
	log_info "Log: $log_file"

	# Ensure PID directory exists before dispatch
	mkdir -p "$SUPERVISOR_DIR/pids"

	# Generate worker-specific MCP config with heavy indexers disabled (t221, t1162)
	# Must be generated BEFORE build_*_dispatch_cmd so Claude CLI gets --mcp-config flag
	# Saves ~4 CPU cores per worker by preventing osgrep from indexing
	local worker_mcp_config=""
	worker_mcp_config=$(generate_worker_mcp_config "$task_id" "$ai_cli" "$worktree_path") || true

	# Build and execute dispatch command
	# t1008: Use verify dispatch for previously-worked tasks (cheaper, focused)
	# Use NUL-delimited read to preserve multi-line prompts as single arguments
	# t1162: For Claude CLI, pass MCP config path to build_*_dispatch_cmd
	local claude_mcp_config=""
	if [[ "$ai_cli" == "claude" && -n "$worker_mcp_config" ]]; then
		claude_mcp_config="$worker_mcp_config"
	fi

	local -a cmd_parts=()
	if [[ "$verify_mode" == "true" ]]; then
		while IFS= read -r -d '' part; do
			cmd_parts+=("$part")
		done < <(build_verify_dispatch_cmd "$task_id" "$worktree_path" "$log_file" "$ai_cli" "$memory_context" "$resolved_model" "$tdesc" "$verify_reason" "$claude_mcp_config")
	else
		while IFS= read -r -d '' part; do
			cmd_parts+=("$part")
		done < <(build_dispatch_cmd "$task_id" "$worktree_path" "$log_file" "$ai_cli" "$memory_context" "$resolved_model" "$tdesc" "$claude_mcp_config")
	fi

	# Set FULL_LOOP_HEADLESS for all supervisor-dispatched workers (t174)
	# This ensures headless mode even if the AI doesn't parse --headless from the prompt
	local headless_env="FULL_LOOP_HEADLESS=true"

	# Write dispatch script to a temp file to avoid bash -c quoting issues
	# with multi-line prompts (newlines in printf '%q' break bash -c strings)
	# t1190: Use timestamped filenames to prevent overwrite race condition when
	# multiple dispatches run for the same task within a short window. Previously,
	# a second dispatch would overwrite the dispatch/wrapper scripts before the
	# first wrapper process had a chance to read them, causing the first wrapper
	# to execute the second dispatch's script (which writes to a different log file),
	# leaving the first log file with only the metadata header (no WORKER_STARTED).
	local dispatch_ts
	dispatch_ts=$(date +%Y%m%d%H%M%S)
	local dispatch_script="${SUPERVISOR_DIR}/pids/${task_id}-dispatch-${dispatch_ts}.sh"
	{
		echo '#!/usr/bin/env bash'
		echo "# Startup sentinel (t183): if this line appears in the log, the script started"
		echo "echo 'WORKER_STARTED task_id=${task_id} pid=\$\$ timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "cd '${worktree_path}' || { echo 'WORKER_FAILED: cd to worktree failed: ${worktree_path}'; exit 1; }"
		echo "export ${headless_env}"
		# t1162: For OpenCode, set XDG_CONFIG_HOME; for Claude, MCP config is in CLI flags
		if [[ "$ai_cli" != "claude" && -n "$worker_mcp_config" ]]; then
			echo "export XDG_CONFIG_HOME='${worker_mcp_config}'"
		fi
		# Write each cmd_part as a properly quoted array element
		printf 'exec '
		printf '%q ' "${cmd_parts[@]}"
		printf '\n'
	} >"$dispatch_script"
	chmod +x "$dispatch_script"

	# Wrapper script (t183): captures errors from the dispatch script itself.
	# Previous approach used nohup bash -c with &>/dev/null which swallowed
	# errors when the dispatch script failed to start (e.g., opencode not found).
	# Now errors are appended to the log file for diagnosis.
	# t253: Add cleanup handlers to prevent orphaned children when wrapper exits
	# t1190: Use timestamped filename (matches dispatch_ts) to prevent overwrite race.
	local wrapper_script="${SUPERVISOR_DIR}/pids/${task_id}-wrapper-${dispatch_ts}.sh"
	{
		echo '#!/usr/bin/env bash'
		# t1190: Wrapper-level sentinel — written before running the dispatch script.
		# If WRAPPER_STARTED appears in the log but WORKER_STARTED does not, the
		# wrapper ran but the dispatch script failed to start (exec failure, bad shebang,
		# permission error). This distinguishes "wrapper never ran" from "dispatch failed".
		echo "echo 'WRAPPER_STARTED task_id=${task_id} wrapper_pid=\$\$ dispatch_script=${dispatch_script} timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ) >> '${log_file}' 2>/dev/null || true"
		echo '# t253: Recursive cleanup to kill all descendant processes'
		echo '_kill_descendants_recursive() {'
		echo '  local parent_pid="$1"'
		echo '  local children'
		echo '  children=$(pgrep -P "$parent_pid" 2>/dev/null || true)'
		echo '  if [[ -n "$children" ]]; then'
		echo '    for child in $children; do'
		echo '      _kill_descendants_recursive "$child"'
		echo '    done'
		echo '  fi'
		echo '  kill -TERM "$parent_pid" 2>/dev/null || true'
		echo '}'
		echo ''
		echo 'cleanup_children() {'
		echo '  local wrapper_pid=$$'
		echo '  local children'
		echo '  children=$(pgrep -P "$wrapper_pid" 2>/dev/null || true)'
		echo '  if [[ -n "$children" ]]; then'
		echo '    # Recursively kill all descendants'
		echo '    for child in $children; do'
		echo '      _kill_descendants_recursive "$child"'
		echo '    done'
		echo '    sleep 0.5'
		echo '    # Force kill any survivors'
		echo '    for child in $children; do'
		echo '      pkill -9 -P "$child" 2>/dev/null || true'
		echo '      kill -9 "$child" 2>/dev/null || true'
		echo '    done'
		echo '  fi'
		echo '}'
		echo '# Register cleanup on EXIT, INT, TERM (KILL cannot be trapped)'
		echo 'trap cleanup_children EXIT INT TERM'
		echo ''
		# t1196: Heartbeat — write a timestamped line to the log every N seconds.
		# This keeps the log file mtime fresh during long-running operations (e.g.,
		# large refactors, integration tests) so the supervisor hang detector does
		# not false-positive kill a legitimately busy worker.
		# Interval: SUPERVISOR_HEARTBEAT_INTERVAL (default 300s = 5 min).
		# The heartbeat process is a child of the wrapper and is killed on cleanup.
		local heartbeat_interval="${SUPERVISOR_HEARTBEAT_INTERVAL:-300}"
		echo "# t1196: Heartbeat background process"
		echo "_heartbeat_log='${log_file}'"
		echo "_heartbeat_interval='${heartbeat_interval}'"
		echo '( while true; do'
		echo '    sleep "$_heartbeat_interval" || break'
		echo '    echo "HEARTBEAT: $(date -u +%Y-%m-%dT%H:%M:%SZ) worker still running" >> "$_heartbeat_log" 2>/dev/null || true'
		echo '  done ) &'
		echo '_heartbeat_pid=$!'
		echo ''
		echo "'${dispatch_script}' >> '${log_file}' 2>&1"
		echo "rc=\$?"
		echo "kill \$_heartbeat_pid 2>/dev/null || true"
		echo "echo \"EXIT:\${rc}\" >> '${log_file}'"
		echo "if [ \$rc -ne 0 ]; then"
		echo "  echo \"WORKER_DISPATCH_ERROR: dispatch script exited with code \${rc}\" >> '${log_file}'"
		echo "fi"
	} >"$wrapper_script"
	chmod +x "$wrapper_script"

	if [[ "$dispatch_mode" == "tabby" ]]; then
		# Tabby: attempt to open in a new tab via OSC 1337 escape sequence
		log_info "Opening Tabby tab for $task_id..."
		printf '\e]1337;NewTab=%s\a' "'${wrapper_script}'" 2>/dev/null || true
		# Also start background process as fallback (Tabby may not support OSC 1337)
		_launch_wrapper_script "${wrapper_script}" "${log_file}"
	else
		# Headless: background process
		_launch_wrapper_script "${wrapper_script}" "${log_file}"
	fi

	local worker_pid=$!
	disown "$worker_pid" 2>/dev/null || true

	# Store PID for monitoring
	echo "$worker_pid" >"$SUPERVISOR_DIR/pids/${task_id}.pid"

	# Transition to running
	cmd_transition "$task_id" "running" --session "pid:$worker_pid"

	# Add dispatched:model label to GitHub issue (t1010)
	add_model_label "$task_id" "dispatched" "$resolved_model" "${trepo:-.}" 2>>"$SUPERVISOR_LOG" || true

	log_success "Dispatched $task_id (PID: $worker_pid)"
	echo "$worker_pid"
	return 0
}

#######################################
# Launch a wrapper script in the background, surviving parent (cron) exit.
# t253: Uses setsid if available (Linux) for process group isolation.
# t1190: Redirects wrapper stderr to log file for startup error diagnosis.
# Args: wrapper_script log_file
#######################################
_launch_wrapper_script() {
	local wrapper_script="$1"
	local log_file="$2"

	if command -v setsid &>/dev/null; then
		nohup setsid bash "${wrapper_script}" >>"${log_file}" 2>&1 &
	else
		nohup bash "${wrapper_script}" >>"${log_file}" 2>&1 &
	fi
	return 0
}

#######################################
# Check the status of a running worker
# Reads log file and PID to determine state
#######################################
cmd_worker_status() {
	local task_id="${1:-}"

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh worker-status <task_id>"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, session_id, log_file, worktree
        FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local tstatus tsession tlog tworktree
	IFS='|' read -r tstatus tsession tlog tworktree <<<"$task_row"

	echo -e "${BOLD}Worker: $task_id${NC}"
	echo "  DB Status:  $tstatus"
	echo "  Session:    ${tsession:-none}"
	echo "  Log:        ${tlog:-none}"
	echo "  Worktree:   ${tworktree:-none}"

	# Check PID if running
	if [[ "$tstatus" == "running" || "$tstatus" == "dispatched" ]]; then
		local pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
		if [[ -f "$pid_file" ]]; then
			local pid
			pid=$(cat "$pid_file")
			if kill -0 "$pid" 2>/dev/null; then
				echo -e "  Process:    ${GREEN}alive${NC} (PID: $pid)"
			else
				echo -e "  Process:    ${RED}dead${NC} (PID: $pid was)"
			fi
		else
			echo "  Process:    unknown (no PID file)"
		fi
	fi

	# Check log file for completion signals
	if [[ -n "$tlog" && -f "$tlog" ]]; then
		local log_size
		log_size=$(wc -c <"$tlog" | tr -d ' ')
		echo "  Log size:   ${log_size} bytes"

		# Check for completion signals
		if grep -q 'FULL_LOOP_COMPLETE' "$tlog" 2>/dev/null; then
			echo -e "  Signal:     ${GREEN}FULL_LOOP_COMPLETE${NC}"
		elif grep -q 'TASK_COMPLETE' "$tlog" 2>/dev/null; then
			echo -e "  Signal:     ${YELLOW}TASK_COMPLETE${NC}"
		fi

		# Show PR URL from DB (t151: don't grep log - picks up wrong URLs)
		local pr_url
		pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || true)
		if [[ -n "$pr_url" && "$pr_url" != "no_pr" && "$pr_url" != "task_only" ]]; then
			echo "  PR:         $pr_url"
		fi

		# Check for EXIT code
		local exit_line
		exit_line=$(grep '^EXIT:' "$tlog" 2>/dev/null | tail -1 || true)
		if [[ -n "$exit_line" ]]; then
			echo "  Exit:       ${exit_line#EXIT:}"
		fi

		# Show last 3 lines of log
		echo ""
		echo "  Last output:"
		tail -3 "$tlog" 2>/dev/null | while IFS= read -r line; do
			echo "    $line"
		done
	fi

	return 0
}

#######################################
# Re-prompt a worker session to continue/retry
# Uses opencode run -c (continue last session) or -s <id> (specific session)
# Returns 0 on successful dispatch, 1 on failure
#######################################
cmd_reprompt() {
	local task_id=""
	local prompt_override=""

	# First positional arg is task_id
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--prompt)
			[[ $# -lt 2 ]] && {
				log_error "--prompt requires a value"
				return 1
			}
			prompt_override="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh reprompt <task_id> [--prompt \"custom prompt\"]"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, repo, description, status, session_id, worktree, log_file, retries, max_retries, error, model
        FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local _tid trepo tdesc tstatus tsession tworktree tlog tretries tmax_retries terror tmodel
	IFS='|' read -r _tid trepo tdesc tstatus tsession tworktree tlog tretries tmax_retries terror tmodel <<<"$task_row"

	# Validate state - must be in retrying state
	if [[ "$tstatus" != "retrying" ]]; then
		log_error "Task $task_id is in '$tstatus' state, must be 'retrying' to re-prompt"
		return 1
	fi

	# Check max retries
	if [[ "$tretries" -ge "$tmax_retries" ]]; then
		log_error "Task $task_id has exceeded max retries ($tretries/$tmax_retries)"
		cmd_transition "$task_id" "failed" --error "Max retries exceeded during re-prompt"
		return 1
	fi

	local ai_cli
	ai_cli=$(resolve_ai_cli) || return 1

	# Pre-reprompt availability check (t233 — distinct exit codes from check_model_health)
	# Avoids wasting retry attempts on dead/rate-limited backends.
	# (t153-pre-diag-1: retries 1+2 failed instantly with backend endpoint errors)
	local health_model health_exit=0
	health_model=$(resolve_model "health" "$ai_cli")
	check_model_health "$ai_cli" "$health_model" || health_exit=$?
	if [[ "$health_exit" -ne 0 ]]; then
		case "$health_exit" in
		2)
			log_warn "Provider rate-limited for $task_id re-prompt ($health_model via $ai_cli) — deferring to next pulse"
			;;
		3)
			log_error "API key invalid/credits exhausted for $task_id re-prompt ($health_model via $ai_cli)"
			;;
		*)
			log_error "Provider unavailable for $task_id re-prompt ($health_model via $ai_cli) — deferring retry"
			;;
		esac
		# Task is already in 'retrying' state with counter incremented.
		# Do NOT transition again (would double-increment). Return 75 (EX_TEMPFAIL)
		# so the pulse cycle can distinguish transient backend failures from real
		# reprompt failures and leave the task in retrying state for the next pulse.
		return 75
	fi

	# Set up log file for this retry attempt
	local log_dir="$SUPERVISOR_DIR/logs"
	mkdir -p "$log_dir"
	local new_log_file
	new_log_file="$log_dir/${task_id}-retry${tretries}-$(date +%Y%m%d%H%M%S).log"

	# Clean-slate retry: if the previous error suggests the worktree is stale
	# or the worker exited without producing a PR, recreate from fresh main.
	# (t178: moved before prompt construction so $needs_fresh_worktree is set
	# when the prompt message references it)
	local needs_fresh_worktree=false
	case "${terror:-}" in
	*clean_exit_no_signal* | *stale* | *diverged* | *worktree*) needs_fresh_worktree=true ;;
	esac

	if [[ "$needs_fresh_worktree" == "true" && -n "$tworktree" ]]; then
		log_info "Clean-slate retry for $task_id — recreating worktree from main"
		local new_worktree
		new_worktree=$(create_task_worktree "$task_id" "$trepo" "true") || {
			log_error "Failed to recreate worktree for $task_id"
			cmd_transition "$task_id" "failed" --error "Clean-slate worktree recreation failed"
			return 1
		}
		tworktree="$new_worktree"
		# Update worktree path in DB
		db "$SUPERVISOR_DB" "
            UPDATE tasks SET worktree = '$(sql_escape "$tworktree")'
            WHERE id = '$(sql_escape "$task_id")';
        " 2>/dev/null || true
	fi

	# (t178) Worktree missing but not a clean-slate case — recreate it.
	# The worktree directory may have been removed between retries (manual
	# cleanup, disk cleanup, wt prune, etc.). Without this, the worker
	# falls back to the main repo which is wrong.
	if [[ -n "$tworktree" && ! -d "$tworktree" && "$needs_fresh_worktree" != "true" ]]; then
		log_warn "Worktree missing for $task_id ($tworktree) — recreating"
		local new_worktree
		new_worktree=$(create_task_worktree "$task_id" "$trepo") || {
			log_error "Failed to recreate missing worktree for $task_id"
			cmd_transition "$task_id" "failed" --error "Missing worktree recreation failed"
			return 1
		}
		tworktree="$new_worktree"
		db "$SUPERVISOR_DB" "
            UPDATE tasks SET worktree = '$(sql_escape "$tworktree")'
            WHERE id = '$(sql_escape "$task_id")';
        " 2>/dev/null || true
		needs_fresh_worktree=true
	fi

	# Determine working directory
	local work_dir="$trepo"
	if [[ -n "$tworktree" && -d "$tworktree" ]]; then
		work_dir="$tworktree"
	fi

	# Build re-prompt message with context about the failure
	local reprompt_msg
	if [[ -n "$prompt_override" ]]; then
		reprompt_msg="$prompt_override"
	elif [[ "$needs_fresh_worktree" == "true" ]]; then
		# (t229) Check if there's an existing PR on this branch — tell the worker to reuse it
		local existing_pr_url=""
		existing_pr_url=$(gh pr list --head "feature/${task_id}" --state open --json url --jq '.[0].url' 2>/dev/null || echo "")
		local pr_reuse_note=""
		if [[ -n "$existing_pr_url" && "$existing_pr_url" != "null" ]]; then
			pr_reuse_note="
IMPORTANT: An existing PR is open on this branch: $existing_pr_url
Push your commits to this branch and the PR will update automatically. Do NOT create a new PR — use the existing one. When done, run: gh pr ready"
		fi
		reprompt_msg="/full-loop $task_id -- ${tdesc:-$task_id}

NOTE: This is a clean-slate retry. The branch has been reset to main. Start fresh — do not look for previous work on this branch.${pr_reuse_note}"
	else
		reprompt_msg="The previous attempt for task $task_id encountered an issue: ${terror:-unknown error}.

Please continue the /full-loop for $task_id. Pick up where the previous attempt left off.
If the task was partially completed, verify what's done and continue from there.
If it failed entirely, start fresh with /full-loop $task_id.

Task description: ${tdesc:-$task_id}"
	fi

	# Pre-create log file with reprompt metadata (t183)
	{
		echo "=== REPROMPT METADATA (t183) ==="
		echo "task_id=$task_id"
		echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "retry=$tretries/$tmax_retries"
		echo "work_dir=$work_dir"
		echo "previous_error=${terror:-none}"
		echo "fresh_worktree=$needs_fresh_worktree"
		echo "=== END REPROMPT METADATA ==="
		echo ""
	} >"$new_log_file" 2>/dev/null || true

	# Transition to dispatched
	cmd_transition "$task_id" "dispatched" --log-file "$new_log_file"

	log_info "Re-prompting $task_id (retry $tretries/$tmax_retries)"
	log_info "Working dir: $work_dir"
	log_info "Log: $new_log_file"

	# Resolve model for retry dispatch (t1186: was missing, causing all retries to
	# use opencode's default model — opus — regardless of the task's requested tier)
	local resolved_model=""
	if [[ -n "$tmodel" ]]; then
		resolved_model=$(resolve_model "$tmodel" "$ai_cli" 2>/dev/null) || true
	fi
	# Record tier delta for retry dispatch (t1186)
	if [[ -n "$resolved_model" && "$resolved_model" != "CONTEST" ]]; then
		record_dispatch_model_tiers "$task_id" "$tmodel" "$resolved_model"
	fi

	# Dispatch the re-prompt (t1160.1: uses build_cli_cmd abstraction)
	# t262: Include truncated description in retry session title
	local retry_title="${task_id}-retry${tretries}"
	if [[ -n "$tdesc" ]]; then
		local short_desc="${tdesc%% -- *}"
		short_desc="${short_desc%% #*}"
		short_desc="${short_desc%% ~*}"
		if [[ ${#short_desc} -gt 30 ]]; then
			short_desc="${short_desc:0:27}..."
		fi
		retry_title="${task_id}-r${tretries}: ${short_desc}"
	fi
	# Ensure PID directory exists
	mkdir -p "$SUPERVISOR_DIR/pids"

	# Generate worker-specific MCP config (t221, t1162)
	# Must be generated BEFORE build_cli_cmd so Claude CLI gets --mcp-config flag
	local worker_mcp_config=""
	worker_mcp_config=$(generate_worker_mcp_config "$task_id" "$ai_cli" "$work_dir") || true

	# t1186: Pass task model to opencode — without this, retries default to
	# opencode's configured model (opus), wasting budget on tasks that only
	# need sonnet. This was the root cause of the sonnet→opus tier escalation.
	# t1162: Build CLI command with MCP config for Claude worker isolation
	local -a build_cmd_args=(
		--cli "$ai_cli"
		--action run
		--output nul
		--model "$resolved_model"
		--title "$retry_title"
		--prompt "$reprompt_msg"
	)
	if [[ "$ai_cli" == "claude" && -n "$worker_mcp_config" ]]; then
		build_cmd_args+=(--mcp-config "$worker_mcp_config")
	fi
	local -a cmd_parts=()
	while IFS= read -r -d '' part; do
		cmd_parts+=("$part")
	done < <(build_cli_cmd "${build_cmd_args[@]}")

	# Write dispatch script with startup sentinel (t183)
	# t1190: Use timestamped filename to prevent overwrite race condition.
	local reprompt_dispatch_ts
	reprompt_dispatch_ts=$(date +%Y%m%d%H%M%S)
	local dispatch_script="${SUPERVISOR_DIR}/pids/${task_id}-reprompt-${reprompt_dispatch_ts}.sh"
	{
		echo '#!/usr/bin/env bash'
		echo "echo 'WORKER_STARTED task_id=${task_id} retry=${tretries} pid=\$\$ timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "cd '${work_dir}' || { echo 'WORKER_FAILED: cd to work_dir failed: ${work_dir}'; exit 1; }"
		# t1162: For OpenCode, set XDG_CONFIG_HOME; for Claude, MCP config is in CLI flags
		if [[ "$ai_cli" != "claude" && -n "$worker_mcp_config" ]]; then
			echo "export XDG_CONFIG_HOME='${worker_mcp_config}'"
		fi
		printf 'exec '
		printf '%q ' "${cmd_parts[@]}"
		printf '\n'
	} >"$dispatch_script"
	chmod +x "$dispatch_script"

	# Wrapper script (t183): captures dispatch errors in log file
	# t253: Add cleanup handlers to prevent orphaned children when wrapper exits
	# t1190: Use timestamped filename to prevent overwrite race condition.
	local wrapper_script="${SUPERVISOR_DIR}/pids/${task_id}-reprompt-wrapper-${reprompt_dispatch_ts}.sh"
	{
		echo '#!/usr/bin/env bash'
		# t1190: Wrapper-level sentinel written before running dispatch script.
		echo "echo 'WRAPPER_STARTED task_id=${task_id} retry=${tretries} wrapper_pid=\$\$ dispatch_script=${dispatch_script} timestamp='\$(date -u +%Y-%m-%dT%H:%M:%SZ) >> '${new_log_file}' 2>/dev/null || true"
		echo '# t253: Recursive cleanup to kill all descendant processes'
		echo '_kill_descendants_recursive() {'
		echo '  local parent_pid="$1"'
		echo '  local children'
		echo '  children=$(pgrep -P "$parent_pid" 2>/dev/null || true)'
		echo '  if [[ -n "$children" ]]; then'
		echo '    for child in $children; do'
		echo '      _kill_descendants_recursive "$child"'
		echo '    done'
		echo '  fi'
		echo '  kill -TERM "$parent_pid" 2>/dev/null || true'
		echo '}'
		echo ''
		echo 'cleanup_children() {'
		echo '  local wrapper_pid=$$'
		echo '  local children'
		echo '  children=$(pgrep -P "$wrapper_pid" 2>/dev/null || true)'
		echo '  if [[ -n "$children" ]]; then'
		echo '    # Recursively kill all descendants'
		echo '    for child in $children; do'
		echo '      _kill_descendants_recursive "$child"'
		echo '    done'
		echo '    sleep 0.5'
		echo '    # Force kill any survivors'
		echo '    for child in $children; do'
		echo '      pkill -9 -P "$child" 2>/dev/null || true'
		echo '      kill -9 "$child" 2>/dev/null || true'
		echo '    done'
		echo '  fi'
		echo '}'
		echo '# Register cleanup on EXIT, INT, TERM (KILL cannot be trapped)'
		echo 'trap cleanup_children EXIT INT TERM'
		echo ''
		echo "'${dispatch_script}' >> '${new_log_file}' 2>&1"
		echo "rc=\$?"
		echo "echo \"EXIT:\${rc}\" >> '${new_log_file}'"
		echo "if [ \$rc -ne 0 ]; then"
		echo "  echo \"WORKER_DISPATCH_ERROR: reprompt script exited with code \${rc}\" >> '${new_log_file}'"
		echo "fi"
	} >"$wrapper_script"
	chmod +x "$wrapper_script"

	# t253: Use setsid if available (Linux) for process group isolation
	# Use nohup + disown to survive parent (cron) exit
	# t1190: Redirect wrapper stderr to log file (not /dev/null) for diagnosis.
	if command -v setsid &>/dev/null; then
		nohup setsid bash "${wrapper_script}" >>"${new_log_file}" 2>&1 &
	else
		nohup bash "${wrapper_script}" >>"${new_log_file}" 2>&1 &
	fi
	local worker_pid=$!
	disown "$worker_pid" 2>/dev/null || true

	echo "$worker_pid" >"$SUPERVISOR_DIR/pids/${task_id}.pid"

	# Transition to running
	cmd_transition "$task_id" "running" --session "pid:$worker_pid"

	log_success "Re-prompted $task_id (PID: $worker_pid, retry $tretries/$tmax_retries)"
	echo "$worker_pid"
	return 0
}
