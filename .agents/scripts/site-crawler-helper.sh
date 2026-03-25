#!/usr/bin/env bash
# shellcheck disable=SC2001,SC2034

# Site Crawler Helper Script
# SEO site auditing with Screaming Frog-like capabilities
# Uses Crawl4AI when available, falls back to lightweight Python crawler
#
# Usage: ./site-crawler-helper.sh [command] [url] [options]
# Commands:
#   crawl           - Full site crawl with SEO data extraction
#   audit-links     - Check for broken links (4XX/5XX)
#   audit-meta      - Audit page titles and meta descriptions
#   audit-redirects - Analyze redirects and chains
#   generate-sitemap - Generate XML sitemap from crawl
#   compare         - Compare two crawls
#   status          - Check crawler dependencies
#   help            - Show this help message
#
# Author: AI DevOps Framework
# Version: 2.0.0
# License: MIT

set -euo pipefail

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly CONFIG_DIR="${HOME}/.config/aidevops"
readonly CONFIG_FILE="${CONFIG_DIR}/site-crawler.json"
readonly DEFAULT_OUTPUT_DIR="${HOME}/Downloads"
readonly CRAWL4AI_PORT="11235"
readonly CRAWL4AI_URL="http://localhost:${CRAWL4AI_PORT}"

# Default configuration
DEFAULT_DEPTH=3
DEFAULT_MAX_URLS=100
DEFAULT_DELAY=100
DEFAULT_FORMAT="xlsx"
RESPECT_ROBOTS=true
USE_CRAWL4AI=false

# Detect Python with required packages
PYTHON_CMD=""

# Print functions
print_header() {
	echo -e "${PURPLE}=== $1 ===${NC}"
	return 0
}

# Check if Crawl4AI is available
check_crawl4ai() {
	if curl -s --connect-timeout 2 "${CRAWL4AI_URL}/health" &>/dev/null; then
		USE_CRAWL4AI=true
		return 0
	fi
	return 1
}

# Find working Python with dependencies
find_python() {
	local pythons=("python3.11" "python3.12" "python3.10" "python3")
	local user_site="${HOME}/Library/Python/3.11/lib/python/site-packages"

	for py in "${pythons[@]}"; do
		# Check if python exists and has the required modules
		if command -v "$py" &>/dev/null &&
			PYTHONPATH="${user_site}:${PYTHONPATH:-}" "$py" -c "import aiohttp, bs4" 2>/dev/null; then
			PYTHON_CMD="$py"
			export PYTHONPATH="${user_site}:${PYTHONPATH:-}"
			return 0
		fi
	done
	return 1
}

# Install Python dependencies
install_python_deps() {
	local pythons=("python3.11" "python3.12" "python3.10" "python3")

	for py in "${pythons[@]}"; do
		if command -v "$py" &>/dev/null; then
			print_info "Installing dependencies with $py..."
			"$py" -m pip install --user aiohttp beautifulsoup4 openpyxl 2>/dev/null && {
				PYTHON_CMD="$py"
				export PYTHONPATH="${HOME}/Library/Python/3.11/lib/python/site-packages:${PYTHONPATH:-}"
				return 0
			}
		fi
	done
	return 1
}

# Extract domain from URL
get_domain() {
	local url="$1"
	echo "$url" | sed -E 's|^https?://||' | sed -E 's|/.*||' | sed -E 's|:.*||'
}

# Create output directory structure
create_output_dir() {
	local domain="$1"
	local output_base="${2:-$DEFAULT_OUTPUT_DIR}"
	local timestamp
	timestamp=$(date +%Y-%m-%d_%H%M%S)

	local output_dir="${output_base}/${domain}/${timestamp}"
	mkdir -p "$output_dir"

	# Update _latest symlink
	local latest_link="${output_base}/${domain}/_latest"
	rm -f "$latest_link"
	ln -sf "$timestamp" "$latest_link"

	echo "$output_dir"
	return 0
}

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
			file_size=$(stat -f%z "${page_images_dir}/${img_filename}" 2>/dev/null || echo "0")
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

# Process one batch of URLs via Crawl4AI API; appends results to results_file
# Returns number of pages crawled in this batch via stdout
_crawl4ai_process_batch() {
	local batch_urls_str="$1" # newline-separated list of URLs
	local output_dir="$2"
	local full_page_dir="$3"
	local body_only_dir="$4"
	local images_dir="$5"
	local base_domain="$6"
	local results_file="$7"
	local depth="$8"
	local current_depth="$9"
	local queue_file="${10}"
	local visited_file="${11}"

	local batch_urls=()
	while IFS= read -r u; do
		[[ -n "$u" ]] && batch_urls+=("$u")
	done <<<"$batch_urls_str"

	[[ ${#batch_urls[@]} -eq 0 ]] && {
		echo "0"
		return 0
	}

	# Build JSON array of URLs
	local urls_json="["
	local first=true
	for batch_url in "${batch_urls[@]}"; do
		[[ "$first" != "true" ]] && urls_json+=","
		urls_json+="\"$batch_url\""
		first=false
	done
	urls_json+="]"

	# Submit crawl job to Crawl4AI
	local response
	response=$(curl -s -X POST "${CRAWL4AI_URL}/crawl" \
		--max-time 120 \
		-H "Content-Type: application/json" \
		-d "{
            \"urls\": $urls_json,
            \"crawler_config\": {
                \"type\": \"CrawlerRunConfig\",
                \"params\": {
                    \"cache_mode\": \"bypass\",
                    \"word_count_threshold\": 10,
                    \"page_timeout\": 30000
                }
            }
        }" 2>/dev/null)

	if [[ -z "$response" ]]; then
		print_warning "No response from Crawl4AI for batch, skipping..."
		echo "0"
		return 0
	fi

	local batch_crawled=0
	if command -v jq &>/dev/null; then
		local result_count
		result_count=$(echo "$response" | jq -r '.results | length' 2>/dev/null || echo "0")

		for ((i = 0; i < result_count; i++)); do
			local result
			result=$(echo "$response" | jq -c ".results[$i]" 2>/dev/null)
			[[ -z "$result" || "$result" == "null" ]] && continue

			echo "$result" >>"$results_file"
			((++batch_crawled))

			local page_url status_code
			page_url=$(printf '%s' "$result" | jq -r '.url // empty')
			status_code=$(printf '%s' "$result" | jq -r '.status_code // 0')

			print_info "  [${batch_crawled}] ${status_code} ${page_url:0:60}"

			save_markdown_with_metadata "$result" "$full_page_dir" "$body_only_dir" "$images_dir" "$base_domain" || true

			_crawl4ai_enqueue_links "$result" "$base_domain" "$depth" "$current_depth" "$queue_file" "$visited_file"
		done
	fi

	echo "$batch_crawled"
	return 0
}

