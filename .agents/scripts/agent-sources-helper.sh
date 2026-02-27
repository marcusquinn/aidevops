#!/usr/bin/env bash
# agent-sources-helper.sh — Sync agents from private repositories into custom/
#
# Usage:
#   agent-sources-helper.sh sync              Sync all configured sources
#   agent-sources-helper.sh add <path>        Add a local repo as agent source
#   agent-sources-helper.sh add-remote <url>  Clone a remote repo and add as source
#   agent-sources-helper.sh remove <name>     Remove a source (keeps synced agents)
#   agent-sources-helper.sh list              List configured sources
#   agent-sources-helper.sh status            Show sync status for all sources
#   agent-sources-helper.sh help              Show this help
#
# Private agent repos contain a .agents/ directory with agent folders.
# Each agent folder is synced into ~/.aidevops/agents/custom/<source-name>/<agent>/

set -euo pipefail

AGENTS_DIR="${HOME}/.aidevops/agents"
CUSTOM_DIR="${AGENTS_DIR}/custom"
CONFIG_FILE="${AGENTS_DIR}/configs/agent-sources.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
	echo -e "${BLUE}[INFO]${NC} $1"
	return 0
}
success() {
	echo -e "${GREEN}[OK]${NC} $1"
	return 0
}
warn() {
	echo -e "${YELLOW}[WARN]${NC} $1"
	return 0
}
error() {
	echo -e "${RED}[ERROR]${NC} $1"
	return 1
}

show_help() {
	echo "agent-sources-helper.sh — Sync agents from private repositories"
	echo ""
	echo "Usage:"
	echo "  agent-sources-helper.sh sync              Sync all configured sources"
	echo "  agent-sources-helper.sh add <path>        Add a local repo as agent source"
	echo "  agent-sources-helper.sh add-remote <url>  Clone a remote repo and add"
	echo "  agent-sources-helper.sh remove <name>     Remove a source config"
	echo "  agent-sources-helper.sh list              List configured sources"
	echo "  agent-sources-helper.sh status            Show sync status"
	echo "  agent-sources-helper.sh help              Show this help"
	echo ""
	echo "Private repos must contain a .agents/ directory with agent folders."
	echo "Agents are synced into ~/.aidevops/agents/custom/<source-name>/<agent>/"
	return 0
}

ensure_config() {
	if [[ ! -f "${CONFIG_FILE}" ]]; then
		mkdir -p "$(dirname "${CONFIG_FILE}")"
		cat >"${CONFIG_FILE}" <<'DEFAULTJSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$comment": "Private agent repositories synced into ~/.aidevops/agents/custom/",
  "version": "1.0.0",
  "sources": []
}
DEFAULTJSON
		info "Created ${CONFIG_FILE}"
	fi
	return 0
}

# Read sources from config using node (available everywhere aidevops runs)
get_sources_json() {
	node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync('${CONFIG_FILE}', 'utf8'));
        console.log(JSON.stringify(cfg.sources || []));
    " 2>/dev/null || echo "[]"
	return 0
}

get_source_count() {
	node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync('${CONFIG_FILE}', 'utf8'));
        console.log((cfg.sources || []).length);
    " 2>/dev/null || echo "0"
	return 0
}

get_source_field() {
	local index="$1"
	local field="$2"
	node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync('${CONFIG_FILE}', 'utf8'));
        const src = (cfg.sources || [])[${index}];
        console.log(src ? src['${field}'] || '' : '');
    " 2>/dev/null || echo ""
	return 0
}

