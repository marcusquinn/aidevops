#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

_init_update_project_operations_context() {
	local project_root="$1"
	local agents_md="$project_root/.agents/AGENTS.md"
	local start="<!-- aidevops:project-operations-context:start -->"
	local end="<!-- aidevops:project-operations-context:end -->"
	local block_file="${agents_md}.project-context-block.$$"
	local tmp_file="${agents_md}.project-context.$$"
	local line_format="%s\n"
	[[ -f "$agents_md" ]] || return 0

	{
		printf "$line_format" "$start" "## Project Operations Context" ""
		[[ -f "$project_root/.aidevops/deployments.yaml" ]] && printf "$line_format" "- Deployment manifest: \`.aidevops/deployments.yaml\`"
		[[ -f "$project_root/.aidevops/wordpress.yaml" ]] && printf "$line_format" "- WordPress manifest: \`.aidevops/wordpress.yaml\`"
		printf "$line_format" "$end"
	} >"$block_file"

	if grep -qF "$start" "$agents_md" 2>/dev/null; then
		awk -v start="$start" -v end="$end" -v block="$block_file" 'function emit(){while((getline line < block)>0) print line; close(block)} index($0,start)==1 {if(!inserted){emit(); inserted=1}; managed=1; next} managed && index($0,end)==1 {managed=0; next} !managed {print}' "$agents_md" >"$tmp_file"
	else
		cp "$agents_md" "$tmp_file"
		[[ ! -s "$tmp_file" ]] || printf "\n" >>"$tmp_file"
		cat "$block_file" >>"$tmp_file"
	fi
	rm -f "$block_file"
	if cmp -s "$agents_md" "$tmp_file"; then
		rm -f "$tmp_file"
	else
		mv "$tmp_file" "$agents_md"
	fi
	return 0
}

_init_scaffold_project_context() {
	local project_root="$1"
	local enable_deployment_context="$2"
	local enable_wordpress_context="$3"
	local template_dir="$AGENTS_DIR/templates/project-context"
	local context_dir="$project_root/.aidevops"
	local enabled_value="true"
	[[ "$enable_deployment_context" == "$enabled_value" || "$enable_wordpress_context" == "$enabled_value" ]] || return 0
	[[ -d "$template_dir" ]] || {
		print_warning "Project context templates not found: $template_dir"
		return 1
	}

	mkdir -p "$context_dir"
	if [[ ! -f "$context_dir/.gitignore" ]]; then
		cp "$template_dir/gitignore" "$context_dir/.gitignore"
		print_success "Created .aidevops/.gitignore"
	fi
	if [[ "$enable_deployment_context" == "$enabled_value" && ! -f "$context_dir/deployments.yaml" ]]; then
		cp "$template_dir/deployments.yaml" "$context_dir/deployments.yaml"
		print_success "Created .aidevops/deployments.yaml"
	fi
	if [[ "$enable_wordpress_context" == "$enabled_value" && ! -f "$context_dir/wordpress.yaml" ]]; then
		cp "$template_dir/wordpress.yaml" "$context_dir/wordpress.yaml"
		print_success "Created .aidevops/wordpress.yaml"
	fi
	_init_update_project_operations_context "$project_root"
	return 0
}