# Extract internal links from a result and add unseen ones to the queue
_crawl4ai_enqueue_links() {
	local result="$1"
	local base_domain="$2"
	local depth="$3"
	local current_depth="$4"
	local queue_file="$5"
	local visited_file="$6"

	[[ $current_depth -ge $depth ]] && return 0

	local links
	links=$(printf '%s' "$result" | jq -r '.links.internal[]?.href // empty' 2>/dev/null | head -50)

	while IFS= read -r link; do
		[[ -z "$link" ]] && continue
		if [[ "$link" =~ ^/ ]]; then
			link="https://${base_domain}${link}"
		elif [[ ! "$link" =~ ^https?:// ]]; then
			continue
		fi
		if [[ "$link" =~ $base_domain ]]; then
			link=$(echo "$link" | sed 's|#.*||' | sed 's|/$||')
			if ! grep -qxF "$link" "$visited_file" 2>/dev/null; then
				echo "$link" >>"$queue_file"
			fi
		fi
	done <<<"$links"
	return 0
}

# Initialise Crawl4AI output directories and tracking files.
# Arguments: $1=url $2=output_dir
# Sets caller-local: full_page_dir, body_only_dir, images_dir,
#                    base_domain, visited_file, queue_file, results_file
_crawl4ai_init_dirs() {
	local url="$1"
	local output_dir="$2"

	full_page_dir="${output_dir}/content-full-page-md"
	body_only_dir="${output_dir}/content-body-md"
	images_dir="${output_dir}/images"
	mkdir -p "$full_page_dir" "$body_only_dir" "$images_dir"

	base_domain=$(echo "$url" | sed -E 's|^https?://||' | sed -E 's|/.*||')

	visited_file="${output_dir}/.visited_urls"
	queue_file="${output_dir}/.queue_urls"
	results_file="${output_dir}/.results.jsonl"

	echo "$url" >"$queue_file"
	touch "$visited_file"
	touch "$results_file"
	return 0
}

# Dequeue the next batch of unvisited URLs from queue_file into visited_file.
# Arguments: $1=max_urls $2=crawled_count $3=batch_size_limit
# Outputs: batch_urls_str (newline-separated) and batch_count via temp files
# Returns: 0 if batch is non-empty, 1 if nothing left to process
_crawl4ai_dequeue_batch() {
	local max_urls="$1"
	local crawled_count="$2"
	local batch_size_limit="${3:-5}"

	local remaining=$((max_urls - crawled_count))
	[[ $remaining -lt $batch_size_limit ]] && batch_size_limit=$remaining

	local batch_urls_str=""
	local batch_count=0

	while IFS= read -r queue_url && [[ $batch_count -lt $batch_size_limit ]]; do
		if grep -qxF "$queue_url" "$visited_file" 2>/dev/null; then
			continue
		fi
		batch_urls_str+="${queue_url}"$'\n'
		echo "$queue_url" >>"$visited_file"
		((++batch_count))
	done <"$queue_file"

	if [[ $batch_count -gt 0 ]]; then
		local new_queue
		new_queue=$(mktemp)
		while IFS= read -r queue_url; do
			if ! grep -qxF "$queue_url" "$visited_file" 2>/dev/null; then
				echo "$queue_url"
			fi
		done <"$queue_file" >"$new_queue"
		mv "$new_queue" "$queue_file"
	fi

	# Pass results back via global (bash 3.2 compatible — no namerefs)
	_CRAWL4AI_BATCH_URLS="$batch_urls_str"
	_CRAWL4AI_BATCH_COUNT="$batch_count"
	[[ $batch_count -gt 0 ]]
	return $?
}

# Print Crawl4AI result counts after crawl completes.
# Arguments: $1=output_dir $2=crawled_count
_crawl4ai_print_results() {
	local output_dir="$1"
	local crawled_count="$2"
	local full_page_dir="${output_dir}/content-full-page-md"
	local body_only_dir="${output_dir}/content-body-md"
	local images_dir="${output_dir}/images"

	local full_page_count body_count img_count
	full_page_count=$(find "$full_page_dir" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
	body_count=$(find "$body_only_dir" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
	img_count=$(find "$images_dir" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.gif" -o -name "*.webp" -o -name "*.svg" \) 2>/dev/null | wc -l | tr -d ' ')

	print_success "Crawl4AI results saved to ${output_dir}"
	print_info "  Pages crawled: $crawled_count"
	print_info "  Full page markdown: $full_page_count (in content-full-page-md/)"
	print_info "  Body-only markdown: $body_count (in content-body-md/)"
	print_info "  Images downloaded: $img_count (in images/)"
	return 0
}

# Crawl using Crawl4AI API with multi-page discovery
crawl_with_crawl4ai() {
	local url="$1"
	local output_dir="$2"
	local max_urls="$3"
	local depth="$4"

	print_info "Using Crawl4AI backend..."

	local full_page_dir body_only_dir images_dir base_domain
	local visited_file queue_file results_file
	_crawl4ai_init_dirs "$url" "$output_dir"

	local crawled_count=0
	local current_depth=0

	print_info "Starting multi-page crawl (max: $max_urls, depth: $depth)"

	while [[ $crawled_count -lt $max_urls ]] && [[ -s "$queue_file" ]]; do
		_CRAWL4AI_BATCH_URLS=""
		_CRAWL4AI_BATCH_COUNT=0
		_crawl4ai_dequeue_batch "$max_urls" "$crawled_count" 5 || break

		local batch_urls_str="$_CRAWL4AI_BATCH_URLS"
		local batch_count="$_CRAWL4AI_BATCH_COUNT"

		print_info "[${crawled_count}/${max_urls}] Crawling batch of ${batch_count} URLs..."

		local batch_result
		batch_result=$(_crawl4ai_process_batch \
			"$batch_urls_str" "$output_dir" \
			"$full_page_dir" "$body_only_dir" "$images_dir" \
			"$base_domain" "$results_file" \
			"$depth" "$current_depth" \
			"$queue_file" "$visited_file")

		crawled_count=$((crawled_count + batch_result))
		((++current_depth))
	done

	print_info "Crawl complete. Processing results..."
	crawl4ai_generate_reports "$output_dir" "$results_file" "$base_domain"
	rm -f "$visited_file" "$queue_file"
	_crawl4ai_print_results "$output_dir" "$crawled_count"
	return 0
}

# Process a single result line from the JSONL results file
# Appends CSV row, broken link entry, and meta issue entry to respective output files
_c4ai_process_result_row() {
	local result="$1"
	local csv_file="$2"
	local broken_file_tmp="$3"
	local meta_file_tmp="$4"
	local status_codes_file="$5"

	local url status_code title meta_desc h1 canonical word_count
	url=$(printf '%s' "$result" | jq -r '.url // ""')
	status_code=$(printf '%s' "$result" | jq -r '.status_code // 0')
	title=$(printf '%s' "$result" | jq -r '.metadata.title // .title // ""' | tr ',' ';' | head -c 200)
	meta_desc=$(printf '%s' "$result" | jq -r '.metadata.description // ""' | tr ',' ';' | head -c 300)
	h1=$(printf '%s' "$result" | jq -r '.metadata.h1 // ""' | tr ',' ';' | head -c 200)
	canonical=$(printf '%s' "$result" | jq -r '.metadata.canonical // ""')
	word_count=$(printf '%s' "$result" | jq -r '.word_count // 0')

	local title_len=${#title}
	local desc_len=${#meta_desc}
	local status="OK"
	[[ $status_code -ge 300 && $status_code -lt 400 ]] && status="Redirect"
	[[ $status_code -ge 400 ]] && status="Error"

	local internal_links external_links
	internal_links=$(printf '%s' "$result" | jq -r '.links.internal | length // 0' 2>/dev/null || echo "0")
	external_links=$(printf '%s' "$result" | jq -r '.links.external | length // 0' 2>/dev/null || echo "0")

	echo "\"$url\",$status_code,\"$status\",\"$title\",$title_len,\"$meta_desc\",$desc_len,\"$h1\",1,\"$canonical\",\"\",$word_count,0,0,$internal_links,$external_links,0,0" >>"$csv_file"

	echo "$status_code" >>"$status_codes_file"

	if [[ $status_code -ge 400 ]]; then
		printf '%s\n' "{\"url\":\"$url\",\"status_code\":$status_code,\"source\":\"direct\"}" >>"$broken_file_tmp"
	fi

	local issues=""
	[[ -z "$title" ]] && issues+="Missing title; "
	[[ $title_len -gt 60 ]] && issues+="Title too long; "
	[[ -z "$meta_desc" ]] && issues+="Missing description; "
	[[ $desc_len -gt 160 ]] && issues+="Description too long; "
	[[ -z "$h1" ]] && issues+="Missing H1; "

	if [[ -n "$issues" ]]; then
		printf '%s\n' "{\"url\":\"$url\",\"title\":\"${title:0:50}\",\"h1\":\"${h1:0:50}\",\"issues\":\"${issues%%; }\"}" >>"$meta_file_tmp"
	fi
	return 0
}

# Write broken-links.csv and meta-issues.csv from temp JSONL files
_c4ai_write_csv_reports() {
	local output_dir="$1"
	local broken_file_tmp="$2"
	local meta_file_tmp="$3"

	if [[ -s "$broken_file_tmp" ]]; then
		local broken_file="${output_dir}/broken-links.csv"
		echo "url,status_code,source" >"$broken_file"
		while IFS= read -r bl; do
			local bl_url bl_code bl_src
			bl_url=$(echo "$bl" | jq -r '.url')
			bl_code=$(echo "$bl" | jq -r '.status_code')
			bl_src=$(echo "$bl" | jq -r '.source')
			echo "\"$bl_url\",$bl_code,\"$bl_src\"" >>"$broken_file"
		done <"$broken_file_tmp"
		print_info "Generated: $broken_file"
	fi

	if [[ -s "$meta_file_tmp" ]]; then
		local issues_file="${output_dir}/meta-issues.csv"
		echo "url,title,h1,issues" >"$issues_file"
		while IFS= read -r mi; do
			local mi_url mi_title mi_h1 mi_issues
			mi_url=$(echo "$mi" | jq -r '.url')
			mi_title=$(echo "$mi" | jq -r '.title')
			mi_h1=$(echo "$mi" | jq -r '.h1')
			mi_issues=$(echo "$mi" | jq -r '.issues')
			echo "\"$mi_url\",\"$mi_title\",\"$mi_h1\",\"$mi_issues\"" >>"$issues_file"
		done <"$meta_file_tmp"
		print_info "Generated: $issues_file"
	fi
	return 0
}

# Write summary.json from status codes file and counts
_c4ai_write_summary_json() {
	local output_dir="$1"
	local base_domain="$2"
	local status_codes_file="$3"
	local broken_count="$4"
	local meta_count="$5"

	local total_pages=0
	local code_200=0 code_301=0 code_302=0 code_404=0 code_500=0 code_other=0

	while IFS= read -r code; do
		[[ -z "$code" ]] && continue
		((++total_pages))
		case "$code" in
		200) ((++code_200)) ;;
		301) ((++code_301)) ;;
		302) ((++code_302)) ;;
		404) ((++code_404)) ;;
		500) ((++code_500)) ;;
		*) ((++code_other)) ;;
		esac
	done <"$status_codes_file"

	local summary_file="${output_dir}/summary.json"
	cat >"$summary_file" <<EOF
{
  "crawl_date": "$(date -Iseconds)",
  "base_url": "https://${base_domain}",
  "backend": "crawl4ai",
  "pages_crawled": $total_pages,
  "broken_links": ${broken_count},
  "redirects": 0,
  "meta_issues": ${meta_count},
  "status_codes": {
    "200": $code_200,
    "301": $code_301,
    "302": $code_302,
    "404": $code_404,
    "500": $code_500,
    "other": $code_other
  }
}
EOF
	print_info "Generated: $summary_file"
	return 0
}

# Generate XLSX from CSV using Python/openpyxl
_c4ai_generate_xlsx() {
	local csv_file="$1"

	find_python || return 0
	"$PYTHON_CMD" -c "import openpyxl" 2>/dev/null || return 0

	local xlsx_script
	xlsx_script=$(mktemp /tmp/xlsx_gen_XXXXXX.py)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${xlsx_script}'"
	cat >"$xlsx_script" <<'PYXLSX'
import sys
import csv
import openpyxl
from openpyxl.styles import Font, PatternFill
from pathlib import Path

csv_file = Path(sys.argv[1])
xlsx_file = csv_file.with_suffix('.xlsx')

wb = openpyxl.Workbook()
ws = wb.active
ws.title = "Crawl Data"

with open(csv_file, 'r', encoding='utf-8') as f:
    reader = csv.reader(f)
    for row_num, row in enumerate(reader, 1):
        for col_num, value in enumerate(row, 1):
            cell = ws.cell(row=row_num, column=col_num, value=value)
            if row_num == 1:
                cell.font = Font(bold=True)
                cell.fill = PatternFill(start_color="DAEEF3", end_color="DAEEF3", fill_type="solid")

wb.save(xlsx_file)
print(f"Generated: {xlsx_file}")
PYXLSX
	"$PYTHON_CMD" "$xlsx_script" "$csv_file" 2>/dev/null || true
	rm -f "$xlsx_script"
	return 0
}

# Generate reports from Crawl4AI results
crawl4ai_generate_reports() {
	local output_dir="$1"
	local results_file="$2"
	local base_domain="$3"

	[[ ! -s "$results_file" ]] && return 0

	# Generate CSV header
	local csv_file="${output_dir}/crawl-data.csv"
	echo "url,status_code,status,title,title_length,meta_description,description_length,h1,h1_count,canonical,meta_robots,word_count,response_time_ms,crawl_depth,internal_links,external_links,images,images_missing_alt" >"$csv_file"

	# Temp files for accumulating rows
	local broken_file_tmp meta_file_tmp status_codes_file
	broken_file_tmp=$(mktemp)
	meta_file_tmp=$(mktemp)
	status_codes_file=$(mktemp)

	while IFS= read -r result; do
		[[ -z "$result" ]] && continue
		_c4ai_process_result_row "$result" "$csv_file" "$broken_file_tmp" "$meta_file_tmp" "$status_codes_file"
	done <"$results_file"

	print_info "Generated: $csv_file"

	local broken_count meta_count
	broken_count=$(wc -l <"$broken_file_tmp" | tr -d ' ')
	meta_count=$(wc -l <"$meta_file_tmp" | tr -d ' ')

	_c4ai_write_csv_reports "$output_dir" "$broken_file_tmp" "$meta_file_tmp"
	_c4ai_write_summary_json "$output_dir" "$base_domain" "$status_codes_file" "$broken_count" "$meta_count"
	_c4ai_generate_xlsx "$csv_file"

	rm -f "$broken_file_tmp" "$meta_file_tmp" "$status_codes_file"
	return 0
}

# Emit Python crawler imports and dataclass definition
_fallback_crawler_header() {
	cat <<'PYHEADER'
#!/usr/bin/env python3
"""
Lightweight SEO Site Crawler
Fallback when Crawl4AI is not available
"""

import asyncio
import aiohttp
import csv
import json
import hashlib
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse
from collections import defaultdict
from dataclasses import dataclass, asdict
from bs4 import BeautifulSoup

try:
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment
    HAS_XLSX = True
except ImportError:
    HAS_XLSX = False


@dataclass
class PageData:
    url: str
    status_code: int = 0
    status: str = ""
    title: str = ""
    title_length: int = 0
    meta_description: str = ""
    description_length: int = 0
    h1: str = ""
    h1_count: int = 0
    canonical: str = ""
    meta_robots: str = ""
    word_count: int = 0
    response_time_ms: float = 0.0
    crawl_depth: int = 0
    internal_links: int = 0
    external_links: int = 0
    images: int = 0
    images_missing_alt: int = 0
PYHEADER
}

# Emit SiteCrawler class definition (__init__, is_internal, normalize_url)
_fallback_crawler_class_init() {
	cat <<'PYINIT'


class SiteCrawler:
    def __init__(self, base_url: str, max_urls: int = 100, max_depth: int = 3, delay_ms: int = 100):
        self.base_url = base_url.rstrip('/')
        self.base_domain = urlparse(base_url).netloc
        self.max_urls = max_urls
        self.max_depth = max_depth
        self.delay = delay_ms / 1000.0
        
        self.visited = set()
        self.queue = [(self.base_url, 0)]
        self.pages = []
        self.broken_links = []
        self.redirects = []

    def is_internal(self, url: str) -> bool:
        parsed = urlparse(url)
        return parsed.netloc == self.base_domain or parsed.netloc == ""

    def normalize_url(self, url: str, base: str) -> str:
        url = urljoin(base, url)
        parsed = urlparse(url)
        normalized = f"{parsed.scheme}://{parsed.netloc}{parsed.path}"
        if parsed.query:
            normalized += f"?{parsed.query}"
        return normalized.rstrip('/')
PYINIT
}

# Emit SiteCrawler._parse_html_meta() helper method
_fallback_crawler_class_parse_meta() {
	cat <<'PYPARSEMETA'

    def _parse_html_meta(self, soup, page):
        """Extract title, meta description, robots, canonical, H1, word count, images."""
        if soup.title:
            page.title = soup.title.get_text(strip=True)[:200]
            page.title_length = len(page.title)

        meta_desc = soup.find('meta', attrs={'name': 'description'})
        if meta_desc:
            page.meta_description = meta_desc.get('content', '')[:300]
            page.description_length = len(page.meta_description)

        meta_robots = soup.find('meta', attrs={'name': 'robots'})
        if meta_robots:
            page.meta_robots = meta_robots.get('content', '')

        canonical = soup.find('link', attrs={'rel': 'canonical'})
        if canonical:
            page.canonical = canonical.get('href', '')

        h1_tags = soup.find_all('h1')
        page.h1_count = len(h1_tags)
        if h1_tags:
            page.h1 = h1_tags[0].get_text(strip=True)[:200]

        text = soup.get_text(separator=' ', strip=True)
        page.word_count = len(text.split())

        images = soup.find_all('img')
        page.images = len(images)
        page.images_missing_alt = sum(1 for img in images if not img.get('alt'))
PYPARSEMETA
}

# Emit SiteCrawler._parse_html_links() helper method
_fallback_crawler_class_parse_links() {
	cat <<'PYPARSELINKS'

    def _parse_html_links(self, soup, url: str, depth: int):
        """Count internal/external links and enqueue unvisited internal URLs."""
        internal_count = 0
        external_count = 0

        for link in soup.find_all('a', href=True):
            href = link.get('href', '')
            if not href or href.startswith(('#', 'javascript:', 'mailto:', 'tel:')):
                continue

            target_url = self.normalize_url(href, url)

            if self.is_internal(target_url):
                internal_count += 1
                if target_url not in self.visited and depth < self.max_depth:
                    self.queue.append((target_url, depth + 1))
            else:
                external_count += 1

        return internal_count, external_count
PYPARSELINKS
}

# Emit SiteCrawler.fetch_page() method
_fallback_crawler_class_fetch() {
	cat <<'PYFETCH'

    async def fetch_page(self, session: aiohttp.ClientSession, url: str, depth: int) -> PageData:
        page = PageData(url=url, crawl_depth=depth)

        try:
            start = datetime.now()
            async with session.get(url, allow_redirects=True, timeout=aiohttp.ClientTimeout(total=15)) as response:
                page.status_code = response.status
                page.response_time_ms = (datetime.now() - start).total_seconds() * 1000

                if response.history:
                    for r in response.history:
                        self.redirects.append({
                            'original_url': str(r.url),
                            'status_code': r.status,
                            'redirect_url': str(response.url)
                        })

                page.status = "OK" if response.status < 300 else ("Redirect" if response.status < 400 else "Error")

                if response.status >= 400:
                    self.broken_links.append({'url': url, 'status_code': response.status, 'source': 'direct'})
                    return page

                content_type = response.headers.get('Content-Type', '')
                if 'text/html' not in content_type:
                    return page

                html = await response.text()
                soup = BeautifulSoup(html, 'html.parser')

                self._parse_html_meta(soup, page)
                page.internal_links, page.external_links = self._parse_html_links(soup, url, depth)

        except asyncio.TimeoutError:
            page.status = "Timeout"
        except Exception as e:
            page.status = f"Error: {str(e)[:50]}"

        return page
PYFETCH
}

# Emit SiteCrawler.crawl() method
_fallback_crawler_class_crawl() {
	cat <<'PYCRAWL'

    async def crawl(self):
        connector = aiohttp.TCPConnector(limit=5)
        headers = {'User-Agent': 'AIDevOps-SiteCrawler/2.0'}
        
        async with aiohttp.ClientSession(connector=connector, headers=headers) as session:
            while self.queue and len(self.visited) < self.max_urls:
                url, depth = self.queue.pop(0)
                
                if url in self.visited:
                    continue
                
                self.visited.add(url)
                page = await self.fetch_page(session, url, depth)
                self.pages.append(page)
                
                print(f"[{len(self.pages)}/{self.max_urls}] {page.status_code or 'ERR'} {url[:70]}")
                
                await asyncio.sleep(self.delay)
        
        return self.pages
PYCRAWL
}

# Emit SiteCrawler.export() method (CSV/XLSX section)
_fallback_crawler_class_export() {
	cat <<'PYEXPORT'

    def export(self, output_dir: Path, domain: str, fmt: str = "xlsx"):
        output_dir = Path(output_dir)
        
        # CSV export
        csv_file = output_dir / "crawl-data.csv"
        fieldnames = list(PageData.__dataclass_fields__.keys())
        
        with open(csv_file, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for page in self.pages:
                writer.writerow(asdict(page))
        print(f"Exported: {csv_file}")
        
        # XLSX export
        if fmt in ("xlsx", "all") and HAS_XLSX:
            xlsx_file = output_dir / "crawl-data.xlsx"
            wb = openpyxl.Workbook()
            ws = wb.active
            ws.title = "Crawl Data"
            
            # Headers
            for col, field in enumerate(fieldnames, 1):
                cell = ws.cell(row=1, column=col, value=field.replace('_', ' ').title())
                cell.font = Font(bold=True)
            
            # Data
            for row, page in enumerate(self.pages, 2):
                for col, field in enumerate(fieldnames, 1):
                    ws.cell(row=row, column=col, value=getattr(page, field))
            
            wb.save(xlsx_file)
            print(f"Exported: {xlsx_file}")
        
        # Broken links
        if self.broken_links:
            broken_file = output_dir / "broken-links.csv"
            with open(broken_file, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=['url', 'status_code', 'source'])
                writer.writeheader()
                writer.writerows(self.broken_links)
            print(f"Exported: {broken_file}")
        
        # Redirects
        if self.redirects:
            redirects_file = output_dir / "redirects.csv"
            with open(redirects_file, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=['original_url', 'status_code', 'redirect_url'])
                writer.writeheader()
                writer.writerows(self.redirects)
            print(f"Exported: {redirects_file}")
        
        return self._export_issues_and_summary(output_dir)
PYEXPORT
}

# Emit SiteCrawler._export_issues_and_summary() method
_fallback_crawler_class_issues_summary() {
	cat <<'PYISSUES'

    def _export_issues_and_summary(self, output_dir: Path):
        # Meta issues
        meta_issues = []
        for page in self.pages:
            issues = []
            if not page.title:
                issues.append("Missing title")
            elif page.title_length > 60:
                issues.append("Title too long")
            if not page.meta_description:
                issues.append("Missing description")
            elif page.description_length > 160:
                issues.append("Description too long")
            if page.h1_count == 0:
                issues.append("Missing H1")
            elif page.h1_count > 1:
                issues.append("Multiple H1s")
            
            if issues:
                meta_issues.append({
                    'url': page.url,
                    'title': page.title[:50],
                    'h1': page.h1[:50],
                    'issues': '; '.join(issues)
                })
        
        if meta_issues:
            issues_file = output_dir / "meta-issues.csv"
            with open(issues_file, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=['url', 'title', 'h1', 'issues'])
                writer.writeheader()
                writer.writerows(meta_issues)
            print(f"Exported: {issues_file}")
        
        # Summary
        summary = {
            'crawl_date': datetime.now().isoformat(),
            'base_url': self.base_url,
            'pages_crawled': len(self.pages),
            'broken_links': len(self.broken_links),
            'redirects': len(self.redirects),
            'meta_issues': len(meta_issues),
            'status_codes': {}
        }
        
        for page in self.pages:
            code = str(page.status_code)
            summary['status_codes'][code] = summary['status_codes'].get(code, 0) + 1
        
        with open(output_dir / "summary.json", 'w') as f:
            json.dump(summary, f, indent=2)
        print(f"Exported: {output_dir / 'summary.json'}")
        
        return summary
PYISSUES
}

# Emit Python main() entry point
_fallback_crawler_main() {
	cat <<'PYMAIN'


async def main():
    if len(sys.argv) < 4:
        print("Usage: crawler.py <url> <output_dir> <max_urls> [depth] [format]")
        sys.exit(1)
    
    url = sys.argv[1]
    output_dir = sys.argv[2]
    max_urls = int(sys.argv[3])
    depth = int(sys.argv[4]) if len(sys.argv) > 4 else 3
    fmt = sys.argv[5] if len(sys.argv) > 5 else "xlsx"
    
    domain = urlparse(url).netloc
    
    print(f"Starting crawl: {url}")
    print(f"Max URLs: {max_urls}, Max depth: {depth}")
    print()
    
    crawler = SiteCrawler(url, max_urls=max_urls, max_depth=depth)
    await crawler.crawl()
    
    summary = crawler.export(Path(output_dir), domain, fmt)
    
    print()
    print("=== Crawl Summary ===")
    print(f"Pages crawled: {summary['pages_crawled']}")
    print(f"Broken links: {summary['broken_links']}")
    print(f"Redirects: {summary['redirects']}")
    print(f"Meta issues: {summary['meta_issues']}")


if __name__ == "__main__":
    asyncio.run(main())
PYMAIN
}

# Lightweight Python crawler (fallback) - assembles Python script from sections
generate_fallback_crawler() {
	_fallback_crawler_header
	_fallback_crawler_class_init
	_fallback_crawler_class_parse_meta
	_fallback_crawler_class_parse_links
	_fallback_crawler_class_fetch
	_fallback_crawler_class_crawl
	_fallback_crawler_class_export
	_fallback_crawler_class_issues_summary
	_fallback_crawler_main
	return 0
}

# Parse do_crawl options into caller-local variables.
# Sets: depth, max_urls, format, output_base, force_fallback
_do_crawl_parse_opts() {
	depth="$DEFAULT_DEPTH"
	max_urls="$DEFAULT_MAX_URLS"
	format="$DEFAULT_FORMAT"
	output_base="$DEFAULT_OUTPUT_DIR"
	force_fallback=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--depth)
			depth="$2"
			shift 2
			;;
		--max-urls)
			max_urls="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		--output)
			output_base="$2"
			shift 2
			;;
		--fallback)
			force_fallback=true
			shift
			;;
		*) shift ;;
		esac
	done
	return 0
}

