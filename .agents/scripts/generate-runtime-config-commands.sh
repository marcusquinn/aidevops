#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Runtime Config Generator -- Command Generation Sub-Library
# =============================================================================
# Slash command deployment for all supported runtimes. Handles per-runtime
# format transforms (OpenCode YAML, Claude Code YAML, Cursor frontmatter-strip,
# Kiro steering, Continue .prompt, Gemini CLI TOML, Kimi Skills).
#
# Usage: source "${SCRIPT_DIR}/generate-runtime-config-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - runtime-registry.sh (rt_display_name, rt_command_dir, rt_feature_commands)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_GENERATE_RUNTIME_CONFIG_COMMANDS_LIB_LOADED:-}" ]] && return 0
_GENERATE_RUNTIME_CONFIG_COMMANDS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Phase 2b: Command Generation -- Per-Runtime Adapters
# =============================================================================

# Shared command definitions -- the body content is defined once here.
# Each runtime adapter writes these to its command directory with the
# appropriate frontmatter format.

_GENERATED_HARDCODED_COMMAND_COUNT=0

# Helper: write a command file for OpenCode format
_write_opencode_command() {
	local cmd_dir="$1"
	local name="$2"
	local description="$3"
	local agent="$4"
	local subtask="$5"
	local body="$6"

	{
		echo "---"
		echo "description: ${description}"
		[[ -n "$agent" ]] && echo "agent: ${agent}"
		[[ "$subtask" == "true" ]] && echo "subtask: true"
		echo "---"
		echo ""
		echo "$body"
	} >"${cmd_dir}/${name}.md"
	return 0
}

# Helper: write a command file for Claude Code format
_write_claude_command() {
	local cmd_dir="$1"
	local name="$2"
	local description="$3"
	# Claude Code doesn't use agent/subtask fields
	local body="$4"

	cat >"${cmd_dir}/${name}.md" <<EOF
---
description: $description
---

$body
EOF
	return 0
}

# Helper: copy a source command file to a destination, stripping only
# OpenCode-specific frontmatter fields that confuse other runtimes.
# Safe default for clients that accept YAML frontmatter + markdown body
# (codex, droid, qwen, kimi, amp, windsurf).
_copy_cmd_strip_opencode_fields() {
	local src="$1"
	local dest="$2"
	sed -E '/^---$/,/^---$/{/^(agent|subtask|mode):/d;}' "$src" >"$dest"
}

# OpenCode requires model fields to contain concrete provider/model IDs. Source
# commands may instead carry canonical workload tiers for other orchestrators;
# strip only those tier values and inherit the active session model.
_copy_cmd_for_opencode() {
	local src="$1"
	local dest="$2"

	awk '
		NR == 1 && /^---$/ { in_fm = 1; print; next }
		in_fm && /^---$/ { in_fm = 0; print; next }
		in_fm && /^model: (simple|standard|thinking)$/ { next }
		{ print }
	' "$src" >"$dest" || return 1
	return 0
}

# Helper: Cursor command files -- Cursor Commands (1.6+) do not support
# YAML frontmatter at all. Strip the entire leading frontmatter block
# and emit only the markdown body.
_copy_cmd_strip_all_frontmatter() {
	local src="$1"
	local dest="$2"
	awk '
		BEGIN { in_fm = 0; past_fm = 0 }
		NR == 1 && /^---$/ { in_fm = 1; next }
		in_fm && /^---$/ { in_fm = 0; past_fm = 1; next }
		in_fm { next }
		{ print }
	' "$src" >"$dest"
}

# Helper: Kiro steering files -- copy as-is but ensure the frontmatter
# contains `inclusion: manual` so the file appears as a user-invocable
# slash command rather than an always-on steering document.
_copy_cmd_kiro_steering() {
	local src="$1"
	local dest="$2"
	local tmp
	tmp=$(mktemp)
	_copy_cmd_strip_opencode_fields "$src" "$tmp"
	if grep -q '^inclusion:' "$tmp"; then
		cp "$tmp" "$dest"
	else
		awk '
			NR == 1 && /^---$/ { print; print "inclusion: manual"; next }
			{ print }
		' "$tmp" >"$dest"
	fi
	rm -f "$tmp"
}