add_source_to_config() {
	local name="$1"
	local local_path="$2"
	local remote_url="${3:-}"

	SOURCE_NAME="$name" SOURCE_PATH="$local_path" SOURCE_URL="$remote_url" \
		CONFIG_PATH="${CONFIG_FILE}" node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync(process.env.CONFIG_PATH, 'utf8'));
        if (!cfg.sources) cfg.sources = [];
        const name = process.env.SOURCE_NAME;
        const local_path = process.env.SOURCE_PATH;
        const remote_url = process.env.SOURCE_URL || '';

        // Check for duplicate
        const existing = cfg.sources.findIndex(s => s.name === name);
        if (existing >= 0) {
            cfg.sources[existing].local_path = local_path;
            cfg.sources[existing].remote_url = remote_url;
            cfg.sources[existing].updated_at = new Date().toISOString();
        } else {
            cfg.sources.push({
                name: name,
                local_path: local_path,
                remote_url: remote_url,
                added_at: new Date().toISOString(),
                last_synced: ''
            });
        }
        fs.writeFileSync(process.env.CONFIG_PATH, JSON.stringify(cfg, null, 2) + '\n');
    " 2>/dev/null
	return 0
}

remove_source_from_config() {
	local name="$1"
	SOURCE_NAME="$name" CONFIG_PATH="${CONFIG_FILE}" node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync(process.env.CONFIG_PATH, 'utf8'));
        cfg.sources = (cfg.sources || []).filter(s => s.name !== process.env.SOURCE_NAME);
        fs.writeFileSync(process.env.CONFIG_PATH, JSON.stringify(cfg, null, 2) + '\n');
    " 2>/dev/null
	return 0
}

update_last_synced() {
	local name="$1"
	local agent_count="$2"
	SOURCE_NAME="$name" AGENT_COUNT="$agent_count" CONFIG_PATH="${CONFIG_FILE}" node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync(process.env.CONFIG_PATH, 'utf8'));
        const src = (cfg.sources || []).find(s => s.name === process.env.SOURCE_NAME);
        if (src) {
            src.last_synced = new Date().toISOString();
            src.agent_count = parseInt(process.env.AGENT_COUNT, 10);
        }
        fs.writeFileSync(process.env.CONFIG_PATH, JSON.stringify(cfg, null, 2) + '\n');
    " 2>/dev/null
	return 0
}

# ── Commands ──

