#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2001
# =============================================================================
# Site Crawler Helper -- Markdown & Metadata Extraction
# =============================================================================
# Functions for extracting page metadata, downloading images, building
# frontmatter, and saving markdown files from Crawl4AI JSON results.
#
# Usage: source "${SCRIPT_DIR}/site-crawler-helper-markdown.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, print_warning, _file_size_bytes)
#   - jq, curl
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SITE_CRAWLER_MARKDOWN_LIB_LOADED:-}" ]] && return 0
_SITE_CRAWLER_MARKDOWN_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

# Extract page URL, status code, and redirect info from a crawl result
_smwm_extract_page_info() {
	local result="$1"
	local _out_url="$2"
	local _out_status="$3"
	local _out_orig_status="$4"
	local _out_redirected="$5"
	local _out_success="$6"

	local page_url status_code redirected_url success
	page_url=$(printf '%s' "$result" | jq -r '.url // empty')
	status_code=$(printf '%s' "$result" | jq -r '.status_code // 0')
	redirected_url=$(printf '%s' "$result" | jq -r '.redirected_url // empty')
	success=$(printf '%s' "$result" | jq -r '.success // false')

	local original_status="$status_code"
	if [[ "$success" == "true" && $status_code -ge 300 && $status_code -lt 400 ]]; then
		local url_normalized redirect_normalized
		url_normalized=$(echo "$page_url" | sed 's|/$||')
		redirect_normalized=$(echo "$redirected_url" | sed 's|/$||')
		if [[ "$url_normalized" == "$redirect_normalized" ]]; then
			status_code=200
		fi
	fi

	# Write results to named output variables via temp file approach
	printf '%s\n' "$page_url" >"${_out_url}"
	printf '%s\n' "$status_code" >"${_out_status}"
	printf '%s\n' "$original_status" >"${_out_orig_status}"
	printf '%s\n' "$redirected_url" >"${_out_redirected}"
	printf '%s\n' "$success" >"${_out_success}"
	return 0
}

# Extract SEO metadata fields from a crawl result JSON
_smwm_extract_metadata() {
	local result="$1"
	local _out_title="$2"
	local _out_meta_desc="$3"
	local _out_meta_keywords="$4"
	local _out_canonical="$5"
	local _out_og_title="$6"
	local _out_og_desc="$7"
	local _out_og_image="$8"
	local _out_hreflang="$9"
	local _out_schema="${10}"

	local title meta_desc meta_keywords canonical og_title og_desc og_image
	title=$(printf '%s' "$result" | jq -r '.metadata.title // empty')
	meta_desc=$(printf '%s' "$result" | jq -r '.metadata.description // empty')
	meta_keywords=$(printf '%s' "$result" | jq -r '.metadata.keywords // empty')
	canonical=$(printf '%s' "$result" | jq -r '.metadata."og:url" // empty')
	og_title=$(printf '%s' "$result" | jq -r '.metadata."og:title" // empty')
	og_desc=$(printf '%s' "$result" | jq -r '.metadata."og:description" // empty')
	og_image=$(printf '%s' "$result" | jq -r '.metadata."og:image" // empty')

	local hreflang_json
	hreflang_json=$(printf '%s' "$result" | jq -c '[.metadata | to_entries[] | select(.key | startswith("hreflang")) | {lang: .key, url: .value}]' 2>/dev/null || echo "[]")

	local schema_json=""
	local html_content
	html_content=$(printf '%s' "$result" | jq -r '.html // empty' 2>/dev/null)
	if [[ -n "$html_content" ]]; then
		schema_json=$(echo "$html_content" | grep -o '<script type="application/ld+json"[^>]*>[^<]*</script>' |
			sed 's/<script type="application\/ld+json"[^>]*>//g' |
			sed 's/<\/script>//g' |
			while read -r schema_block; do
				echo "$schema_block" | jq '.' 2>/dev/null
			done)
	fi

	printf '%s\n' "$title" >"${_out_title}"
	printf '%s\n' "$meta_desc" >"${_out_meta_desc}"
	printf '%s\n' "$meta_keywords" >"${_out_meta_keywords}"
	printf '%s\n' "$canonical" >"${_out_canonical}"
	printf '%s\n' "$og_title" >"${_out_og_title}"
	printf '%s\n' "$og_desc" >"${_out_og_desc}"
	printf '%s\n' "$og_image" >"${_out_og_image}"
	printf '%s\n' "$hreflang_json" >"${_out_hreflang}"
	printf '%s\n' "$schema_json" >"${_out_schema}"
	return 0
}