# Helper: Continue .prompt files -- Continue wants `.prompt` extension
# plus `invokable: true` in the frontmatter for the prompt to appear
# as a slash command in Chat/Plan/Agent modes.
_copy_cmd_continue_prompt() {
	local src="$1"
	local dest="$2" # caller already switched extension to .prompt
	local tmp
	tmp=$(mktemp)
	_copy_cmd_strip_opencode_fields "$src" "$tmp"
	if grep -q '^invokable:' "$tmp"; then
		cp "$tmp" "$dest"
	else
		awk '
			NR == 1 && /^---$/ { print; print "invokable: true"; next }
			{ print }
		' "$tmp" >"$dest"
	fi
	rm -f "$tmp"
}

# Helper: Gemini CLI TOML files -- convert markdown with YAML frontmatter
# into Gemini's documented TOML format (geminicli.com/docs/cli/custom-commands).
# Output schema:
#   description = "<extracted from frontmatter>"
#   prompt = """
#   <body after frontmatter>
#   """
# Uses basic multi-line strings (`"""`) by default; falls back to literal
# multi-line strings (`'''`) if the body contains the triple-quote sequence.
_copy_cmd_gemini_toml() {
	local src="$1"
	local dest="$2" # caller already switched extension to .toml
	local description body delim
	local warning_line=""

	# Extract `description:` value from the YAML frontmatter block (first
	# fenced `---` region). Stop at the closing marker.
	description=$(awk '
		/^---$/ {
			if (in_fm) exit
			in_fm = 1
			next
		}
		in_fm && /^description:[[:space:]]*/ {
			sub(/^description:[[:space:]]*/, "")
			sub(/[[:space:]]+$/, "")
			print
			exit
		}
	' "$src")

	# Extract the body (everything after the closing frontmatter marker).
	# If the file has no frontmatter, the whole file is the body.
	body=$(awk '
		BEGIN { in_fm = 0; past_fm = 0; has_fm = 0 }
		NR == 1 && /^---$/ { in_fm = 1; has_fm = 1; next }
		in_fm && /^---$/ { in_fm = 0; past_fm = 1; next }
		in_fm { next }
		{ print }
	' "$src")

	# Pick a multi-line string delimiter the body will not collide with.
	delim='"""'
	if printf '%s' "$body" | grep -qF '"""'; then
		delim="'''"
		if printf '%s' "$body" | grep -qF "'''"; then
			warning_line="# WARNING: body contains both \"\"\" and ''' -- prompt string may need manual fix-up"
		fi
	fi

	# Escape double quotes in the description (TOML basic string rules).
	local escaped_desc
	escaped_desc=$(printf '%s' "$description" | sed 's/\\/\\\\/g; s/"/\\"/g')

	{
		[[ -n "$warning_line" ]] && echo "$warning_line"
		if [[ -n "$description" ]]; then
			printf 'description = "%s"\n' "$escaped_desc"
		fi
		printf 'prompt = %s\n' "$delim"
		printf '%s\n' "$body"
		printf '%s\n' "$delim"
	} >"$dest"
	return 0
}

# Helper: Kimi CLI Skills -- Kimi expects a directory-per-skill layout:
#   ~/.kimi/skills/<name>/SKILL.md
# where the parent directory name MUST match the `name:` frontmatter field.
# This helper creates the subdirectory, writes SKILL.md inside it, and
# injects/corrects the required `name:` and `description:` fields.
#
# Arguments:
#   $1 - source file
#   $2 - skills root dir (e.g. ~/.kimi/skills)
#   $3 - skill name (what the directory is called)
_copy_cmd_kimi_skill() {
	local src="$1"
	local skills_root="$2"
	local name="$3"
	local skill_dir="${skills_root}/${name}"
	local dest="${skill_dir}/SKILL.md"

	mkdir -p "$skill_dir"

	# Strip OpenCode-only fields first so other clients' frontmatter doesn't
	# confuse Kimi's skill loader.
	local tmp
	tmp=$(mktemp)
	_copy_cmd_strip_opencode_fields "$src" "$tmp"

	# Ensure `name:` matches the directory name. If present, replace its
	# value; if absent, inject it right after the opening `---` marker.
	local tmp2
	tmp2=$(mktemp)
	if grep -q '^name:' "$tmp"; then
		sed "s|^name:.*|name: ${name}|" "$tmp" >"$tmp2"
	else
		awk -v n="$name" '
			NR == 1 && /^---$/ { print; print "name: " n; next }
			{ print }
		' "$tmp" >"$tmp2"
	fi

	# Ensure `description:` is present. Kimi requires it for auto-invocation;
	# inject a sensible fallback derived from the skill name if the source
	# file doesn't carry one.
	if grep -q '^description:' "$tmp2"; then
		cp "$tmp2" "$dest"
	else
		awk -v n="$name" '
			NR == 1 && /^---$/ { print; print "description: aidevops primary agent routing command: " n; next }
			{ print }
		' "$tmp2" >"$dest"
	fi

	rm -f "$tmp" "$tmp2"
	return 0
}

# Namespace prefix applied to every slash command deployed to clients.
# Differentiates aidevops commands from native client slash commands and
# groups them alphabetically in the client's command picker.
_AIDEVOPS_CMD_PREFIX="aidevops-"

# Hash the full body without runtime-specific frontmatter or outer blank lines.
_command_body_digest() {
	local file="$1"
	local digest
	digest=$(awk '
		NR == 1 && /^---$/ { in_fm = 1; next }
		in_fm && /^---$/ { in_fm = 0; next }
		in_fm { next }
		{ lines[++n] = $0 }
		END {
			first = 1
			while (first <= n && lines[first] == "") first++
			while (n >= first && lines[n] == "") n--
			for (i = first; i <= n; i++) print lines[i]
		}
	' "$file" | shasum -a 256) || return 1
	printf '%s\n' "${digest%% *}"
	return 0
}

# Prune only known, unchanged legacy output. A path reference or filename alone
# cannot establish ownership: users can write their own commands with either.
# These SHA-256 body fingerprints come from the literal create_command bodies in
# generate-opencode-commands-*.sh and maybe_write_command bodies in
# generate-claude-commands.sh. Ignore frontmatter and surrounding blank lines,
# but preserve any body edits. Also recognize unchanged auto-discovered copies of
# current source commands at these legacy names. Unknown variants survive.
# Names still written by _generate_hardcoded_commands are excluded.
_prune_legacy_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	case "$runtime_id" in
	opencode | claude-code) ;;
	*) return 0 ;;
	esac

	local name fingerprints file digest source_file source_digest
	while IFS=: read -r name fingerprints; do
		file="${cmd_dir}/${name}.md"
		# Never follow symlinks or remove directories, even at an allowlisted name.
		[[ -f "$file" && ! -L "$file" ]] || continue
		digest=$(_command_body_digest "$file") || return 1
		source_file="$HOME/.aidevops/agents/scripts/commands/${name}.md"
		if [[ -f "$source_file" ]]; then
			source_digest=$(_command_body_digest "$source_file") || return 1
			fingerprints="${fingerprints}|${source_digest}"
		fi
		case "|${fingerprints}|" in
		*"|${digest}|"*)
			rm -- "$file" || return 1
			print_info "Removed stale legacy command: $file"
			;;
		esac
	done <<'LEGACY_COMMANDS'
