#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# The marker is accepted only as the first line after YAML frontmatter. A
# coincidental reference to it in an operator prompt cannot confer ownership.
_opencode_generated_agent_owned() {
	local file="$1"
	[[ -f "$file" && ! -L "$file" ]] || return 1
	awk '
		NR == 1 { if ($0 != "---") exit 1; next }
		$0 == "---" {
			getline
			if ($0 == "<!-- aidevops:generated-subagent -->") owned = 1
			exit
		}
		END { if (!owned) exit 1 }
	' "$file"
	return $?
}

_opencode_agent_output_available() {
	local file="$1"
	if [[ -e "$file" || -L "$file" ]]; then
		# Generation must not overwrite an operator definition, even when its
		# basename collides with a canonical aidevops source.
		if ! _opencode_generated_agent_owned "$file"; then
			printf 'Preserving operator-owned OpenCode agent: %s\n' "${file##*/}" >&2
			return 1
		fi
	fi
	return 0
}

_opencode_clean_generated_agents() {
	local agent_dir="$1"
	local file
	while IFS= read -r -d '' file; do
		if _opencode_generated_agent_owned "$file"; then
			rm -f "$file" || return 1
		fi
	done < <(find "$agent_dir" -maxdepth 1 -name '*.md' -type f -print0)
	return 0
}
