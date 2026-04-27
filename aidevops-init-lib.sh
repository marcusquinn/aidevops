#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Init and Scaffold Library
# =============================================================================
# Project initialisation and scaffolding functions extracted from aidevops.sh
# to keep the orchestrator under the 2000-line file-size threshold.
#
# Covers:
#   1. Scaffold helpers: _scaffold_contributing, _scaffold_security, _scaffold_coc,
#      scaffold_repo_courtesy_files, _generate_security_section, scaffold_agents_md,
#      _update_agents_md_security
#   2. Init helpers: _init_parse_features, _seed_mission_control_template,
#      _init_scaffold_commands_symlinks, _init_scaffold_scope_gated_files
#   3. cmd_init: main init command dispatcher
#
# Usage: source "${SCRIPT_DIR}/aidevops-init-lib.sh"
#
# Dependencies:
#   - INSTALL_DIR, AGENTS_DIR, CONFIG_DIR (set by aidevops.sh)
#   - print_* helpers and utility functions (defined in aidevops.sh before sourcing)
#   - register_repo(), get_repo_slug() from aidevops-repos-lib.sh (sourced first)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AIDEVOPS_INIT_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_INIT_LIB_LOADED=1

# Scaffold standard repo courtesy files if they don't exist
# Scaffold helpers (extracted for complexity reduction)
_scaffold_contributing() {
	local project_root="$1" repo_name="$2"
	[[ -f "$project_root/CONTRIBUTING.md" ]] && return 1
	local c="# Contributing to $repo_name"
	c="$c"$'\n\n'"Thanks for your interest in contributing!"
	c="$c"$'\n\n'"## Quick Start"$'\n\n'"1. Fork the repository"
	c="$c"$'\n'"2. Create a branch: \`git checkout -b feature/your-feature\`"
	c="$c"$'\n'"3. Make your changes"
	c="$c"$'\n'"4. Commit with conventional commits: \`git commit -m \"feat: add new feature\"\`"
	c="$c"$'\n'"5. Push and open a PR"
	c="$c"$'\n\n'"## Commit Messages"$'\n\n'"We use [Conventional Commits](https://www.conventionalcommits.org/):"
	c="$c"$'\n\n'"- \`feat:\` - New feature"$'\n'"- \`fix:\` - Bug fix"$'\n'"- \`docs:\` - Documentation only"
	c="$c"$'\n'"- \`refactor:\` - Code change that neither fixes a bug nor adds a feature"$'\n'"- \`chore:\` - Maintenance tasks"
	printf '%s\n' "$c" >"$project_root/CONTRIBUTING.md"
	return 0
}

_scaffold_security() {
	local project_root="$1"
	[[ -f "$project_root/SECURITY.md" ]] && return 1
	local se="" ge
	ge=$(git -C "$project_root" config user.email 2>/dev/null || echo "")
	[[ -n "$ge" ]] && se="$ge"
	cat >"$project_root/SECURITY.md" <<SECEOF
# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately.
SECEOF
	[[ -n "$se" ]] && cat >>"$project_root/SECURITY.md" <<SECEOF

**Email:** $se

Please do not open public issues for security vulnerabilities.
SECEOF
	return 0
}

_scaffold_coc() {
	local project_root="$1"
	[[ -f "$project_root/CODE_OF_CONDUCT.md" ]] && return 1
	cat >"$project_root/CODE_OF_CONDUCT.md" <<'COCEOF'
# Contributor Covenant Code of Conduct

## Our Pledge

We as members, contributors, and leaders pledge to make participation in our
community a harassment-free experience for everyone.

## Our Standards

Examples of behavior that contributes to a positive environment:

- Using welcoming and inclusive language
- Being respectful of differing viewpoints and experiences
- Gracefully accepting constructive criticism
- Focusing on what is best for the community

## Attribution

This Code of Conduct is adapted from the [Contributor Covenant](https://www.contributor-covenant.org),
version 2.1.
COCEOF
	return 0
}

# Scaffold standard repo courtesy files if they don't exist
# Creates: README.md, LICENCE, CHANGELOG.md, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md
scaffold_repo_courtesy_files() {
	local project_root="$1"
	local scope="${2:-standard}" # Default to standard for backward compatibility
	local created=0
	local repo_name
	repo_name=$(basename "$project_root")
	local author_name
	author_name=$(git -C "$project_root" config user.name 2>/dev/null || echo "")
	local current_year
	current_year=$(date +%Y)
	print_info "Checking repo courtesy files (scope: $scope)..."

	# README.md: requires "standard" scope
	if _scope_includes "$scope" "standard"; then
		if [[ ! -f "$project_root/README.md" ]]; then
			local rc="# $repo_name"
			if [[ -f "$project_root/.aidevops.json" ]]; then
				local desc
				desc=$(jq -r '.description // empty' "$project_root/.aidevops.json" 2>/dev/null || echo "")
				[[ -n "$desc" ]] && rc="$rc"$'\n\n'"$desc"
			fi
			{ [[ -f "$project_root/LICENCE" ]] || [[ -f "$project_root/LICENSE" ]]; } && rc="$rc"$'\n\n'"## Licence"$'\n\n'"See [LICENCE](LICENCE) for details."
			printf '%s\n' "$rc" >"$project_root/README.md"
			((++created))
		fi
	fi

	# LICENCE: requires "public" scope
	if _scope_includes "$scope" "public"; then
		if [[ ! -f "$project_root/LICENCE" ]] && [[ ! -f "$project_root/LICENSE" ]]; then
			local lh="${author_name:-$(whoami)}"
			cat >"$project_root/LICENCE" <<LICEOF
MIT License

Copyright (c) $current_year $lh

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICEOF
			((++created))
		fi
	fi

	# CHANGELOG.md: requires "public" scope
	if _scope_includes "$scope" "public"; then
		if [[ ! -f "$project_root/CHANGELOG.md" ]]; then
			cat >"$project_root/CHANGELOG.md" <<'CHEOF'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
CHEOF
			((++created))
		fi
	fi

	# CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md: require "public" scope
	if _scope_includes "$scope" "public"; then
		_scaffold_contributing "$project_root" "$repo_name" && ((++created))
		_scaffold_security "$project_root" && ((++created))
		_scaffold_coc "$project_root" && ((++created))
	fi

	[[ $created -gt 0 ]] && print_success "Created $created repo courtesy file(s) (README, LICENCE, CHANGELOG, etc.)" || print_info "Repo courtesy files already exist"
	return 0
}

# Generate the Security section content based on project type (t1412.11)
# Returns the content via stdout so callers can use it for create or update.
_generate_security_section() {
	local project_root="$1"

	# Detect project type for security recommendations
	local is_js_ts=false
	if [[ -f "$project_root/package.json" ]]; then
		is_js_ts=true
	fi

	cat <<'SECHEADER'
## Security

SECHEADER

	if [[ "$is_js_ts" == "true" ]]; then
		cat <<'SECEOF'
### Prompt Injection Defense

Any feature that processes untrusted content (tool outputs, user input, webhook
payloads) and passes it to an LLM must defend against prompt injection. This is
a JS/TS project — use `@stackone/defender` to sanitize untrusted tool results
before they enter the LLM context:

```bash
npm install @stackone/defender
```

```typescript
import { createPromptDefense } from '@stackone/defender';

const defense = createPromptDefense({ enableTier2: true, blockHighRisk: true });

// Sanitize untrusted tool output before adding to LLM context
const result = await defense.defendToolResult(toolResponse, 'tool_name');
if (!result.allowed) {
  throw new Error('Blocked untrusted content');
}
const safeContent = result.sanitized;
```

For features that don't use LLMs but process untrusted text (webhooks, form
submissions, API endpoints), validate and sanitize inputs at the boundary.

### General Security Rules

- Never log or expose API keys, tokens, or credentials in output
- Store secrets via `aidevops secret set <NAME>` (gopass-encrypted) or
  environment variables — never hardcode them in source
- Use `<PLACEHOLDER>` values in code examples; note the secure storage location
- Validate all external input (user input, webhook payloads, API responses)
- Pin third-party GitHub Actions to SHA hashes, not branch tags
- Run `aidevops security audit` periodically to check security posture
- See `~/.aidevops/agents/tools/security/prompt-injection-defender.md` for
  the framework's prompt injection defense patterns
SECEOF
	else
		cat <<'SECEOF'
### Prompt Injection Defense

Any feature that passes untrusted content to an LLM — user input, tool outputs,
retrieved documents, emails, tickets, or webhook payloads — must defend against
prompt injection. Sanitize and validate that content before including it in
prompts:

- Strip or escape control characters and instruction-like patterns
- Use structured prompt templates with clear system/user boundaries
- Never concatenate raw external content directly into system prompts
- Validate all externally sourced content (tool results, API responses, database
  records) before inclusion in prompts
- Consider allowlist-based input validation where possible

### General Security Rules

- Never log or expose API keys, tokens, or credentials in output
- Store secrets via `aidevops secret set <NAME>` (gopass-encrypted) or
  environment variables — never hardcode them in source
- Use `<PLACEHOLDER>` values in code examples; note the secure storage location
- Validate all external input (user input, webhook payloads, API responses)
- Pin third-party GitHub Actions to SHA hashes, not branch tags
- Run `aidevops security audit` periodically to check security posture
- See `~/.aidevops/agents/tools/security/prompt-injection-defender.md` for
  the framework's prompt injection defense patterns
SECEOF
	fi

	return 0
}