autocomplete-research:3ced4a07c86536e082f932b648b8dabc8792e02c1f39470fdf0cc987aeb6852c|8e8432186cf79752c36777bb04755b95ea233744a61638111146acc44030adfa
bugfix:4eb162e536d21f23909a679bb2e1891bb70027fd8082796e5878dfaacd478f89|df4df13751aae4a828452fd9c2a2c308c400681c20cbd74a2e4f69e65dd59814
changelog:04c689b6ec618da7bd38215a66884a5bcbb73af821863bf48f63d85f43de91b2|202f3a2098cdd3c3a3a8039561a300f72a697513648c18b8901d744c321dc6c9
code-audit-remote:e31d369c0719f5f9e3d34ab16729c6cf8e6fecd1630447865bc686eaf892fd61|ef7cbb9b018ebe8a6397d9f90460b6576a41e4f45bc78371c446f476838484d1
code-simplifier:384f3ecac1dea4f13f01b2a59398b343cca87379f57bc04cefc3d6d73291ea0c|cb38c41ea68ffb16c44bdb07ec7a0a4c1b485d8f18d11fff06b0abf3ea47ce10
code-standards:251c5d5e3eb0adf047a4705f0ae978f425ced0956696fdd527480ba4bcc4740b|d665b9ee943a713a073e7d0b507977bb32b8561d346f135c991ef63cdcf2b8d4
create-pr:6cce74d411d3268da56aa9901f4c428859ff10037e162a8be0ad78a915b9363b|e30927aecb53a23a8e1227dd33c4d13089ce010d1db8a7927c355bb3ac8b8e6a
create-prd:2cc6d1dcb3ec589df30d6345ede7e4a4b9c194173f8a57adcfa29d7d5b37de53|73e90fa8547ce68a7258f858f2d9ecf29232cfa6f4ee62c2374d5e53b7c3e0b4
feature:4e2af0696cdb9b6c735f79d127f3d4453fe79784b4b44ab50fe09e0985f15bbc|634c3fc232a71133d4123c6f6b0a2becfd561cf3d4a37f40936fb1dbe0b70218
full-loop:8e4e900fa7e7d59f9610602845178bed1872609847120f9697170dafba890c7e
generate-tasks:9d05c2a20c6b401678b6eb37086fa63943b847499ff1d773621a13ec06e427eb|d44886fd075b56f5e0a767b61470a9780ac685abd9a9d45bf450f9d99b9e318b
hotfix:0b491e813ea55bf5278ef87980273174e8ab6f31ebe146b37040408503634fc8|e4952f4b5ee8dc66a42fc1485d54588ca0a0d2b01aa502c6979fc3f0d6883e73
keyword-research:3cffaf9c4fc4199790417c4f62a6f352864fcf39bf38daa8dc013e0206216a18|f46740c2f36e474aea12c288940896b89b02f270ef0017582ced36d8b36262b2
keyword-research-extended:82ca24d415658783ab985699278d884810297d26506504ef008e37146a99019a|dbecc763642b76de7d314e8ace3db471a3dafe9937b5c416bdeaf5cd2901c15b
linters-local:4bc3d359315ae6ace99bcef472928c5104d786e63c304324311c363ec67b22ad|85af0275575d783b84ffa42a1d13a7f71d33358847864d8b593c164d7a34b10e
list-keys:4c096946158584bdefe03af8bae1d62565679173283d82de35ec8d5591e85a96|b4d1d25005eb3122a1dd2db580d6257d2ff3fa25630ec5f4ec99402fc3e879e1
list-todo:fce366c1f15fb55b12ef5992efee0aac6b6b17d64591ced6162039a906748f10
log-time-spent:09b24f667f1e0f1be1ce5ec3c91ea0b5c52c27059211c626354f4be260ce0893|35fef4b7de41f933becfbac755e267b0a54b9a10dd0fe22a010b4387215f8f39
plan-status:236dbb8970505818ff568f344c8ec22fb2da6e1730804d8bb16a9ffa119e7205|737d1332cef941b888f6463c761eba5c5aadd830d5026c89893e197b57b7b1b9
postflight-loop:221e154811aa1bd7bda8978d6bc191cc644e3e2f4593dd60e0de97fd06a333ea
pr:ccfa44ea2a12a000594df2c6cafb05f280f56fe3b6077dc1456692f9ad433a81
pr-loop:95c9bc2febd41989d9084a92b1f09e4bb5d7353c65488e5472517636cbcc32f3
preflight-loop:6c8b87ce2aa5d2989833a541bb0f524c49a4cbdcd92e66eb6491edac9b01b985
recall:67f989582ce662b4cf42e696712c169ed5c5af78cf06b727254c6024b27fda06
remember:537b6ccb32ce211d80982a3a9e017b8fca9988e94302b40f2f34fc26c7e68028
save-todo:080938bc6d60ccde9fd2df90a2850bb40decb631511697a0c0a6529fa432ff62
seo-agent-discovery:016a5dc06d7422ebffbe1cc5661601b557255aa5196a0ac74778e759af398a5b|7a295c552ecc56bc1ecca5c8e33a18ca2f303a1497348d0acfb92cbbc62234e5
seo-ai-baseline:17f3e2bce58bc56593a766298fbc2578e8bd20ef83eb7e22771b0cb1d5d76ddb|e49411dd970db55f9a579b5d353c45256d19138728f0e88949873420d59fcbe8
seo-ai-readiness:728425623c3f9972a6c622e6fea2acf6bd7c9d8f1fc7b54a2763ccc1e404afd8|c5352415eb286a8a6dd1bcbeffd97dfaa1f0b3ea8e338d6de6f0b8279750e54e
seo-fanout:668d2b0b2ca567491e40d129e7c28635bcf78f3566a7b26917fb315441362b40|a5b63898f22e3972f52a5e73ffaf1ac1962df20b220b3a95e85e9dc78f5d18ce
seo-geo:3f0eca92f0934798b90e8b695e7f93b6509c050bad174457f61b3b2c1addd93b|eaf719a37f02442c5aba3a8acc043c44096da7a965d81d2bab90eaf36f138502
seo-hallucination-defense:2f3b6fb40d192de0407d8e08efee47810a868c8f6bf393e2480d6fdff786dc1d|b5b02c91796d342c9bdde873e55723168fcabf07231a7a4ca50cba983a976622
seo-sro:5c57b180a3c60bb86b7ad5d177e916541e37f35b89cc5573bdda96638cddb9cc|7d34a6e8df1105f7f71ddd56d18634b6727b323ca43a1fa6b26fbbdb63bbe499
session-review:07dd5b12eca536c6cf69c61ee35f184f6e40ed2ee15ccbfc2a0a40e38ab85b2b|b8c8eddcac9ea25251e8fc1cc8a60ca60de2af1fb0403386b82a1c2bd74a7329
version-bump:86a27ab1e52f6e944541d7e9e920afdda603380e33dd966d0ae0b4ac487cbca8|fdcc820a4a3d76dea54483c88bd97a798ba38087237be128bc31dee5d2cd87d6
webmaster-keywords:6d5209db6a31e40c76ab5036f4a93ab2f931c2cf53b78ed20a890e5035ba267e|dc1a717e189d2a41bddc8cdb4cba11dd2edc7388d66ac9eb90b91d2a3e8a6d6f
LEGACY_COMMANDS
	return 0
}