# Run the Python fallback crawler for do_crawl.
# Arguments: $1=url $2=output_dir $3=max_urls $4=depth $5=format $6=output_base $7=domain
_do_crawl_run_python() {
	local url="$1"
	local output_dir="$2"
	local max_urls="$3"
	local depth="$4"
	local format="$5"
	local output_base="$6"
	local domain="$7"

	print_info "Using lightweight Python crawler..."

	if ! find_python; then
		print_warning "Installing Python dependencies..."
		if ! install_python_deps; then
			print_error "Could not find or install Python with required packages"
			print_info "Install manually: pip3 install aiohttp beautifulsoup4 openpyxl"
			return 1
		fi
	fi

	print_info "Using: $PYTHON_CMD"

	local crawler_script
	crawler_script=$(mktemp /tmp/site_crawler_XXXXXX.py)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${crawler_script}'"
	generate_fallback_crawler >"$crawler_script"

	"$PYTHON_CMD" "$crawler_script" "$url" "$output_dir" "$max_urls" "$depth" "$format"
	local exit_code=$?

	rm -f "$crawler_script"

	if [[ $exit_code -eq 0 ]]; then
		print_success "Crawl complete!"
		print_info "Results: $output_dir"
		print_info "Latest: ${output_base}/${domain}/_latest"
	else
		print_error "Crawl failed with exit code $exit_code"
	fi

	return $exit_code
}