# Scaffold .agents/AGENTS.md with context-aware Security section (t1412.11)
# Idempotent: creates the file if missing, or updates the Security section
# in an existing file (preserving all other custom content).
scaffold_agents_md() {
	local project_root="$1"
	local agents_md="$project_root/.agents/AGENTS.md"

	mkdir -p "$(dirname "$agents_md")"

	if [[ -f "$agents_md" ]]; then
		# File exists — update the Security section idempotently
		_update_agents_md_security "$project_root"
		return $?
	fi

	# File missing — create from scratch with base template + security
	local security_content
	security_content=$(_generate_security_section "$project_root")

	cat >"$agents_md" <<'AGENTSEOF'
# Agent Instructions

This directory contains project-specific agent context. The [aidevops](https://aidevops.sh)
framework is loaded separately via the global config (`~/.aidevops/agents/`).

## Purpose

Files in `.agents/` provide project-specific instructions that AI assistants
read when working in this repository. Use this for:

- Domain-specific conventions not covered by the framework
- Project architecture decisions and patterns
- API design rules, data models, naming conventions
- Integration details (third-party services, deployment targets)

## Adding Agents

Create `.md` files in this directory for domain-specific context:

```text
.agents/
  AGENTS.md              # This file - overview and index
  api-patterns.md        # API design conventions
  deployment.md          # Deployment procedures
  data-model.md          # Database schema and relationships
```

Each file is read on demand by AI assistants when relevant to the task.

AGENTSEOF

	# Append the generated security section
	printf '%s\n' "$security_content" >>"$agents_md"

	return 0
}

# Update the Security section in an existing .agents/AGENTS.md (t1412.11)
# Replaces everything from "## Security" to the next "## " heading (or EOF)
# with the latest security guidance. Preserves all other content.
_update_agents_md_security() {
	local project_root="$1"
	local agents_md="$project_root/.agents/AGENTS.md"
	local tmp_file="${agents_md}.tmp.$$"

	local security_content
	security_content=$(_generate_security_section "$project_root")

	local in_security=false
	local has_security_section=false

	# Process line by line: skip old Security section, insert new one
	while IFS= read -r line || [[ -n "$line" ]]; do
		# Match "## Security" exactly, with optional trailing whitespace
		if [[ "$line" =~ ^'## Security'[[:space:]]*$ ]]; then
			# Found the Security heading — replace it
			in_security=true
			has_security_section=true
			printf '%s\n' "$security_content" >>"$tmp_file"
			continue
		fi

		if [[ "$in_security" == "true" ]]; then
			# Check if we've hit the next ## heading (end of Security section)
			if [[ "$line" == "## "* ]]; then
				in_security=false
				printf '%s\n' "$line" >>"$tmp_file"
			fi
			# Skip lines within the old Security section
			continue
		fi

		printf '%s\n' "$line" >>"$tmp_file"
	done <"$agents_md"

	if [[ "$has_security_section" == "false" ]]; then
		# No existing Security section — append it
		printf '\n%s\n' "$security_content" >>"$tmp_file"
	fi

	mv "$tmp_file" "$agents_md"

	return 0
}

# Init helpers (extracted for complexity reduction)
_init_parse_features() {
	local features="$1"
	case "$features" in
	all) echo "planning git_workflow code_quality time_tracking database beads security" ;;
	planning) echo "planning" ;; git-workflow) echo "git_workflow" ;; code-quality) echo "code_quality" ;;
	time-tracking) echo "time_tracking planning" ;; database) echo "database" ;;
	beads) echo "beads planning" ;; sops) echo "sops" ;; security) echo "security" ;;
	*)
		local result=""
		IFS=',' read -ra FL <<<"$features"
		for f in "${FL[@]}"; do
			case "$f" in
			planning) result="$result planning" ;; git-workflow) result="$result git_workflow" ;;
			code-quality) result="$result code_quality" ;; time-tracking) result="$result time_tracking planning" ;;
			database) result="$result database" ;; beads) result="$result beads planning" ;;
			sops) result="$result sops" ;; security) result="$result security" ;;
			esac
		done
		echo "$result"
		;;
	esac
	return 0
}