# Deploy one source command file to a runtime's command directory,
# applying the correct per-runtime format transform.
# Arguments:
#   $1 - runtime_id
#   $2 - source file (full path)
#   $3 - deployed name (WITHOUT extension -- format-specific extension added here)
#   $4 - destination command dir
# Returns: 0 on success, 1 on failure.
_deploy_one_command() {
	local runtime_id="$1"
	local src="$2"
	local name="$3"
	local cmd_dir="$4"
	local dest

	case "$runtime_id" in
	opencode)
		# Canonical workload tiers are routing intent, not OpenCode model IDs.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_for_opencode "$src" "$dest" || return 1
		;;
	claude-code | codex | droid | amp | qwen)
		# Markdown + YAML frontmatter clients: strip opencode-only fields
		# (agent, subtask, mode) that other clients don't recognise.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_strip_opencode_fields "$src" "$dest" || return 1
		;;
	cursor)
		# Cursor Commands (1.6+) do not support YAML frontmatter. Strip it.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_strip_all_frontmatter "$src" "$dest" || return 1
		;;
	kiro)
		# Kiro steering files: add `inclusion: manual` so they appear as
		# user-invocable slash commands rather than always-on steering docs.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_kiro_steering "$src" "$dest" || return 1
		;;
	continue)
		# Continue: rename extension to .prompt and add `invokable: true`
		# so the file appears as a slash command in Chat/Plan/Agent modes.
		dest="${cmd_dir}/${name}.prompt"
		_copy_cmd_continue_prompt "$src" "$dest" || return 1
		;;
	gemini-cli)
		# Convert markdown + YAML frontmatter to Gemini CLI's documented TOML
		# format: `description = "..."` + `prompt = """..."""`. The helper
		# handles triple-quote collisions by falling back to literal strings.
		dest="${cmd_dir}/${name}.toml"
		_copy_cmd_gemini_toml "$src" "$dest" || return 1
		;;
	kimi)
		# Kimi Skills: directory-per-skill layout. The skill name (= directory
		# name) must match the `name:` frontmatter field. `cmd_dir` here is
		# the parent ~/.kimi/skills dir; the helper creates the subdirectory
		# and writes SKILL.md inside it.
		_copy_cmd_kimi_skill "$src" "$cmd_dir" "$name" || return 1
		;;
	kilo | windsurf | aider)
		# Kilo uses custom modes (different mechanism); Windsurf uses a
		# repo-local dir created by `aidevops init`; Aider has no native
		# slash commands. These are handled elsewhere -- skip here.
		return 0
		;;
	*)
		# Unknown runtime: conservative fall-through -- copy as-is.
		dest="${cmd_dir}/${name}.md"
		cp "$src" "$dest" || return 1
		;;
	esac
	return 0
}