# Run crawl
do_crawl() {
	local url="$1"
	shift

	local depth max_urls format output_base force_fallback
	_do_crawl_parse_opts "$@"

	local domain
	domain=$(get_domain "$url")

	local output_dir
	output_dir=$(create_output_dir "$domain" "$output_base")

	print_header "Site Crawler - SEO Audit"
	print_info "URL: $url"
	print_info "Output: $output_dir"
	print_info "Depth: $depth, Max URLs: $max_urls"

	if [[ "$force_fallback" != "true" ]] && check_crawl4ai; then
		print_success "Crawl4AI detected at ${CRAWL4AI_URL}"
		crawl_with_crawl4ai "$url" "$output_dir" "$max_urls" "$depth"
		print_success "Crawl complete!"
		print_info "Results: $output_dir"
		print_info "Latest: ${output_base}/${domain}/_latest"
		return 0
	fi

	_do_crawl_run_python "$url" "$output_dir" "$max_urls" "$depth" "$format" "$output_base" "$domain"
	return $?
}

# Audit broken links
audit_links() {
	local url="$1"
	shift
	print_info "Running broken link audit..."
	do_crawl "$url" --max-urls 200 "$@"
	return 0
}

# Audit meta data
audit_meta() {
	local url="$1"
	shift
	print_info "Running meta data audit..."
	do_crawl "$url" --max-urls 200 "$@"
	return 0
}