# Download images for a page; writes downloaded image info (pipe-delimited) to _out_images file
_smwm_download_images() {
	local images_json="$1"
	local page_images_dir="$2"
	local _out_images="$3"

	local image_count
	image_count=$(echo "$images_json" | jq 'length' 2>/dev/null || echo "0")

	: >"${_out_images}"

	[[ $image_count -eq 0 ]] && return 0

	mkdir -p "$page_images_dir"

	local seen_images
	seen_images=()
	for ((j = 0; j < image_count && j < 20; j++)); do
		local img_src img_alt img_filename
		img_src=$(echo "$images_json" | jq -r ".[$j].src // empty")
		img_alt=$(echo "$images_json" | jq -r ".[$j].alt // empty")

		[[ -z "$img_src" ]] && continue
		[[ "$img_src" =~ ^data: ]] && continue

		img_filename=$(basename "$img_src" | sed 's|?.*||' | sed 's|#.*||')

		local base_img
		base_img=$(echo "$img_filename" | sed -E 's/-[0-9]+x[0-9]+\./\./')

		local already_seen=false
		if [[ ${#seen_images[@]} -gt 0 ]]; then
			for seen in "${seen_images[@]}"; do
				if [[ "$seen" == "$base_img" ]]; then
					already_seen=true
					break
				fi
			done
		fi
		[[ "$already_seen" == "true" ]] && continue
		seen_images+=("$base_img")

		if curl -sS -L --max-time 10 -o "${page_images_dir}/${img_filename}" "$img_src" 2>/dev/null; then
			local file_size
			file_size=$(_file_size_bytes "${page_images_dir}/${img_filename}")
			if [[ $file_size -gt 1024 ]]; then
				printf '%s\n' "${img_filename}|${img_src}|${img_alt}" >>"${_out_images}"
			else
				rm -f "${page_images_dir}/${img_filename}"
			fi
		fi
	done

	rmdir "${page_images_dir}" 2>/dev/null || true
	return 0
}

# Build YAML frontmatter string for a markdown page
_smwm_build_frontmatter() {
	local page_url="$1"
	local status_code="$2"
	local original_status="$3"
	local redirected_url="$4"
	local title="$5"
	local meta_desc="$6"
	local meta_keywords="$7"
	local canonical="$8"
	local og_title="$9"
	local og_image="${10}"
	local hreflang_json="${11}"
	local images_file="${12}"

	local frontmatter="---
url: \"${page_url}\"
status_code: ${status_code}"

	if [[ $original_status -ge 300 && $original_status -lt 400 && "$status_code" != "$original_status" ]]; then
		frontmatter+="
redirect_status: ${original_status}
redirected_to: \"${redirected_url}\""
	elif [[ -n "$redirected_url" && "$redirected_url" != "$page_url" && "$redirected_url" != "null" ]]; then
		frontmatter+="
redirected_to: \"${redirected_url}\""
	fi

	if [[ -n "$title" && "$title" != "null" ]]; then
		frontmatter+="
title: \"$(echo "$title" | sed 's/"/\\"/g')\""
	fi

	if [[ -n "$meta_desc" && "$meta_desc" != "null" ]]; then
		frontmatter+="
description: \"$(echo "$meta_desc" | sed 's/"/\\"/g')\""
	fi

	if [[ -n "$meta_keywords" && "$meta_keywords" != "null" ]]; then
		frontmatter+="
keywords: \"$(echo "$meta_keywords" | sed 's/"/\\"/g')\""
	fi

	if [[ -n "$canonical" && "$canonical" != "null" ]]; then
		frontmatter+="
canonical: \"${canonical}\""
	fi

	if [[ -n "$og_title" && "$og_title" != "null" && "$og_title" != "$title" ]]; then
		frontmatter+="
og_title: \"$(echo "$og_title" | sed 's/"/\\"/g')\""
	fi

	if [[ -n "$og_image" && "$og_image" != "null" ]]; then
		frontmatter+="
og_image: \"${og_image}\""
	fi

	if [[ "$hreflang_json" != "[]" && "$hreflang_json" != "null" ]]; then
		local hreflang_yaml
		hreflang_yaml=$(echo "$hreflang_json" | jq -r '.[] | "  - lang: \"\(.lang)\"\n    url: \"\(.url)\""' 2>/dev/null)
		if [[ -n "$hreflang_yaml" ]]; then
			frontmatter+="
hreflang:
${hreflang_yaml}"
		fi
	fi

	if [[ -s "$images_file" ]]; then
		frontmatter+="
images:"
		while IFS= read -r img_info; do
			[[ -z "$img_info" ]] && continue
			local img_file img_url img_alt_text
			img_file=$(echo "$img_info" | cut -d'|' -f1)
			img_url=$(echo "$img_info" | cut -d'|' -f2)
			img_alt_text=$(echo "$img_info" | cut -d'|' -f3 | sed 's/"/\\"/g')
			frontmatter+="
  - file: \"${img_file}\"
    original_url: \"${img_url}\""
			if [[ -n "$img_alt_text" ]]; then
				frontmatter+="
    alt: \"${img_alt_text}\""
			fi
		done <"$images_file"
	fi

	frontmatter+="
crawled_at: \"$(date -Iseconds)\"
---"

	printf '%s\n' "$frontmatter"
	return 0
}

# Save markdown with rich metadata frontmatter and download images
save_markdown_with_metadata() {
	local result="$1"
	local full_page_dir="$2"
	local body_only_dir="$3"
	local images_dir="$4"
	local _base_domain="$5" # Reserved for future domain-relative path generation

	# Use temp files to pass multi-line values between sub-functions
	local tmp_dir
	tmp_dir=$(mktemp -d)
	local _f_url="${tmp_dir}/url" _f_status="${tmp_dir}/status"
	local _f_orig="${tmp_dir}/orig_status" _f_redir="${tmp_dir}/redirected"
	local _f_success="${tmp_dir}/success"
	local _f_title="${tmp_dir}/title" _f_desc="${tmp_dir}/desc"
	local _f_kw="${tmp_dir}/keywords" _f_canon="${tmp_dir}/canonical"
	local _f_ogtitle="${tmp_dir}/og_title" _f_ogdesc="${tmp_dir}/og_desc"
	local _f_ogimg="${tmp_dir}/og_image" _f_hreflang="${tmp_dir}/hreflang"
	local _f_schema="${tmp_dir}/schema" _f_images="${tmp_dir}/images"

	# Extract page info
	_smwm_extract_page_info "$result" \
		"$_f_url" "$_f_status" "$_f_orig" "$_f_redir" "$_f_success"

	local page_url status_code original_status redirected_url
	page_url=$(cat "$_f_url")
	status_code=$(cat "$_f_status")
	original_status=$(cat "$_f_orig")
	redirected_url=$(cat "$_f_redir")

	# Extract metadata
	_smwm_extract_metadata "$result" \
		"$_f_title" "$_f_desc" "$_f_kw" "$_f_canon" \
		"$_f_ogtitle" "$_f_ogdesc" "$_f_ogimg" "$_f_hreflang" "$_f_schema"

	local title meta_desc meta_keywords canonical og_title og_image hreflang_json schema_json
	title=$(cat "$_f_title")
	meta_desc=$(cat "$_f_desc")
	meta_keywords=$(cat "$_f_kw")
	canonical=$(cat "$_f_canon")
	og_title=$(cat "$_f_ogtitle")
	og_image=$(cat "$_f_ogimg")
	hreflang_json=$(cat "$_f_hreflang")
	schema_json=$(cat "$_f_schema")

	# Get markdown content
	local markdown_content
	markdown_content=$(printf '%s' "$result" | jq -r '.markdown.raw_markdown // .markdown // empty' 2>/dev/null)

	[[ -z "$markdown_content" || "$markdown_content" == "null" || "$markdown_content" == "{" ]] && {
		rm -rf "$tmp_dir"
		return 0
	}

	# Generate slug for filename
	local slug
	slug=$(echo "$page_url" | sed -E 's|^https?://[^/]+||' | sed 's|^/||' | sed 's|/$||' | tr '/' '-' | tr '?' '-' | tr '&' '-')
	[[ -z "$slug" ]] && slug="index"
	slug="${slug:0:100}"

	# Download images
	local images_json page_images_dir
	images_json=$(printf '%s' "$result" | jq -c '.media.images // []' 2>/dev/null)
	page_images_dir="${images_dir}/${slug}"
	_smwm_download_images "$images_json" "$page_images_dir" "$_f_images"

	# Build frontmatter
	local frontmatter
	frontmatter=$(_smwm_build_frontmatter \
		"$page_url" "$status_code" "$original_status" "$redirected_url" \
		"$title" "$meta_desc" "$meta_keywords" "$canonical" \
		"$og_title" "$og_image" "$hreflang_json" "$_f_images")

	# Update markdown image references to point to local files
	local updated_markdown="$markdown_content"
	if [[ -s "$_f_images" ]]; then
		while IFS= read -r img_info; do
			[[ -z "$img_info" ]] && continue
			local img_file img_url
			img_file=$(echo "$img_info" | cut -d'|' -f1)
			img_url=$(echo "$img_info" | cut -d'|' -f2)
			updated_markdown=$(echo "$updated_markdown" | sed "s|${img_url}|../images/${slug}/${img_file}|g")
		done <"$_f_images"
	fi

	# Extract body-only content
	local body_markdown
	body_markdown=$(extract_body_content "$updated_markdown")

	_smwm_write_files \
		"$frontmatter" "$updated_markdown" "$body_markdown" "$schema_json" \
		"$full_page_dir" "$body_only_dir" "$slug"

	rm -rf "$tmp_dir"
	return 0
}

# Write full-page and body-only markdown files for a crawled page
_smwm_write_files() {
	local frontmatter="$1"
	local updated_markdown="$2"
	local body_markdown="$3"
	local schema_json="$4"
	local full_page_dir="$5"
	local body_only_dir="$6"
	local slug="$7"

	# Write full page markdown
	{
		echo "$frontmatter"
		echo ""
		echo "$updated_markdown"
		if [[ -n "$schema_json" ]]; then
			echo ""
			echo "---"
			echo ""
			echo "## Structured Data (JSON-LD)"
			echo ""
			echo '```json'
			echo "$schema_json"
			echo '```'
		fi
	} >"${full_page_dir}/${slug}.md"

	# Write body-only markdown
	{
		echo "$frontmatter"
		echo ""
		echo "$body_markdown"
	} >"${body_only_dir}/${slug}.md"
	return 0
}

# Extract body content from markdown (remove nav, header, footer, cookie notices)
# Site-agnostic approach - optimized for performance
extract_body_content() {
	local markdown="$1"

	# Use awk for efficient single-pass extraction
	# This is much faster than bash loops with regex
	echo "$markdown" | awk '
    BEGIN {
        in_body = 0
        footer_started = 0
    }
    
    # Start at first H1 or H2 heading
    /^#+ / && !in_body {
        in_body = 1
    }
    
    # Skip until we find a heading
    !in_body { next }
    
    # Detect footer markers
    /^##* *[Ff]ooter/ { footer_started = 1 }
    /©|Copyright|\(c\) *20[0-9][0-9]/ { footer_started = 1 }
    /All rights reserved|Alle Rechte vorbehalten|Tous droits/ { footer_started = 1 }
    /^##* *(References|Références|Referenzen)$/ { footer_started = 1 }
    
    # Cookie/GDPR patterns
    /[Cc]ookie.*(consent|settings|preferences|policy)/ { footer_started = 1 }
    /GDPR|CCPA|LGPD/ { footer_started = 1 }
    /[Pp]rivacy [Oo]verview/ { footer_started = 1 }
    /[Ss]trictly [Nn]ecessary [Cc]ookie/ { footer_started = 1 }
    
    # Powered by patterns
    /[Pp]owered by|[Bb]uilt with|[Mm]ade with/ { footer_started = 1 }
    
    # Skip footer content
    footer_started { next }
    
    # Print body content
    { print }
    '
}