# Generate all shared commands for a given runtime.
# Reads from two source directories:
#   1. ~/.aidevops/agents/commands/        -- main-agent symlinks (already
#                                            prefixed with `aidevops-`)
#   2. ~/.aidevops/agents/scripts/commands/ -- skills/workflows/utilities
#                                            (prefix is applied at deploy time)
# Gated on the per-runtime `commands` feature flag.
#
# Arguments: $1=runtime_id
_generate_commands_for_runtime() {
	local runtime_id="$1"
	local display_name
	display_name=$(rt_display_name "$runtime_id") || display_name="$runtime_id"

	# Feature flag gate -- user can disable commands installation per runtime
	# via AIDEVOPS_FEATURE_COMMANDS_<SUFFIX>=no.
	local feature_enabled
	feature_enabled=$(rt_feature_commands "$runtime_id" 2>/dev/null || echo "yes")
	if [[ "$feature_enabled" != "yes" ]]; then
		print_info "Commands installation disabled for $display_name (feature flag)"
		return 0
	fi

	local cmd_dir
	cmd_dir=$(rt_command_dir "$runtime_id") || cmd_dir=""

	if [[ -z "$cmd_dir" ]]; then
		print_info "No command directory for $display_name -- skipping commands"
		return 0
	fi

	mkdir -p "$cmd_dir"

	local command_count=0
	local skipped_count=0

	print_info "Generating $display_name commands..."

	# --- Source 1: .agents/commands/ (main-agent symlinks -- already prefixed) ---
	local main_src_dir="$HOME/.aidevops/agents/commands"
	if [[ -d "$main_src_dir" ]]; then
		local cmd_file cmd_name
		for cmd_file in "$main_src_dir"/*.md; do
			[[ -e "$cmd_file" ]] || continue
			cmd_name=$(basename "$cmd_file" .md)

			# Deploy with name as-is (already carries `aidevops-` prefix).
			if ! _deploy_one_command "$runtime_id" "$cmd_file" "$cmd_name" "$cmd_dir"; then
				if [[ ! -e "$cmd_file" ]]; then
					print_warning "Skipping main-agent command $cmd_name: source disappeared"
					skipped_count=$((skipped_count + 1))
					continue
				fi
				print_warning "Failed to deploy main-agent command $cmd_name for $display_name"
				return 1
			fi
			command_count=$((command_count + 1))
		done
	fi

	# --- Source 2: .agents/scripts/commands/ (skills + workflows) ---
	# These files are NOT prefixed at the source -- prepend `aidevops-` at deploy.
	local skills_src_dir="$HOME/.aidevops/agents/scripts/commands"
	if [[ -d "$skills_src_dir" ]]; then
		local cmd_file cmd_name deployed_name
		for cmd_file in "$skills_src_dir"/*.md; do
			[[ -f "$cmd_file" ]] || continue
			cmd_name=$(basename "$cmd_file" .md)

			# Skip non-commands
			[[ "$cmd_name" == "SKILL" ]] && continue

			# Apply namespace prefix.
			deployed_name="${_AIDEVOPS_CMD_PREFIX}${cmd_name}"

			if ! _deploy_one_command "$runtime_id" "$cmd_file" "$deployed_name" "$cmd_dir"; then
				if [[ ! -f "$cmd_file" ]]; then
					print_warning "Skipping command $cmd_name: source disappeared"
					skipped_count=$((skipped_count + 1))
					continue
				fi
				print_warning "Failed to deploy command $cmd_name for $display_name"
				return 1
			fi
			command_count=$((command_count + 1))
		done
	fi

	# Generate hardcoded commands that aren't in scripts/commands/
	# These are runtime-specific commands that have inline body content
	_generate_hardcoded_commands "$runtime_id" "$cmd_dir" || return 1
	command_count=$((command_count + _GENERATED_HARDCODED_COMMAND_COUNT))

	# Only prune after replacements have been deployed successfully.
	_prune_legacy_commands "$runtime_id" "$cmd_dir" || return 1

	if [[ "$skipped_count" -gt 0 ]]; then
		print_warning "$display_name: skipped $skipped_count command file(s) that disappeared during generation"
	fi
	if [[ "$runtime_id" == "codex" ]]; then
		python3 "${SCRIPT_DIR}/codex-setup.py" skills || return 1
	fi
	print_success "$display_name: $command_count commands in $cmd_dir"
	return 0
}

# Write a canonical hardcoded command using the appropriate runtime format.
# These names are owned by the generator, so replace stale legacy output on
# every uncached generation rather than preserving obsolete routing metadata.
# Arguments:
#   $1 - runtime_id
#   $2 - cmd_dir
#   $3 - command name
#   $4 - description
#   $5 - body content
#   $6 - OpenCode subtask flag (optional, defaults to true)
# Returns: 0 when written
_maybe_write_hardcoded_command() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local name="$3"
	local description="$4"
	local body="$5"
	local subtask="${6:-true}"

	case "$runtime_id" in
	opencode)
		_write_opencode_command "$cmd_dir" "$name" "$description" "Build+" "$subtask" "$body"
		;;
	*)
		_write_claude_command "$cmd_dir" "$name" "$description" "$body"
		;;
	esac
	return 0
}

# Generate quality/review hardcoded commands.
# Arguments: $1 - runtime_id, $2 - cmd_dir
# Sets _GENERATED_HARDCODED_COMMAND_COUNT and returns 0 on success.
_generate_hardcoded_quality_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	# --- Agent Review ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "agent-review" \
		"Systematic review and improvement of agent instructions" \
		'Read ~/.aidevops/agents/tools/build-agent/agent-review.md and follow it as the canonical review rubric.

Review target: $ARGUMENTS

If no target is provided, review the instruction surfaces used in this session.'; then
		count=$((count + 1))
	fi

	# --- Issue / PR Review ---
	# Opening-message reviews must remain in the primary conversation so the
	# evidence trail and maintainer decisions stay visible in the parent session.
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "review-issue-pr" \
		"Review external issue or PR - validate problem and evaluate solution" \
		'Read ~/.aidevops/agents/workflows/review.md, select the maintainer policy, then follow ~/.aidevops/agents/workflows/review-issue-pr.md.

Review this issue or PR: $ARGUMENTS

This is the legacy alias for `/review issue ...` or `/review pr ...`.

**Usage:**
- `/review-issue-pr 123` - Review issue or PR by number
- `/review-issue-pr https://github.com/owner/repo/issues/123` - Review by URL
- `/review-issue-pr https://github.com/owner/repo/pull/456` - Review PR by URL

**Core questions to answer:**
1. Is the issue real? (reproducible, not duplicate, actually a bug)
2. Is this the best solution? (simplest approach, fixes root cause)
3. Is the scope appropriate? (minimal changes, no scope creep)

End every completed review with the exact ready-to-run approval command when the recommendation is Approve. Group same-kind targets as `sudo aidevops approve issue|pr N N... owner/repo`, or mixed targets as `sudo aidevops approve batch issue:N pr:N... owner/repo`; otherwise state why no approval command is appropriate.' \
		"false"; then
		count=$((count + 1))
	fi

	# --- Preflight ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "preflight" \
		"Run quality checks before version bump and release" \
		'Read ~/.aidevops/agents/workflows/preflight.md and follow its instructions.

Run preflight checks for: $ARGUMENTS

This includes:
1. Code quality checks (ShellCheck, SonarCloud, secrets scan)
2. Markdown formatting validation
3. Version consistency verification
4. Git status check (clean working tree)'; then
		count=$((count + 1))
	fi

	# --- Postflight ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "postflight" \
		"Check code audit feedback on latest push (branch or PR)" \
		'Check code audit tool feedback on the latest push.

Target: $ARGUMENTS

**Auto-detection:**
1. If in a linked worktree with open PR -> check that PR'\''s feedback
2. If in a linked worktree without PR -> check ref CI status
3. If on main -> check latest commit'\''s CI/audit status

**Checks performed:**
1. GitHub Actions workflow status (pass/fail/pending)
2. CodeRabbit comments and suggestions
3. Codacy analysis results
4. SonarCloud quality gate status

Report findings and recommend next actions (fix issues, merge, etc.)'; then
		count=$((count + 1))
	fi

	_GENERATED_HARDCODED_COMMAND_COUNT="$count"
	return 0
}

# Generate lifecycle hardcoded commands (release, onboarding, setup-aidevops).
# Arguments: $1 - runtime_id, $2 - cmd_dir
# Sets _GENERATED_HARDCODED_COMMAND_COUNT and returns 0 on success.
_generate_hardcoded_lifecycle_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	# --- Release ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "release" \
		"Full release workflow with version bump, tag, and GitHub release" \
		'Execute a release for the current repository.

Release type: $ARGUMENTS (valid: major, minor, patch)

**Steps:**
1. Run `git log v$(cat VERSION 2>/dev/null || echo "0.0.0")..HEAD --oneline` to see commits since last release
2. If no release type provided, determine it from commits
3. Run the single release command:
   ```bash
   .agents/scripts/version-manager.sh release [type] --skip-preflight --force
   ```
4. Report the result with the GitHub release URL'; then
		count=$((count + 1))
	fi

	# --- Onboarding ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "onboarding" \
		"Interactive onboarding wizard - discover services, configure integrations" \
		'Read ${AIDEVOPS_HOME:-$HOME/.aidevops}/agents/onboarding.md and follow its Welcome Flow instructions to guide the user through setup. Do NOT repeat these instructions — go straight to the Welcome Flow conversation.

Arguments: $ARGUMENTS'; then
		count=$((count + 1))
	fi

	# --- Setup ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "setup-aidevops" \
		"Deploy latest aidevops agent changes locally" \
		'Run the aidevops setup script to deploy the latest changes.

```bash
AIDEVOPS_REPO="${AIDEVOPS_REPO:-$(jq -r ".initialized_repos[]?.path | select(test(\"/aidevops$\"))" ~/.config/aidevops/repos.json 2>/dev/null | head -n 1)}"
if [[ -z "$AIDEVOPS_REPO" ]]; then
  AIDEVOPS_REPO="$HOME/Git/aidevops"
fi
[[ -f "$AIDEVOPS_REPO/setup.sh" ]] || {
  echo "Unable to find setup.sh. Set AIDEVOPS_REPO to your aidevops clone path." >&2
  exit 1
}
cd "$AIDEVOPS_REPO" && ./setup.sh || exit
```

This deploys agents, updates commands, regenerates configs.
Arguments: $ARGUMENTS'; then
		count=$((count + 1))
	fi

	_GENERATED_HARDCODED_COMMAND_COUNT="$count"
	return 0
}

# Generate hardcoded commands not in scripts/commands/
# Sets _GENERATED_HARDCODED_COMMAND_COUNT and returns 0 on success.
_generate_hardcoded_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	_generate_hardcoded_quality_commands "$runtime_id" "$cmd_dir" || return 1
	count=$((count + _GENERATED_HARDCODED_COMMAND_COUNT))

	_generate_hardcoded_lifecycle_commands "$runtime_id" "$cmd_dir" || return 1
	count=$((count + _GENERATED_HARDCODED_COMMAND_COUNT))

	_GENERATED_HARDCODED_COMMAND_COUNT="$count"
	return 0
}
