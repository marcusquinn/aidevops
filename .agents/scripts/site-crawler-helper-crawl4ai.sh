#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# Site Crawler Helper -- Crawl4AI Engine
# =============================================================================
# Functions for crawling websites via the Crawl4AI API, including batch
# processing, link discovery, report generation, and XLSX export.
#
# Usage: source "${SCRIPT_DIR}/site-crawler-helper-crawl4ai.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, print_warning, print_success,
#     _save_cleanup_scope, push_cleanup, _run_cleanups)
#   - site-crawler-helper-markdown.sh (save_markdown_with_metadata)
#   - jq, curl
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SITE_CRAWLER_CRAWL4AI_LIB_LOADED:-}" ]] && return 0
_SITE_CRAWLER_CRAWL4AI_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

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
	# t2997: drop .py — XXXXXX must be at end for BSD mktemp.
	xlsx_script=$(mktemp /tmp/xlsx_gen-XXXXXX)
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