# Audit redirects
audit_redirects() {
	local url="$1"
	shift
	print_info "Running redirect audit..."
	do_crawl "$url" --max-urls 200 "$@"
	return 0
}

# Generate XML sitemap
generate_sitemap() {
	local url="$1"
	local domain
	domain=$(get_domain "$url")
	local output_dir="${DEFAULT_OUTPUT_DIR}/${domain}/_latest"

	if [[ ! -d "$output_dir" ]]; then
		print_error "No crawl data found. Run 'crawl' first."
		return 1
	fi

	local crawl_data="${output_dir}/crawl-data.csv"
	if [[ ! -f "$crawl_data" ]]; then
		print_error "Crawl data not found: $crawl_data"
		return 1
	fi

	print_header "Generating XML Sitemap"

	local sitemap="${output_dir}/sitemap.xml"

	{
		echo '<?xml version="1.0" encoding="UTF-8"?>'
		echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'

		tail -n +2 "$crawl_data" | while IFS=, read -r page_url status_code rest; do
			if [[ "$status_code" == "200" ]]; then
				page_url="${page_url//\"/}"
				echo "  <url>"
				echo "    <loc>$page_url</loc>"
				echo "    <changefreq>weekly</changefreq>"
				echo "    <priority>0.5</priority>"
				echo "  </url>"
			fi
		done

		echo '</urlset>'
	} >"$sitemap"

	print_success "Sitemap generated: $sitemap"
	return 0
}