# Seed mission-control onboarding template when initializing a mission-control repo.
# Usage: _seed_mission_control_template <project_root> <personal|org>
_seed_mission_control_template() {
	local project_root="$1"
	local scope="$2"
	local seed_file="$project_root/todo/mission-control-seed.md"

	if [[ -z "$scope" ]]; then
		return 0
	fi

	if [[ -f "$seed_file" ]]; then
		return 0
	fi

	mkdir -p "$project_root/todo"

	if [[ "$scope" == "personal" ]]; then
		cat >"$seed_file" <<'EOF'
# Mission Control Seed (Personal)

Starter checklist for a personal mission-control repo initialized with aidevops.

## First-Day Setup

- [ ] Confirm `~/.config/aidevops/repos.json` has all active repos registered with correct `slug` and `path`
- [ ] Set `pulse: true` only for repos you want actively supervised
- [ ] Add `pulse_hours` windows to avoid dispatch during daytime manual development
- [ ] Verify profile and archive repos are `pulse: false` and `priority: "profile"` where applicable

## Operating Rhythm

- [ ] Define weekly review cadence for `aidevops pulse` health and backlog aging
- [ ] Add hygiene tasks for stale branches, stale worktrees, and stale queued issues
- [ ] Track cross-repo blockers in TODO with clear `blocked-by:` links
EOF
	else
		cat >"$seed_file" <<'EOF'
# Mission Control Seed (Organization)

Starter checklist for an organization mission-control repo initialized with aidevops.

## First-Day Setup

- [ ] Register all managed org repos in `~/.config/aidevops/repos.json` with `slug`, `path`, `priority`, and `maintainer`
- [ ] Set `pulse: true` only for repos approved for autonomous dispatch
- [ ] Configure `pulse_hours` and optional `pulse_expires` windows for sprint-based focus
- [ ] Keep sensitive/internal-only repos `pulse: false` until policy checks are complete

## Governance

- [ ] Define maintainer response SLA for `needs-maintainer-review` triage
- [ ] Document worker guardrails (release, merge, and security boundaries)
- [ ] Add a weekly audit task for repo registration drift and label hygiene
EOF
	fi

	print_success "Seeded mission-control template: todo/mission-control-seed.md (${scope})"
	return 0
}

# Scaffold .agents/commands/ and .windsurf/workflows/ symlinks so that clients
# which read repo-local command directories (Amp reads .agents/commands/ natively;
# Windsurf reads .windsurf/workflows/) see the aidevops main-agent slash commands.
#
# Behavior is idempotent:
#   - If .agents/commands/ already contains the expected aidevops-*.md symlinks
#     (this repo IS the aidevops source), do nothing.
#   - Otherwise link .agents/commands/ → ~/.aidevops/agents/commands/
#   - Always link .windsurf/workflows/ → ../.agents/commands/ (relative)
_init_scaffold_commands_symlinks() {
	local project_root="$1"
	local source_dir="$HOME/.aidevops/agents/commands"
	local commands_dir="$project_root/.agents/commands"
	local windsurf_dir="$project_root/.windsurf"
	local workflows_link="$windsurf_dir/workflows"

	# If .agents/commands/ already contains main-agent symlinks, this repo
	# manages them directly (e.g. the aidevops source repo itself) — leave
	# it alone so we never overwrite authoritative content.
	if [[ -e "$commands_dir/aidevops-build-plus.md" ]]; then
		print_info ".agents/commands/ already contains main-agent symlinks — preserving"
	elif [[ ! -d "$source_dir" ]]; then
		print_warning "Framework commands dir not found at $source_dir — run setup.sh first to deploy main-agent symlinks"
	elif [[ -L "$commands_dir" ]]; then
		# Existing symlink — point at the canonical source
		local current_target
		current_target=$(readlink "$commands_dir")
		if [[ "$current_target" != "$source_dir" ]]; then
			rm "$commands_dir"
			ln -s "$source_dir" "$commands_dir"
			print_success "Re-linked .agents/commands/ → $source_dir"
		else
			print_info ".agents/commands/ already linked correctly"
		fi
	elif [[ -d "$commands_dir" ]]; then
		print_warning ".agents/commands/ exists as a real directory — not overwriting"
	else
		ln -s "$source_dir" "$commands_dir"
		print_success "Linked .agents/commands/ → $source_dir (Amp reads this natively)"
	fi

	# .windsurf/workflows/ → ../.agents/commands/ (relative, so the link
	# resolves inside the repo regardless of checkout path).
	mkdir -p "$windsurf_dir"
	if [[ -L "$workflows_link" ]]; then
		print_info ".windsurf/workflows/ already linked"
	elif [[ -d "$workflows_link" ]]; then
		print_warning ".windsurf/workflows/ exists as a real directory — not overwriting"
	else
		(cd "$windsurf_dir" && ln -s "../.agents/commands" workflows)
		print_success "Linked .windsurf/workflows/ → ../.agents/commands (Windsurf slash commands)"
	fi
	return 0
}