cmd_add() {
	local repo_path="$1"

	# Resolve to absolute path
	if [[ "${repo_path}" != /* ]]; then
		repo_path="$(cd "${repo_path}" 2>/dev/null && pwd)" || {
			error "Directory not found: ${repo_path}"
			return 1
		}
	fi

	# Validate it has .agents/
	if [[ ! -d "${repo_path}/.agents" ]]; then
		error "No .agents/ directory found in ${repo_path}"
		echo "  Private agent repos must contain a .agents/ directory with agent folders."
		return 1
	fi

	# Derive name from directory
	local name
	name="$(basename "${repo_path}")"

	# Check for git remote URL
	local remote_url=""
	if [[ -d "${repo_path}/.git" ]]; then
		remote_url="$(cd "${repo_path}" && git remote get-url origin 2>/dev/null)" || true
	fi

	ensure_config
	add_source_to_config "${name}" "${repo_path}" "${remote_url}"
	success "Added source: ${name} (${repo_path})"

	# Count agents
	local agent_count=0
	for agent_dir in "${repo_path}/.agents"/*/; do
		[[ -d "${agent_dir}" ]] && ((agent_count++)) || true
	done
	info "Found ${agent_count} agent(s) in .agents/"

	# Offer to sync
	echo ""
	info "Run 'agent-sources-helper.sh sync' to deploy agents to custom/"
	return 0
}

cmd_add_remote() {
	local remote_url="$1"
	local clone_dir="${AIDEVOPS_GIT_DIR:-${HOME}/Git}"

	# Derive repo name from URL
	local repo_name
	repo_name="$(basename "${remote_url}" .git)"
	local local_path="${clone_dir}/${repo_name}"

	if [[ -d "${local_path}" ]]; then
		info "Repository already exists at ${local_path}, pulling latest..."
		(cd "${local_path}" && git pull --ff-only 2>/dev/null) || warn "Pull failed, using existing state"
	else
		info "Cloning ${remote_url} to ${local_path}..."
		git clone "${remote_url}" "${local_path}" 2>&1 || {
			error "Failed to clone ${remote_url}"
			return 1
		}
	fi

	cmd_add "${local_path}"
	return 0
}

cmd_remove() {
	local name="$1"
	ensure_config

	# Clean up symlinks before removing config
	cleanup_source_symlinks "${name}"

	remove_source_from_config "${name}"
	success "Removed source: ${name}"
	info "Synced agents in custom/${name}/ were NOT deleted. Remove manually if needed:"
	echo "  rm -rf ${CUSTOM_DIR}/${name}/"
	return 0
}

# Remove symlinks created by a source (primary agents + slash commands)
cleanup_source_symlinks() {
	local name="$1"
	local source_dir="${CUSTOM_DIR}/${name}"

	[[ -d "${source_dir}" ]] || return 0

	# Remove primary agent symlinks from agents root
	for agent_dir in "${source_dir}"/*/; do
		[[ -d "${agent_dir}" ]] || continue
		local agent_name
		agent_name="$(basename "${agent_dir}")"
		local link="${AGENTS_DIR}/${agent_name}.md"
		if [[ -L "${link}" ]]; then
			local target
			target="$(readlink "${link}")"
			if [[ "${target}" == *"${name}"* ]]; then
				rm -f "${link}"
				info "  Removed primary agent symlink: ${agent_name}"
			fi
		fi
	done

	# Remove slash command symlinks from OpenCode command dir
	local opencode_cmd_dir="${HOME}/.config/opencode/command"
	if [[ -d "${opencode_cmd_dir}" ]]; then
		for link in "${opencode_cmd_dir}"/*.md; do
			[[ -L "${link}" ]] || continue
			local target
			target="$(readlink "${link}")"
			if [[ "${target}" == *"${name}"* ]]; then
				rm -f "${link}"
				local cmd_name
				cmd_name="$(basename "${link}" .md)"
				info "  Removed slash command: /${cmd_name}"
			fi
		done
	fi
	return 0
}

cmd_list() {
	ensure_config
	local count
	count="$(get_source_count)"

	if [[ "${count}" == "0" ]]; then
		info "No agent sources configured."
		echo ""
		echo "Add one with:"
		echo "  agent-sources-helper.sh add ~/Git/my-private-agents"
		echo "  agent-sources-helper.sh add-remote git@github.com:user/agents.git"
		return 0
	fi

	echo "Agent Sources (${count}):"
	echo ""
	printf "  %-25s %-45s %s\n" "NAME" "PATH" "LAST SYNCED"
	printf "  %-25s %-45s %s\n" "----" "----" "-----------"

	local i=0
	while [[ ${i} -lt ${count} ]]; do
		local name path synced
		name="$(get_source_field "${i}" "name")"
		path="$(get_source_field "${i}" "local_path")"
		synced="$(get_source_field "${i}" "last_synced")"
		[[ -z "${synced}" ]] && synced="never"
		# Shorten home path
		path="${path/#${HOME}/~}"
		printf "  %-25s %-45s %s\n" "${name}" "${path}" "${synced}"
		((i++))
	done
	return 0
}

cmd_status() {
	ensure_config
	local count
	count="$(get_source_count)"

	if [[ "${count}" == "0" ]]; then
		info "No agent sources configured."
		return 0
	fi

	echo "Agent Source Status:"
	echo ""

	local i=0
	while [[ ${i} -lt ${count} ]]; do
		local name path synced remote_url
		name="$(get_source_field "${i}" "name")"
		path="$(get_source_field "${i}" "local_path")"
		synced="$(get_source_field "${i}" "last_synced")"
		remote_url="$(get_source_field "${i}" "remote_url")"

		echo "  ${name}:"
		echo "    Path:        ${path/#${HOME}/~}"
		[[ -n "${remote_url}" ]] && echo "    Remote:      ${remote_url}"
		echo "    Last synced: ${synced:-never}"

		# Check if path exists
		if [[ ! -d "${path}" ]]; then
			echo -e "    Status:      ${RED}MISSING${NC} (directory not found)"
		elif [[ ! -d "${path}/.agents" ]]; then
			echo -e "    Status:      ${RED}INVALID${NC} (no .agents/ directory)"
		else
			local agent_count=0
			for agent_dir in "${path}/.agents"/*/; do
				[[ -d "${agent_dir}" ]] && ((agent_count++)) || true
			done
			echo -e "    Status:      ${GREEN}OK${NC} (${agent_count} agents)"

			# Check if synced copy exists
			if [[ -d "${CUSTOM_DIR}/${name}" ]]; then
				local synced_count=0
				for synced_dir in "${CUSTOM_DIR}/${name}"/*/; do
					[[ -d "${synced_dir}" ]] && ((synced_count++)) || true
				done
				echo "    Deployed:    ${synced_count} agents in custom/${name}/"
			else
				echo -e "    Deployed:    ${YELLOW}NOT SYNCED${NC}"
			fi

			# Check for uncommitted changes in source
			if [[ -d "${path}/.git" ]]; then
				local dirty
				dirty="$(cd "${path}" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
				if [[ "${dirty}" != "0" ]]; then
					echo -e "    Git:         ${YELLOW}${dirty} uncommitted change(s)${NC}"
				else
					echo -e "    Git:         ${GREEN}clean${NC}"
				fi
			fi
		fi
		echo ""
		((i++))
	done
	return 0
}

cmd_sync() {
	ensure_config
	local count
	count="$(get_source_count)"

	if [[ "${count}" == "0" ]]; then
		info "No agent sources configured. Nothing to sync."
		echo "  Add a source: agent-sources-helper.sh add ~/Git/my-agents"
		return 0
	fi

	mkdir -p "${CUSTOM_DIR}"
	local total_agents=0
	local total_sources=0
	local total_primary=0
	local total_commands=0

	local i=0
	while [[ ${i} -lt ${count} ]]; do
		local name path
		name="$(get_source_field "${i}" "name")"
		path="$(get_source_field "${i}" "local_path")"

		info "Syncing: ${name} (${path/#${HOME}/~})"

		if [[ ! -d "${path}" ]]; then
			warn "  Source directory missing: ${path}"
			((i++))
			continue
		fi

		if [[ ! -d "${path}/.agents" ]]; then
			warn "  No .agents/ directory in ${path}"
			((i++))
			continue
		fi

		# Pull latest if it's a git repo
		if [[ -d "${path}/.git" ]]; then
			(cd "${path}" && git pull --ff-only 2>/dev/null) || warn "  Git pull failed, using current state"
		fi

		# Sync each agent directory from source .agents/ into custom/<source-name>/
		local dest_dir="${CUSTOM_DIR}/${name}"
		mkdir -p "${dest_dir}"

		local agent_count=0
		for agent_dir in "${path}/.agents"/*/; do
			[[ -d "${agent_dir}" ]] || continue
			local agent_name
			agent_name="$(basename "${agent_dir}")"

			# Safety: skip empty source dirs to prevent --delete wiping destination
			if [[ -z "$(find "${agent_dir}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
				warn "  Skipping empty agent directory: ${agent_name}"
				continue
			fi

			# rsync the agent directory (preserves permissions, handles deletions)
			rsync -a --delete "${agent_dir}" "${dest_dir}/${agent_name}/"
			((agent_count++))

			# Post-sync: register primary agents and deploy slash commands
			sync_primary_agent "${dest_dir}/${agent_name}" "${agent_name}"
			sync_slash_commands "${dest_dir}/${agent_name}" "${agent_name}" "${name}"
		done

		update_last_synced "${name}" "${agent_count}"
		success "  Synced ${agent_count} agent(s) to custom/${name}/"
		total_agents=$((total_agents + agent_count))
		((total_sources++))
		((i++))
	done

	echo ""
	local summary="Sync complete: ${total_agents} agent(s) from ${total_sources} source(s)"
	[[ ${total_primary} -gt 0 ]] && summary="${summary}, ${total_primary} primary agent(s)"
	[[ ${total_commands} -gt 0 ]] && summary="${summary}, ${total_commands} slash command(s)"
	success "${summary}"
	return 0
}

# Register a primary agent by symlinking its .md to the agents root
# This makes it discoverable by generate-opencode-agents.sh auto-discovery
sync_primary_agent() {
	local agent_dir="$1"
	local agent_name="$2"
	local agent_md="${agent_dir}/${agent_name}.md"

	[[ -f "${agent_md}" ]] || return 0

	# Check frontmatter for mode: primary (BSD sed compatible)
	local mode
	mode="$(sed -n '/^---$/,/^---$/p' "${agent_md}" 2>/dev/null | grep '^mode:' | head -1 | sed 's/^mode:[[:space:]]*//')" || true
	[[ "${mode}" == "primary" ]] || return 0

	# Symlink to agents root for auto-discovery
	local link_target="${AGENTS_DIR}/${agent_name}.md"
	if [[ -L "${link_target}" ]]; then
		rm -f "${link_target}"
	elif [[ -f "${link_target}" ]]; then
		# Don't overwrite a real file (core agent)
		warn "  Skipping primary agent ${agent_name}: conflicts with core agent"
		return 0
	fi

	ln -s "${agent_md}" "${link_target}"
	info "  Registered primary agent: ${agent_name}"
	((total_primary++)) || true
	return 0
}

# Deploy slash commands from an agent directory to OpenCode command dir
# Slash commands are .md files with 'agent:' in frontmatter (not the agent doc itself, not subagents)
sync_slash_commands() {
	local agent_dir="$1"
	local agent_name="$2"
	local source_name="$3"
	local opencode_cmd_dir="${HOME}/.config/opencode/command"

	mkdir -p "${opencode_cmd_dir}"

	for md_file in "${agent_dir}"/*.md; do
		[[ -f "${md_file}" ]] || continue
		local filename
		filename="$(basename "${md_file}")"

		# Skip the agent doc itself (filename matches directory name)
		[[ "${filename}" == "${agent_name}.md" ]] && continue

		# Check if this is a slash command (has 'agent:' in frontmatter, BSD sed compatible)
		if ! sed -n '/^---$/,/^---$/p' "${md_file}" 2>/dev/null | grep -q '^agent:'; then
			continue
		fi

		local cmd_name="${filename%.md}"
		local target="${opencode_cmd_dir}/${cmd_name}.md"

		# Collision detection: only suffix if a different file already exists
		if [[ -f "${target}" ]] && ! [[ -L "${target}" && "$(readlink "${target}")" == "${md_file}" ]]; then
			local suffixed_name="${cmd_name}-${source_name}"
			target="${opencode_cmd_dir}/${suffixed_name}.md"
			warn "  Command collision: /${cmd_name} exists, deploying as /${suffixed_name}"
		fi

		# Symlink rather than copy — stays in sync without re-running
		ln -sf "${md_file}" "${target}"
		((total_commands++)) || true
	done
	return 0
}

# ── Main ──

main() {
	local command="${1:-help}"
	shift || true

	case "${command}" in
	sync)
		cmd_sync
		;;
	add)
		if [[ -z "${1:-}" ]]; then
			error "Usage: agent-sources-helper.sh add <path>"
			return 1
		fi
		cmd_add "$1"
		;;
	add-remote)
		if [[ -z "${1:-}" ]]; then
			error "Usage: agent-sources-helper.sh add-remote <git-url>"
			return 1
		fi
		cmd_add_remote "$1"
		;;
	remove)
		if [[ -z "${1:-}" ]]; then
			error "Usage: agent-sources-helper.sh remove <name>"
			return 1
		fi
		cmd_remove "$1"
		;;
	list)
		cmd_list
		;;
	status)
		cmd_status
		;;
	help | --help | -h)
		show_help
		;;
	*)
		error "Unknown command: ${command}"
		show_help
		return 1
		;;
	esac
	return 0
}

main "$@"