# Compare crawls
compare_crawls() {
	local arg1="${1:-}"
	local arg2="${2:-}"

	print_header "Comparing Crawls"

	if [[ -z "$arg2" ]] && [[ -n "$arg1" ]]; then
		local domain
		domain=$(get_domain "$arg1")
		local domain_dir="${DEFAULT_OUTPUT_DIR}/${domain}"

		if [[ ! -d "$domain_dir" ]]; then
			print_error "No crawl data found for domain"
			return 1
		fi

		local crawls
		crawls=$(find "$domain_dir" -maxdepth 1 -type d -name "20*" | sort -r | head -2)
		local count
		count=$(echo "$crawls" | wc -l | tr -d ' ')

		if [[ $count -lt 2 ]]; then
			print_error "Need at least 2 crawls to compare"
			return 1
		fi

		arg1=$(echo "$crawls" | head -1)
		arg2=$(echo "$crawls" | tail -1)
	fi

	print_info "Crawl 1: $arg1"
	print_info "Crawl 2: $arg2"

	if [[ -f "${arg1}/crawl-data.csv" ]] && [[ -f "${arg2}/crawl-data.csv" ]]; then
		local urls1 urls2
		urls1=$(cut -d, -f1 "${arg1}/crawl-data.csv" | tail -n +2 | sort -u | wc -l | tr -d ' ')
		urls2=$(cut -d, -f1 "${arg2}/crawl-data.csv" | tail -n +2 | sort -u | wc -l | tr -d ' ')

		print_info "Crawl 1 URLs: $urls1"
		print_info "Crawl 2 URLs: $urls2"
	fi

	return 0
}