# Scaffold optional files gated by init_scope (t2265).
# Extracted from cmd_init to reduce nesting depth and function length.
# Usage: _init_scaffold_scope_gated_files <project_root> <init_scope> <repo_name>
_init_scaffold_scope_gated_files() {
	local project_root="$1"
	local init_scope="$2"
	local repo_name="$3"

	# Collaborator pointer files — require standard scope
	if _scope_includes "$init_scope" "standard"; then
		local pointer_content="Read AGENTS.md for all project context and instructions."
		local pointer_files=(".cursorrules" ".windsurfrules" ".clinerules" ".github/copilot-instructions.md")
		local pointer_created=0
		local pf
		for pf in "${pointer_files[@]}"; do
			local pf_path="$project_root/$pf"
			if [[ ! -f "$pf_path" ]]; then
				mkdir -p "$(dirname "$pf_path")"
				echo "$pointer_content" >"$pf_path"
				((++pointer_created))
			fi
		done
		if [[ $pointer_created -gt 0 ]]; then
			print_success "Created $pointer_created collaborator pointer file(s) (.cursorrules, etc.)"
		else
			print_info "Collaborator pointer files already exist"
		fi
	else
		print_info "Collaborator pointer files skipped (init_scope: $init_scope)"
	fi

	# DESIGN.md — requires standard scope
	if _scope_includes "$init_scope" "standard"; then
		if [[ ! -f "$project_root/DESIGN.md" ]]; then
			local design_template="$AGENTS_DIR/templates/DESIGN.md.template"
			if [[ -f "$design_template" ]]; then
				sed "s/{Project Name}/$repo_name/g" "$design_template" >"$project_root/DESIGN.md"
				print_success "Created DESIGN.md (design system skeleton — populate with tools/design/design-md.md)"
			fi
		else
			print_info "DESIGN.md already exists, skipping"
		fi
	else
		print_info "DESIGN.md skipped (init_scope: $init_scope)"
	fi

	# Courtesy files (README, LICENCE, CHANGELOG, etc.) — scope handled internally
	scaffold_repo_courtesy_files "$project_root" "$init_scope"

	# MODELS.md — requires standard scope
	if _scope_includes "$init_scope" "standard"; then
		local generate_models_script="$AGENTS_DIR/scripts/generate-models-md.sh"
		if [[ -x "$generate_models_script" ]] && command -v sqlite3 &>/dev/null; then
			print_info "Generating MODELS.md (model performance leaderboard)..."
			if "$generate_models_script" --output "$project_root/MODELS.md" --repo-path "$project_root" --quiet 2>/dev/null; then
				print_success "Created MODELS.md (per-repo model leaderboard)"
			else
				print_warning "MODELS.md generation failed (will be populated as tasks run)"
			fi
		else
			print_info "MODELS.md skipped (sqlite3 or generate script not available)"
		fi
	else
		print_info "MODELS.md skipped (init_scope: $init_scope)"
	fi

	return 0
}