# Check status
check_status() {
	print_header "Site Crawler Status"

	# Check Crawl4AI
	print_info "Checking Crawl4AI..."
	if check_crawl4ai; then
		print_success "Crawl4AI: Running at ${CRAWL4AI_URL}"
	else
		print_warning "Crawl4AI: Not running (will use fallback crawler)"
	fi

	# Check Python
	print_info "Checking Python..."
	if find_python; then
		print_success "Python: $PYTHON_CMD with required packages"
	else
		print_warning "Python: Dependencies not installed"
		print_info "  Install with: pip3 install aiohttp beautifulsoup4 openpyxl"
	fi

	# Check dependencies
	if command -v jq &>/dev/null; then
		print_success "jq: installed"
	else
		print_warning "jq: not installed (optional, for JSON processing)"
	fi

	if command -v curl &>/dev/null; then
		print_success "curl: installed"
	else
		print_error "curl: not installed (required)"
	fi

	return 0
}

# Show help
show_help() {
	cat <<'EOF'
Site Crawler Helper - SEO Spider Tool

Usage: site-crawler-helper.sh [command] [url] [options]

Commands:
  crawl <url>           Full site crawl with SEO data extraction
  audit-links <url>     Check for broken links (4XX/5XX errors)
  audit-meta <url>      Audit page titles and meta descriptions
  audit-redirects <url> Analyze redirects and chains
  generate-sitemap <url> Generate XML sitemap from crawl
  compare [url|dir1] [dir2] Compare two crawls
  status                Check crawler dependencies
  help                  Show this help message

Options:
  --depth <n>           Max crawl depth (default: 3)
  --max-urls <n>        Max URLs to crawl (default: 100)
  --format <fmt>        Output format: csv, xlsx, all (default: xlsx)
  --output <dir>        Output directory (default: ~/Downloads)
  --fallback            Force use of fallback crawler (skip Crawl4AI)

Examples:
  # Full site crawl
  site-crawler-helper.sh crawl https://example.com

  # Limited crawl
  site-crawler-helper.sh crawl https://example.com --depth 2 --max-urls 50

  # Quick broken link check
  site-crawler-helper.sh audit-links https://example.com

  # Generate sitemap from existing crawl
  site-crawler-helper.sh generate-sitemap https://example.com

  # Check status
  site-crawler-helper.sh status

Output Structure:
  ~/Downloads/{domain}/{timestamp}/
    - crawl-data.xlsx      Full crawl data
    - crawl-data.csv       Full crawl data (CSV)
    - broken-links.csv     4XX/5XX errors
    - redirects.csv        Redirect chains
    - meta-issues.csv      Title/description issues
    - summary.json         Crawl statistics

  ~/Downloads/{domain}/_latest -> symlink to latest crawl

Backends:
  - Crawl4AI (preferred): Uses Docker-based Crawl4AI when available
  - Fallback: Lightweight async Python crawler

Related:
  - E-E-A-T scoring: eeat-score-helper.sh
  - Crawl4AI setup: crawl4ai-helper.sh
  - PageSpeed: pagespeed-helper.sh
EOF
	return 0
}

# Main function
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	crawl)
		do_crawl "$@"
		;;
	audit-links)
		audit_links "$@"
		;;
	audit-meta)
		audit_meta "$@"
		;;
	audit-redirects)
		audit_redirects "$@"
		;;
	generate-sitemap)
		generate_sitemap "$@"
		;;
	compare)
		compare_crawls "$@"
		;;
	status)
		check_status
		;;
	help | -h | --help | "")
		show_help
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac

	return 0
}

main "$@"