# Init command - initialize aidevops in a project
cmd_init() {
	local features="${1:-all}"

	print_header "Initialize AI DevOps in Project"
	echo ""

	# Check if we're in a git repo
	if ! git rev-parse --is-inside-work-tree &>/dev/null; then
		print_error "Not in a git repository"
		print_info "Run 'git init' first or navigate to a git repository"
		return 1
	fi

	# Check for protected branch and offer worktree
	if ! check_protected_branch "chore" "aidevops-init"; then
		return 1
	fi

	local project_root
	project_root=$(git rev-parse --show-toplevel)
	print_info "Project root: $project_root"
	echo ""

	# Parse features using helper
	local parsed
	parsed=$(_init_parse_features "$features")
	local enable_planning=false enable_git_workflow=false enable_code_quality=false
	local enable_time_tracking=false enable_database=false enable_beads=false
	local enable_sops=false enable_security=false
	local _f
	for _f in $parsed; do
		case "$_f" in
		planning) enable_planning=true ;; git_workflow) enable_git_workflow=true ;;
		code_quality) enable_code_quality=true ;; time_tracking) enable_time_tracking=true ;;
		database) enable_database=true ;; beads) enable_beads=true ;;
		sops) enable_sops=true ;; security) enable_security=true ;;
		esac
	done

	# Determine init_scope: minimal | standard | public
	# Infer from context when not set; user can override via repos.json or .aidevops.json
	local init_scope
	init_scope=$(_infer_init_scope "$project_root")
	print_info "Init scope: $init_scope (controls which scaffolding files are created)"

	# Create .aidevops.json config
	local config_file="$project_root/.aidevops.json"
	local aidevops_version
	aidevops_version=$(get_version)

	print_info "Creating .aidevops.json..."
	cat >"$config_file" <<EOF
{
  "version": "$aidevops_version",
  "initialized": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "init_scope": "$init_scope",
  "features": {
    "planning": $enable_planning,
    "git_workflow": $enable_git_workflow,
    "code_quality": $enable_code_quality,
    "time_tracking": $enable_time_tracking,
    "database": $enable_database,
    "beads": $enable_beads,
    "sops": $enable_sops,
    "security": $enable_security
  },
  "time_tracking": {
    "enabled": $enable_time_tracking,
    "prompt_on_commit": true,
    "auto_record_branch_start": true
  },
  "database": {
    "enabled": $enable_database,
    "schema_path": "schemas",
    "migrations_path": "migrations",
    "seeds_path": "seeds",
    "auto_generate_migration": true
  },
  "beads": {
    "enabled": $enable_beads,
    "sync_on_commit": false,
    "auto_ready_check": true
  },
  "sops": {
    "enabled": $enable_sops,
    "backend": "age",
    "patterns": ["*.secret.yaml", "*.secret.json", "configs/*.enc.json", "configs/*.enc.yaml"]
  },
  "plugins": []
}
EOF
	# Note: plugins array is always present but empty by default.
	# Users add plugins via: aidevops plugin add <repo-url> [--namespace <name>]
	# Schema per plugin entry:
	# {
	#   "name": "pro",
	#   "repo": "https://github.com/user/aidevops-pro.git",
	#   "branch": "main",
	#   "namespace": "pro",
	#   "enabled": true
	# }
	# Plugins deploy to ~/.aidevops/agents/<namespace>/ (namespaced, no collisions)
	print_success "Created .aidevops.json"

	# Derive repo name for scaffolding
	# In worktrees, basename gives the worktree dir name (e.g., "repo-chore-foo"),
	# not the actual repo name. Prefer: git remote URL > main worktree basename > cwd basename.
	local repo_name
	local remote_url
	remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || true)
	local repo_slug=""
	if [[ -n "$remote_url" ]]; then
		repo_slug=$(echo "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	fi
	if [[ -n "$remote_url" ]]; then
		repo_name=$(basename "$remote_url" .git)
	else
		# No remote — try main worktree path (first line of `git worktree list`)
		local main_wt
		main_wt=$(git -C "$project_root" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
		if [[ -n "$main_wt" ]]; then
			repo_name=$(basename "$main_wt")
		else
			repo_name=$(basename "$project_root")
		fi
	fi

	# Create .agents/ directory for project-specific agent context
	# (The aidevops framework is loaded globally via ~/.aidevops/agents/ — this
	# directory is for project-specific agents, conventions, and architecture docs)
	if [[ -L "$project_root/.agents" ]]; then
		# Migrate legacy symlink to real directory
		rm -f "$project_root/.agents"
		print_info "Removed legacy .agents symlink (framework is loaded globally now)"
	fi
	# Also clean up legacy .agent symlink/directory
	if [[ -L "$project_root/.agent" ]]; then
		rm -f "$project_root/.agent"
		print_info "Removed legacy .agent symlink"
	elif [[ -d "$project_root/.agent" && ! -d "$project_root/.agents" ]]; then
		mv "$project_root/.agent" "$project_root/.agents"
		print_success "Migrated .agent/ -> .agents/ directory"
	fi

	if [[ ! -d "$project_root/.agents" ]]; then
		mkdir -p "$project_root/.agents"
		print_success "Created .agents/ directory"
	fi

	# Link .agents/commands/ and .windsurf/workflows/ so Amp (native) and Windsurf
	# (symlinked) can see the aidevops main-agent slash commands.
	_init_scaffold_commands_symlinks "$project_root"

	# Scaffold or update .agents/AGENTS.md (idempotent — creates if missing,
	# updates Security section if file already exists)
	local _agents_md_existed=false
	[[ -f "$project_root/.agents/AGENTS.md" ]] && _agents_md_existed=true
	scaffold_agents_md "$project_root"
	if [[ "$_agents_md_existed" == "true" ]]; then
		print_success "Updated Security section in .agents/AGENTS.md"
	else
		print_success "Created .agents/AGENTS.md"
	fi

	# Scaffold root AGENTS.md if missing
	if [[ ! -f "$project_root/AGENTS.md" ]]; then
		cat >"$project_root/AGENTS.md" <<ROOTAGENTSEOF
# $repo_name

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Build**: \`# TODO: add build command\`
- **Test**: \`# TODO: add test command\`
- **Deploy**: \`# TODO: add deploy command\`

## Project Overview

<!-- Brief description of what this project does and why it exists. -->

## Architecture

<!-- Key architectural decisions, tech stack, directory structure. -->

## Conventions

- Commits: [Conventional Commits](https://www.conventionalcommits.org/)
- Branches: \`feature/\`, \`bugfix/\`, \`hotfix/\`, \`refactor/\`, \`chore/\`

## Key Files

| File | Purpose |
|------|---------|
| \`.agents/AGENTS.md\` | Project-specific agent instructions |
| \`TODO.md\` | Task tracking |
| \`CHANGELOG.md\` | Version history |

<!-- AI-CONTEXT-END -->
ROOTAGENTSEOF
		print_success "Created AGENTS.md"
	fi

	# Create planning files if enabled
	if [[ "$enable_planning" == "true" ]]; then
		print_info "Setting up planning files..."

		# Create TODO.md from template
		if [[ ! -f "$project_root/TODO.md" ]]; then
			if [[ -f "$AGENTS_DIR/templates/todo-template.md" ]]; then
				cp "$AGENTS_DIR/templates/todo-template.md" "$project_root/TODO.md"
				print_success "Created TODO.md"
			else
				# Fallback minimal template
				cat >"$project_root/TODO.md" <<'EOF'
# TODO

## In Progress

<!-- Tasks currently being worked on -->

## Backlog

<!-- Prioritized list of upcoming tasks -->

---

*Format: `- [ ] Task description @owner #tag ~estimate`*
*Time tracking: `started:`, `completed:`, `actual:`*
EOF
				print_success "Created TODO.md (minimal template)"
			fi
		else
			print_warning "TODO.md already exists, skipping"
		fi

		# Create todo/ directory and PLANS.md
		mkdir -p "$project_root/todo/tasks"

		if [[ ! -f "$project_root/todo/PLANS.md" ]]; then
			if [[ -f "$AGENTS_DIR/templates/plans-template.md" ]]; then
				cp "$AGENTS_DIR/templates/plans-template.md" "$project_root/todo/PLANS.md"
				print_success "Created todo/PLANS.md"
			else
				# Fallback minimal template
				cat >"$project_root/todo/PLANS.md" <<'EOF'
# Execution Plans

Complex, multi-session work that requires detailed planning.

## Active Plans

<!-- Plans currently in progress -->

## Completed Plans

<!-- Archived completed plans -->

---

*See `.agents/workflows/plans.md` for planning workflow*
EOF
				print_success "Created todo/PLANS.md (minimal template)"
			fi
		else
			print_warning "todo/PLANS.md already exists, skipping"
		fi

		# Create .gitkeep in tasks
		touch "$project_root/todo/tasks/.gitkeep"

		# Seed mission-control starter template for personal/org control repos
		local init_actor=""
		if command -v gh &>/dev/null; then
			init_actor=$(gh api user --jq '.login' 2>/dev/null || echo "")
		fi
		local mission_scope=""
		mission_scope=$(_resolve_mission_control_scope "$repo_slug" "$init_actor" 2>/dev/null || echo "")
		_seed_mission_control_template "$project_root" "$mission_scope"
	fi

	# Create database directories if enabled
	if [[ "$enable_database" == "true" ]]; then
		print_info "Setting up database schema directories..."

		# Create schemas directory with AGENTS.md
		if [[ ! -d "$project_root/schemas" ]]; then
			mkdir -p "$project_root/schemas"
			cat >"$project_root/schemas/AGENTS.md" <<'EOF'
# Database Schemas

Declarative schema files - source of truth for database structure.

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
			print_success "Created schemas/ directory"
		else
			print_warning "schemas/ already exists, skipping"
		fi

		# Create migrations directory with AGENTS.md
		if [[ ! -d "$project_root/migrations" ]]; then
			mkdir -p "$project_root/migrations"
			cat >"$project_root/migrations/AGENTS.md" <<'EOF'
# Database Migrations

Auto-generated versioned migration files. Do not edit manually.

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
			print_success "Created migrations/ directory"
		else
			print_warning "migrations/ already exists, skipping"
		fi

		# Create seeds directory with AGENTS.md
		if [[ ! -d "$project_root/seeds" ]]; then
			mkdir -p "$project_root/seeds"
			cat >"$project_root/seeds/AGENTS.md" <<'EOF'
# Database Seeds

Initial and reference data (roles, statuses, test accounts).

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
			print_success "Created seeds/ directory"
		else
			print_warning "seeds/ already exists, skipping"
		fi
	fi

	# Initialize Beads if enabled
	if [[ "$enable_beads" == "true" ]]; then
		print_info "Setting up Beads task graph..."

		# Check if Beads CLI is installed
		if ! command -v bd &>/dev/null; then
			print_warning "Beads CLI (bd) not installed"
			echo "  Install with: brew install steveyegge/beads/bd"
			echo "  Or download: https://github.com/steveyegge/beads/releases"
			echo "  Or via Go:   go install github.com/steveyegge/beads/cmd/bd@latest"
		else
			# Initialize Beads in the project
			if [[ ! -d "$project_root/.beads" ]]; then
				print_info "Initializing Beads database..."
				if (cd "$project_root" && bd init 2>/dev/null); then
					print_success "Beads initialized"
				else
					print_warning "Beads init failed - run manually: bd init"
				fi
			else
				print_info "Beads already initialized"
			fi

			# Run initial sync from TODO.md/PLANS.md
			if [[ -f "$AGENTS_DIR/scripts/beads-sync-helper.sh" ]]; then
				print_info "Syncing tasks to Beads..."
				if bash "$AGENTS_DIR/scripts/beads-sync-helper.sh" push "$project_root" 2>/dev/null; then
					print_success "Tasks synced to Beads"
				else
					print_warning "Beads sync failed - run manually: beads-sync-helper.sh push"
				fi
			fi
		fi
	fi

	# Initialize SOPS if enabled
	if [[ "$enable_sops" == "true" ]]; then
		print_info "Setting up SOPS encrypted config support..."

		# Check for sops and age
		local sops_ready=true
		if ! command -v sops &>/dev/null; then
			print_warning "SOPS not installed"
			echo "  Install with: brew install sops"
			sops_ready=false
		fi
		if ! command -v age-keygen &>/dev/null; then
			print_warning "age not installed (default SOPS backend)"
			echo "  Install with: brew install age"
			sops_ready=false
		fi

		# Generate age key if none exists
		local age_key_file="$HOME/.config/sops/age/keys.txt"
		if [[ "$sops_ready" == "true" ]] && [[ ! -f "$age_key_file" ]]; then
			print_info "Generating age key for SOPS..."
			mkdir -p "$(dirname "$age_key_file")"
			age-keygen -o "$age_key_file" 2>/dev/null
			chmod 600 "$age_key_file"
			print_success "Age key generated at $age_key_file"
		fi

		# Create .sops.yaml if it doesn't exist
		if [[ ! -f "$project_root/.sops.yaml" ]]; then
			local age_pubkey=""
			if [[ -f "$age_key_file" ]]; then
				age_pubkey=$(grep -o 'age1[a-z0-9]*' "$age_key_file" | head -1)
			fi

			if [[ -n "$age_pubkey" ]]; then
				cat >"$project_root/.sops.yaml" <<SOPSEOF
# SOPS configuration - encrypts values in config files while keeping keys visible
# See: .agents/tools/credentials/sops.md
creation_rules:
  - path_regex: '\.secret\.(yaml|yml|json)$'
    age: >-
      $age_pubkey
  - path_regex: 'configs/.*\.enc\.(yaml|yml|json)$'
    age: >-
      $age_pubkey
SOPSEOF
				print_success "Created .sops.yaml with age key"
			else
				cat >"$project_root/.sops.yaml" <<'SOPSEOF'
# SOPS configuration - encrypts values in config files while keeping keys visible
# See: .agents/tools/credentials/sops.md
#
# Generate an age key first:
#   age-keygen -o ~/.config/sops/age/keys.txt
#
# Then replace AGE_PUBLIC_KEY below with your public key:
creation_rules:
  - path_regex: '\.secret\.(yaml|yml|json)$'
    age: >-
      AGE_PUBLIC_KEY
  - path_regex: 'configs/.*\.enc\.(yaml|yml|json)$'
    age: >-
      AGE_PUBLIC_KEY
SOPSEOF
				print_warning "Created .sops.yaml template (replace AGE_PUBLIC_KEY with your key)"
			fi
		else
			print_info ".sops.yaml already exists"
		fi
	fi

	# Ensure .gitattributes has ai-training=false (opt out of AI model training)
	# GitHub and other platforms respect this attribute to exclude repo content
	# from AI/ML training datasets. Idempotent — only adds if not already present.
	local gitattributes="$project_root/.gitattributes"
	if [[ -f "$gitattributes" ]]; then
		if ! grep -qE '^\*[[:space:]]+ai-training=false' "$gitattributes" 2>/dev/null; then
			ensure_trailing_newline "$gitattributes"
			{
				echo ""
				echo "# Opt out of AI model training"
				echo "* ai-training=false"
			} >>"$gitattributes"
			print_success "Added ai-training=false to .gitattributes"
		else
			print_info ".gitattributes already has ai-training=false"
		fi
	else
		cat >"$gitattributes" <<'GITATTRSEOF'
# Opt out of AI model training
* ai-training=false
GITATTRSEOF
		print_success "Created .gitattributes with ai-training=false"
	fi

	# Add aidevops runtime artifacts to .gitignore
	# Note: .agents/ itself is NOT ignored — it contains committed project-specific agents.
	# Only runtime artifacts (loop state, tmp, memory) are ignored.
	local gitignore="$project_root/.gitignore"
	if [[ -f "$gitignore" ]]; then
		local gitignore_updated=false

		# Remove legacy bare ".agents" entry if present (was added by older versions)
		if grep -q "^\.agents$" "$gitignore" 2>/dev/null; then
			sed -i '' '/^\.agents$/d' "$gitignore" 2>/dev/null ||
				sed -i '/^\.agents$/d' "$gitignore" 2>/dev/null || true
			# Also remove the "# aidevops" comment if it's now orphaned
			sed -i '' '/^# aidevops$/{ N; /^# aidevops\n$/d; }' "$gitignore" 2>/dev/null || true
			print_info "Removed legacy bare .agents from .gitignore (now tracked)"
			gitignore_updated=true
		fi

		# Remove legacy bare ".agent" entry if present
		if grep -q "^\.agent$" "$gitignore" 2>/dev/null; then
			sed -i '' '/^\.agent$/d' "$gitignore" 2>/dev/null ||
				sed -i '/^\.agent$/d' "$gitignore" 2>/dev/null || true
			gitignore_updated=true
		fi

		# Add runtime artifact ignores
		if ! grep -q "^\.agents/loop-state/" "$gitignore" 2>/dev/null; then
			# Ensure trailing newline before appending (prevents malformed entries like *.zip.agents/loop-state/)
			ensure_trailing_newline "$gitignore"
			{
				echo ""
				echo "# aidevops runtime artifacts"
				echo ".agents/loop-state/"
				echo ".agents/tmp/"
				echo ".agents/memory/"
			} >>"$gitignore"
			print_success "Added .agents/ runtime artifact ignores to .gitignore"
			gitignore_updated=true
		fi

		# Add .aidevops.json to gitignore (local config, not committed).
		# If .aidevops.json is already tracked by git (committed by older framework
		# versions), untrack it first — adding a tracked file to .gitignore is a
		# no-op and the file keeps showing in git diff on every re-init (#2570 bug 3).
		if ! grep -q "^\.aidevops\.json$" "$gitignore" 2>/dev/null; then
			if git -C "$project_root" ls-files --error-unmatch .aidevops.json &>/dev/null; then
				git -C "$project_root" rm --cached .aidevops.json &>/dev/null || true
				print_info "Untracked .aidevops.json from git (was committed by older version)"
			fi
			# Ensure trailing newline before appending
			ensure_trailing_newline "$gitignore"
			echo ".aidevops.json" >>"$gitignore"
			gitignore_updated=true
		fi

		# Add .beads if beads is enabled
		if [[ "$enable_beads" == "true" ]]; then
			if ! grep -q "^\.beads$" "$gitignore" 2>/dev/null; then
				# Ensure trailing newline before appending
				ensure_trailing_newline "$gitignore"
				echo ".beads" >>"$gitignore"
				print_success "Added .beads to .gitignore"
				gitignore_updated=true
			fi
		fi

		if [[ "$gitignore_updated" == "true" ]]; then
			print_info "Updated .gitignore"
		fi
	fi

	# Scaffold optional files gated by init_scope (collaborator pointers,
	# DESIGN.md, courtesy files, MODELS.md). Extracted to reduce cmd_init
	# nesting depth and function length (t2265).
	_init_scaffold_scope_gated_files "$project_root" "$init_scope" "$repo_name"

	# ─── Badge initialization (t2975) ────────────────────────────────────────
	# Install the loc-badge caller workflow and seed the canonical README badge
	# block in fresh repos. Both operations are idempotent. Skip for local_only
	# repos (no remote to host SVGs or run GitHub Actions).
	local _badges_helper="$AGENTS_DIR/scripts/readme-badges-helper.sh"
	local _wf_template="$AGENTS_DIR/templates/workflows/loc-badge-caller.yml"
	local _wf_dest="$project_root/.github/workflows/loc-badge.yml"

	if [[ -n "$repo_slug" ]]; then
		# Install loc-badge caller workflow if template is available and file is absent
		if [[ -f "$_wf_template" && ! -f "$_wf_dest" ]]; then
			mkdir -p "$project_root/.github/workflows"
			cp "$_wf_template" "$_wf_dest"
			print_success "Installed .github/workflows/loc-badge.yml (LOC badge workflow)"
		elif [[ -f "$_wf_dest" ]]; then
			print_info ".github/workflows/loc-badge.yml already present"
		fi

		# Seed the canonical badge block in README.md
		local _readme_path="$project_root/README.md"
		if [[ -f "$_badges_helper" && -f "$_readme_path" ]]; then
			if bash "$_badges_helper" inject "$_readme_path" "$repo_slug" 2>/dev/null; then
				print_success "Seeded canonical badge block in README.md"
			else
				print_warning "Badge block injection failed — run manually: aidevops badges sync --repo $repo_slug --apply"
			fi
		elif [[ ! -f "$_readme_path" ]]; then
			print_info "No README.md found — skipping badge block injection (create README.md first)"
		fi

		# Remind about SYNC_PAT if the repo has a remote and isn't local_only
		local _is_local_only
		_is_local_only=$(jq -r --arg s "$repo_slug" \
			'.initialized_repos // [] | map(select(.slug == $s)) | if length > 0 then .[0].local_only // false else false end' \
			"$HOME/.config/aidevops/repos.json" 2>/dev/null || echo "false")
		if [[ "$_is_local_only" != "true" ]]; then
			print_info "Reminder: set SYNC_PAT secret so GitHub Actions can push badge SVGs — see: aidevops --help sync-pat"
		fi
	fi

	# Run security posture assessment if enabled (t1412.11)
	if [[ "$enable_security" == "true" ]]; then
		local security_posture_script="$AGENTS_DIR/scripts/security-posture-helper.sh"
		if [[ -f "$security_posture_script" ]]; then
			print_info "Running security posture assessment..."
			if bash "$security_posture_script" store "$project_root"; then
				print_success "Security posture assessed and stored in .aidevops.json"
			else
				print_warning "Security posture assessment found issues (review with: aidevops security audit)"
			fi
		else
			print_info "Security posture check skipped (security-posture-helper.sh not available)"
		fi
	fi

	# Build features string for registration
	local features_list=""
	[[ "$enable_planning" == "true" ]] && features_list="${features_list}planning,"
	[[ "$enable_git_workflow" == "true" ]] && features_list="${features_list}git-workflow,"
	[[ "$enable_code_quality" == "true" ]] && features_list="${features_list}code-quality,"
	[[ "$enable_time_tracking" == "true" ]] && features_list="${features_list}time-tracking,"
	[[ "$enable_database" == "true" ]] && features_list="${features_list}database,"
	[[ "$enable_beads" == "true" ]] && features_list="${features_list}beads,"
	[[ "$enable_sops" == "true" ]] && features_list="${features_list}sops,"
	[[ "$enable_security" == "true" ]] && features_list="${features_list}security,"
	features_list="${features_list%,}" # Remove trailing comma

	# Register the *main* repo path (not the worktree path) in repos.json.
	# When check_protected_branch creates a worktree and cd's into it,
	# $project_root (resolved via git rev-parse --show-toplevel) points to the
	# worktree directory. We must register the canonical main worktree path so
	# that pulse and cleanup processes don't treat the worktree as a standalone repo.
	local register_path="$project_root"
	if [[ -n "${WORKTREE_PATH:-}" ]]; then
		# We're inside a worktree — resolve the main worktree path from git metadata
		local main_wt_path
		main_wt_path=$(git -C "$project_root" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
		if [[ -n "$main_wt_path" ]] && [[ "$main_wt_path" != "$project_root" ]]; then
			register_path="$main_wt_path"
		fi
	fi
	register_repo "$register_path" "$aidevops_version" "$features_list"

	# Auto-commit initialized files so they don't linger as mystery unstaged
	# changes (#2570 bug 2). Collect all files that cmd_init creates/modifies.
	local init_files=()
	[[ -f "$project_root/.gitattributes" ]] && init_files+=(".gitattributes")
	[[ -f "$project_root/.gitignore" ]] && init_files+=(".gitignore")
	[[ -d "$project_root/.agents" ]] && init_files+=(".agents/")
	[[ -f "$project_root/AGENTS.md" ]] && init_files+=("AGENTS.md")
	[[ -f "$project_root/DESIGN.md" ]] && init_files+=("DESIGN.md")
	[[ -f "$project_root/TODO.md" ]] && init_files+=("TODO.md")
	[[ -d "$project_root/todo" ]] && init_files+=("todo/")
	[[ -f "$project_root/MODELS.md" ]] && init_files+=("MODELS.md")
	[[ -f "$project_root/LICENCE" ]] && init_files+=("LICENCE")
	[[ -f "$project_root/CHANGELOG.md" ]] && init_files+=("CHANGELOG.md")
	[[ -f "$project_root/README.md" ]] && init_files+=("README.md")
	[[ -f "$project_root/.cursorrules" ]] && init_files+=(".cursorrules")
	[[ -f "$project_root/.windsurfrules" ]] && init_files+=(".windsurfrules")
	[[ -f "$project_root/.clinerules" ]] && init_files+=(".clinerules")
	[[ -d "$project_root/.github" ]] && init_files+=(".github/")
	[[ -f "$project_root/.sops.yaml" ]] && init_files+=(".sops.yaml")
	[[ -d "$project_root/schemas" ]] && init_files+=("schemas/")
	[[ -d "$project_root/migrations" ]] && init_files+=("migrations/")
	[[ -d "$project_root/seeds" ]] && init_files+=("seeds/")

	local committed=false
	if [[ ${#init_files[@]} -gt 0 ]]; then
		# Stage all init files (--force not needed; .aidevops.json is gitignored above)
		if git -C "$project_root" add -- "${init_files[@]}" 2>/dev/null; then
			# Only commit if there are staged changes
			if ! git -C "$project_root" diff --cached --quiet 2>/dev/null; then
				if git -C "$project_root" commit -m "chore: initialize aidevops v${aidevops_version}" 2>/dev/null; then
					committed=true
					print_success "Committed initialized files"
				else
					print_warning "Auto-commit failed (pre-commit hook rejected?)"
				fi
			fi
		fi
	fi

	echo ""
	print_success "AI DevOps initialized! (scope: $init_scope)"
	echo ""
	echo "Enabled features:"
	[[ "$enable_planning" == "true" ]] && echo "  ✓ Planning (TODO.md, PLANS.md)"
	[[ "$enable_git_workflow" == "true" ]] && echo "  ✓ Git workflow (branch management)"
	[[ "$enable_code_quality" == "true" ]] && echo "  ✓ Code quality (linting, auditing)"
	[[ "$enable_time_tracking" == "true" ]] && echo "  ✓ Time tracking (estimates, actuals)"
	[[ "$enable_database" == "true" ]] && echo "  ✓ Database (schemas/, migrations/, seeds/)"
	[[ "$enable_beads" == "true" ]] && echo "  ✓ Beads (task graph visualization)"
	[[ "$enable_sops" == "true" ]] && echo "  ✓ SOPS (encrypted config files with age backend)"
	[[ "$enable_security" == "true" ]] && echo "  ✓ Security (per-repo posture assessment)"
	[[ -f "$project_root/MODELS.md" ]] && echo "  ✓ MODELS.md (per-repo model performance leaderboard)"
	echo ""
	# When init ran inside a worktree (check_protected_branch created one),
	# print explicit instructions so the user knows where to find their work.
	# Without this, the user's shell is back in the main repo after aidevops exits
	# and the worktree appears to have "disappeared".
	if [[ -n "${WORKTREE_PATH:-}" ]]; then
		local worktree_branch
		worktree_branch=$(git branch --show-current 2>/dev/null || echo "chore/aidevops-init")
		echo "Worktree location:"
		echo "  $WORKTREE_PATH"
		echo ""
		echo "Your init commit is in the worktree above. To continue:"
		echo "  cd $WORKTREE_PATH"
		echo "  git push -u origin ${worktree_branch}"
		echo "  gh pr create --fill" # aidevops-allow: raw-gh-wrapper
		echo ""
	fi
	echo "Next steps:"
	local step=1
	if [[ "$committed" != "true" ]]; then
		echo "  ${step}. Commit the initialized files: git add -A && git commit -m 'chore: initialize aidevops'"
		((++step))
	fi
	if [[ "$enable_beads" == "true" ]]; then
		echo "  ${step}. Add tasks to TODO.md with dependencies (blocked-by:t001)"
		((++step))
		echo "  ${step}. Run /ready to see unblocked tasks"
		((++step))
		echo "  ${step}. Run /sync-beads to sync with Beads graph"
		((++step))
		echo "  ${step}. Use 'bd' CLI for graph visualization"
	elif [[ "$enable_database" == "true" ]]; then
		echo "  ${step}. Add schema files to schemas/"
		((++step))
		echo "  ${step}. Run diff to generate migrations"
		((++step))
		echo "  ${step}. See .agents/workflows/sql-migrations.md"
	else
		echo "  ${step}. Add tasks to TODO.md"
		((++step))
		echo "  ${step}. Use /create-prd for complex features"
		((++step))
		echo "  ${step}. Use /feature to start development"
	fi

	return 0
}
