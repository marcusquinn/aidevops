#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# Email Health Check -- Content Analysis
# =============================================================================
# HTML email content quality checks: subject line, preheader,
# accessibility, links, images, spam words, and content scoring.
#
# Usage: source "${SCRIPT_DIR}/email-health-check-helper-content.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - email-health-check-helper.sh (print_header)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_EMAIL_HEALTH_CONTENT_LIB_LOADED:-}" ]] && return 0
_EMAIL_HEALTH_CONTENT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Content Score Tracking (separate from infrastructure score) ---

CONTENT_SCORE=0
CONTENT_MAX=0

# --- Functions ---

# Validate that a file exists and is readable HTML
validate_html_file() {
	local file="$1"
	if [[ ! -f "$file" ]]; then
		print_error "File not found: $file"
		return 1
	fi
	if [[ ! -r "$file" ]]; then
		print_error "File not readable: $file"
		return 1
	fi
	return 0
}

add_content_score() {
	local points="$1"
	local max_points="$2"
	CONTENT_SCORE=$((CONTENT_SCORE + points))
	CONTENT_MAX=$((CONTENT_MAX + max_points))
	return 0
}

# Check subject line quality
check_subject() {
	local file="$1"
	validate_html_file "$file" || return 1

	print_header "Subject Line Check"

	local subject=""
	# Extract from <title> tag (common pattern in HTML emails)
	subject=$(sed -n 's/.*<[tT][iI][tT][lL][eE]>\([^<]*\).*/\1/p' "$file" 2>/dev/null | head -1 || true)
	# Fallback: look for subject in meta tag
	if [[ -z "$subject" ]]; then
		subject=$(sed -n 's/.*name="subject"[[:space:]]*content="\([^"]*\)".*/\1/Ip' "$file" 2>/dev/null | head -1 || true)
	fi

	if [[ -z "$subject" ]]; then
		print_warning "No subject line found (<title> tag or meta name=\"subject\")"
		print_info "Add a <title> tag to your HTML email for subject line analysis"
		add_content_score 0 2
		return 1
	fi

	print_info "Subject: $subject"
	local subject_len=${#subject}
	local score=2

	# Length check
	if [[ "$subject_len" -le 50 ]]; then
		print_success "Length: $subject_len chars (good, under 50)"
	elif [[ "$subject_len" -le 80 ]]; then
		print_warning "Length: $subject_len chars (may truncate on mobile, aim for under 50)"
		score=$((score - 1))
	else
		print_error "Length: $subject_len chars (will truncate on most clients, max 80)"
		score=$((score - 2))
	fi

	# ALL CAPS check
	local upper_count
	upper_count=$(echo "$subject" | grep -o '[A-Z]' || true | wc -l | tr -d ' ')
	local alpha_count
	alpha_count=$(echo "$subject" | grep -o '[a-zA-Z]' || true | wc -l | tr -d ' ')
	if [[ "$alpha_count" -gt 0 ]]; then
		local upper_pct=$(((upper_count * 100) / alpha_count))
		if [[ "$upper_pct" -gt 50 ]]; then
			print_warning "ALL CAPS: ${upper_pct}% uppercase (spam filter trigger)"
			if [[ "$score" -gt 0 ]]; then
				score=$((score - 1))
			fi
		fi
	fi

	# Excessive punctuation
	local excl_count
	excl_count=$(echo "$subject" | grep -o '!' || true | wc -l | tr -d ' ')
	local quest_count
	quest_count=$(echo "$subject" | grep -o '?' || true | wc -l | tr -d ' ')
	if [[ "$excl_count" -gt 1 ]]; then
		print_warning "Excessive exclamation marks: $excl_count (use at most 1)"
		if [[ "$score" -gt 0 ]]; then
			score=$((score - 1))
		fi
	fi
	if [[ "$quest_count" -gt 1 ]]; then
		print_warning "Excessive question marks: $quest_count (use at most 1)"
	fi

	# Spam trigger words in subject
	local spam_words_list=("free" "act now" "limited time" "click here" "buy now" "order now" "no obligation" "risk free" "winner" "congratulations" "urgent" "cash" "guarantee")
	local subject_lower
	subject_lower=$(echo "$subject" | tr '[:upper:]' '[:lower:]')
	local spam_found=false
	local spam_word
	for spam_word in "${spam_words_list[@]}"; do
		if [[ "$subject_lower" == *"$spam_word"* ]]; then
			print_warning "Spam trigger word in subject: '$spam_word'"
			spam_found=true
		fi
	done
	if [[ "$spam_found" == true ]]; then
		if [[ "$score" -gt 0 ]]; then
			score=$((score - 1))
		fi
	fi

	add_content_score "$score" 2
	return 0
}

# Check preheader/preview text
check_preheader() {
	local file="$1"
	validate_html_file "$file" || return 1

	print_header "Preheader Text Check"

	local preheader=""
	# Look for common preheader patterns
	# Pattern 1: hidden div/span with preheader class
	preheader=$(sed -n 's/.*class="[^"]*preheader[^"]*"[^>]*>\([^<]*\).*/\1/Ip' "$file" 2>/dev/null | head -1 || true)
	# Pattern 2: hidden preview text span
	if [[ -z "$preheader" ]]; then
		preheader=$(sed -n 's/.*class="[^"]*preview[^"]*"[^>]*>\([^<]*\).*/\1/Ip' "$file" 2>/dev/null | head -1 || true)
	fi
	# Pattern 3: meta description
	if [[ -z "$preheader" ]]; then
		preheader=$(sed -n 's/.*name="description"[[:space:]]*content="\([^"]*\)".*/\1/Ip' "$file" 2>/dev/null | head -1 || true)
	fi

	if [[ -z "$preheader" ]]; then
		print_warning "No preheader/preview text found"
		print_info "Add a hidden preheader element: <span class=\"preheader\">Preview text here</span>"
		print_info "Without a preheader, email clients show the first visible text"
		add_content_score 0 1
		return 1
	fi

	print_info "Preheader: $preheader"
	local preheader_len=${#preheader}
	local score=1

	# Length check
	if [[ "$preheader_len" -ge 40 && "$preheader_len" -le 130 ]]; then
		print_success "Length: $preheader_len chars (optimal range: 40-130)"
	elif [[ "$preheader_len" -lt 40 ]]; then
		print_warning "Length: $preheader_len chars (too short, aim for 40-130)"
		score=0
	else
		print_warning "Length: $preheader_len chars (may truncate, aim for 40-130)"
	fi

	# Check for placeholder text
	local preheader_lower
	preheader_lower=$(echo "$preheader" | tr '[:upper:]' '[:lower:]')
	local phrase
	for phrase in "view in browser" "email not displaying" "view this email" "having trouble viewing"; do
		if [[ "$preheader_lower" == *"$phrase"* ]]; then
			print_warning "Default/placeholder preheader text detected: '$phrase'"
			score=0
		fi
	done

	add_content_score "$score" 1
	return 0
}

# Check email accessibility
check_accessibility() {
	local file="$1"
	validate_html_file "$file" || return 1

	print_header "Accessibility Check"

	local score=2
	local issues=0
	local content
	content=$(cat "$file")

	# Check lang attribute
	if echo "$content" | grep -qi '<html[^>]*lang='; then
		print_success "Language attribute found on <html> tag"
	else
		print_warning "Missing lang attribute on <html> tag (e.g., <html lang=\"en\">)"
		issues=$((issues + 1))
	fi

	# Check image alt text
	local img_count
	img_count=$(echo "$content" | grep -io '<img[[:space:]]' || true | wc -l | tr -d ' ')
	local img_with_alt
	img_with_alt=$(echo "$content" | grep -io '<img[^>]*alt=' || true | wc -l | tr -d ' ')
	local img_no_alt=$((img_count - img_with_alt))
	if [[ "$img_no_alt" -lt 0 ]]; then
		img_no_alt=0
	fi

	if [[ "$img_count" -eq 0 ]]; then
		print_info "No images found in email"
	elif [[ "$img_no_alt" -eq 0 ]]; then
		print_success "All $img_count images have alt attributes"
	else
		print_warning "$img_no_alt of $img_count images missing alt attribute"
		issues=$((issues + 1))
	fi

	# Check for layout table roles
	local table_count
	table_count=$(echo "$content" | grep -io '<table[[:space:]]' || true | wc -l | tr -d ' ')
	local table_with_role
	table_with_role=$(echo "$content" | grep -io '<table[^>]*role=' || true | wc -l | tr -d ' ')

	if [[ "$table_count" -gt 0 ]]; then
		if [[ "$table_with_role" -eq "$table_count" ]]; then
			print_success "All $table_count tables have role attributes"
		else
			local missing=$((table_count - table_with_role))
			print_warning "$missing of $table_count tables missing role attribute (use role=\"presentation\" for layout tables)"
			issues=$((issues + 1))
		fi
	fi

	# Check for generic link text
	local generic_links
	generic_links=$(echo "$content" | grep -Eio '<a[^>]*>[^<]*(click here|read more|learn more)[^<]*</a>' || true | wc -l | tr -d ' ')
	if [[ "$generic_links" -gt 0 ]]; then
		print_warning "$generic_links links with generic text (\"click here\", \"read more\") - use descriptive link text"
		issues=$((issues + 1))
	fi

	# Check for small font sizes
	local small_fonts
	small_fonts=$(echo "$content" | grep -Eio 'font-size:[[:space:]]*[0-9]+px' | sed 's/[^0-9]//g' | while read -r size; do
		if [[ "$size" -lt 14 ]]; then
			echo "$size"
		fi
	done | wc -l | tr -d ' ')
	if [[ "$small_fonts" -gt 0 ]]; then
		print_warning "$small_fonts instances of font-size below 14px (readability concern)"
		issues=$((issues + 1))
	fi

	# Score based on issues
	if [[ "$issues" -eq 0 ]]; then
		print_success "No accessibility issues found"
	elif [[ "$issues" -le 2 ]]; then
		score=1
	else
		score=0
	fi

	add_content_score "$score" 2
	return 0
}

# Check links in email
check_links() {
	local file="$1"
	validate_html_file "$file" || return 1

	print_header "Link Validation"

	local score=2
	local content
	content=$(cat "$file")

	# Count total links
	local link_count
	link_count=$(echo "$content" | grep -io '<a[^>]*href=' || true | wc -l | tr -d ' ')
	print_info "Total links found: $link_count"

	# Check for empty hrefs
	local empty_hrefs
	empty_hrefs=$(echo "$content" | grep -Eio 'href=["'"'"'][[:space:]]*["'"'"']' || true | wc -l | tr -d ' ')
	if [[ "$empty_hrefs" -gt 0 ]]; then
		print_error "$empty_hrefs links with empty href"
		score=$((score - 1))
	fi

	# Check for placeholder links
	local placeholder_links
	placeholder_links=$(echo "$content" | grep -Eio 'href=["'"'"'](#|javascript:|https?://example\.com)["'"'"']' || true | wc -l | tr -d ' ')
	if [[ "$placeholder_links" -gt 0 ]]; then
		print_warning "$placeholder_links placeholder links detected (#, javascript:, example.com)"
		if [[ "$score" -gt 0 ]]; then
			score=$((score - 1))
		fi
	fi

	# Check for unsubscribe link (CAN-SPAM requirement)
	local unsub_links
	unsub_links=$(echo "$content" | grep -Eio '(unsubscribe|opt.out|manage.preferences|email.preferences)' || true | wc -l | tr -d ' ')
	if [[ "$unsub_links" -gt 0 ]]; then
		print_success "Unsubscribe/opt-out link found"
	else
		print_error "No unsubscribe link found (CAN-SPAM requirement)"
		if [[ "$score" -gt 0 ]]; then
			score=$((score - 1))
		fi
	fi

	# Check link count (too many triggers spam filters)
	if [[ "$link_count" -gt 20 ]]; then
		print_warning "High link count: $link_count (over 20 may trigger spam filters)"
	fi

	# Report UTM parameters
	local utm_links
	utm_links=$(echo "$content" | grep -io 'utm_' || true | wc -l | tr -d ' ')
	if [[ "$utm_links" -gt 0 ]]; then
		print_info "UTM tracking parameters found in $utm_links locations"
	fi

	add_content_score "$score" 2
	return 0
}

# Check images in email
check_images() {
	local file="$1"
	validate_html_file "$file" || return 1

	print_header "Image Validation"

	local score=2
	local content
	content=$(cat "$file")

	# Count images
	local img_count
	img_count=$(echo "$content" | grep -io '<img[[:space:]]' || true | wc -l | tr -d ' ')

	if [[ "$img_count" -eq 0 ]]; then
		print_info "No images found in email"
		add_content_score 2 2
		return 0
	fi

	print_info "Total images found: $img_count"

	# Check for missing alt text (total images minus images with alt)
	local img_with_alt
	img_with_alt=$(echo "$content" | grep -io '<img[^>]*alt=' || true | wc -l | tr -d ' ')
	local img_no_alt=$((img_count - img_with_alt))
	if [[ "$img_no_alt" -lt 0 ]]; then
		img_no_alt=0
	fi
	if [[ "$img_no_alt" -gt 0 ]]; then
		print_warning "$img_no_alt images missing alt attribute"
		score=$((score - 1))
	fi

	# Check for missing dimensions (total images minus images with width/height)
	local img_with_width
	img_with_width=$(echo "$content" | grep -io '<img[^>]*width=' || true | wc -l | tr -d ' ')
	local img_with_height
	img_with_height=$(echo "$content" | grep -io '<img[^>]*height=' || true | wc -l | tr -d ' ')
	local img_no_width=$((img_count - img_with_width))
	local img_no_height=$((img_count - img_with_height))
	if [[ "$img_no_width" -lt 0 ]]; then
		img_no_width=0
	fi
	if [[ "$img_no_height" -lt 0 ]]; then
		img_no_height=0
	fi
	if [[ "$img_no_width" -gt 0 || "$img_no_height" -gt 0 ]]; then
		print_warning "Images missing dimensions: $img_no_width without width, $img_no_height without height"
		print_info "Missing dimensions cause layout shift when images load"
	fi

	# Count external images
	local external_imgs
	external_imgs=$(echo "$content" | grep -Eio 'src=["'"'"']https?://' || true | wc -l | tr -d ' ')
	print_info "External images: $external_imgs of $img_count"

	# Estimate image-to-text ratio (rough heuristic)
	local text_length
	# Strip all HTML tags and count remaining text
	text_length=$(echo "$content" | sed 's/<[^>]*>//g' | tr -s '[:space:]' | wc -c | tr -d ' ')
	local total_length
	total_length=$(echo "$content" | wc -c | tr -d ' ')

	if [[ "$total_length" -gt 0 ]]; then
		local text_pct=$(((text_length * 100) / total_length))
		if [[ "$text_pct" -lt 40 ]]; then
			print_warning "Low text-to-HTML ratio: ${text_pct}% (image-heavy emails may trigger spam filters)"
			if [[ "$score" -gt 0 ]]; then
				score=$((score - 1))
			fi
		else
			print_info "Text-to-HTML ratio: ${text_pct}%"
		fi
	fi

	# Check file size (Gmail clips at 102KB)
	local file_size
	file_size=$(wc -c <"$file" | tr -d ' ')
	local file_size_kb=$((file_size / 1024))
	if [[ "$file_size_kb" -gt 102 ]]; then
		print_error "Email HTML is ${file_size_kb}KB (Gmail clips emails over 102KB)"
		if [[ "$score" -gt 0 ]]; then
			score=$((score - 1))
		fi
	elif [[ "$file_size_kb" -gt 80 ]]; then
		print_warning "Email HTML is ${file_size_kb}KB (approaching Gmail's 102KB clip limit)"
	else
		print_success "Email HTML size: ${file_size_kb}KB (under Gmail's 102KB limit)"
	fi

	add_content_score "$score" 2
	return 0
}

# Check for spam trigger words in email body
check_spam_words() {
	local file="$1"
	validate_html_file "$file" || return 1

	print_header "Spam Word Scan"

	local content
	# Strip HTML tags for text analysis
	content=$(sed 's/<[^>]*>//g' "$file" | tr '[:upper:]' '[:lower:]')

	local score=1
	local high_risk_count=0
	local medium_risk_count=0

	# High-risk spam words (commonly trigger filters)
	local high_risk_words
	high_risk_words="act now limited time buy now order now no obligation risk free winner congratulations urgent cash guarantee double your earn money no cost"

	for phrase in "act now" "limited time" "buy now" "order now" "no obligation" "risk free" "winner" "congratulations" "urgent" "cash" "guarantee" "double your" "earn money" "no cost"; do
		local count
		count=$(echo "$content" | grep -io "$phrase" | wc -l | tr -d ' ')
		if [[ "$count" -gt 0 ]]; then
			print_warning "High-risk spam phrase: '$phrase' (found $count times)"
			high_risk_count=$((high_risk_count + count))
		fi
	done

	# Medium-risk words
	for phrase in "dear friend" "once in a lifetime" "as seen on" "special promotion" "100% free" "click below" "apply now" "no questions asked"; do
		local count
		count=$(echo "$content" | grep -io "$phrase" | wc -l | tr -d ' ')
		if [[ "$count" -gt 0 ]]; then
			print_info "Medium-risk spam phrase: '$phrase' (found $count times)"
			medium_risk_count=$((medium_risk_count + count))
		fi
	done

	if [[ "$high_risk_count" -eq 0 && "$medium_risk_count" -eq 0 ]]; then
		print_success "No spam trigger words detected"
	else
		print_info "High-risk phrases: $high_risk_count, Medium-risk phrases: $medium_risk_count"
		if [[ "$high_risk_count" -gt 3 ]]; then
			score=0
		fi
	fi

	add_content_score "$score" 1
	return 0
}

# Run all content checks on an HTML email file
check_content() {
	local file="$1"
	validate_html_file "$file" || return 1

	print_header "Content Precheck for $file"
	echo ""

	# Reset content score
	CONTENT_SCORE=0
	CONTENT_MAX=0

	check_subject "$file" || true
	check_preheader "$file" || true
	check_accessibility "$file" || true
	check_links "$file" || true
	check_images "$file" || true
	check_spam_words "$file" || true

	# Print content score summary
	print_content_score_summary "$file"

	return 0
}

# Print content score summary
print_content_score_summary() {
	local file="$1"

	print_header "Content Score for $file"
	echo ""

	if [[ "$CONTENT_MAX" -eq 0 ]]; then
		print_warning "No content checks were scored"
		return 0
	fi

	local percentage=$(((CONTENT_SCORE * 100) / CONTENT_MAX))
	local grade

	if [[ "$percentage" -ge 90 ]]; then
		grade="A"
	elif [[ "$percentage" -ge 80 ]]; then
		grade="B"
	elif [[ "$percentage" -ge 70 ]]; then
		grade="C"
	elif [[ "$percentage" -ge 60 ]]; then
		grade="D"
	else
		grade="F"
	fi

	echo "  Score: $CONTENT_SCORE / $CONTENT_MAX ($percentage%)"
	echo "  Grade: $grade"
	echo ""

	case "$grade" in
	"A")
		print_success "Excellent content quality - ready to send"
		;;
	"B")
		print_success "Good content quality - minor improvements possible"
		;;
	"C")
		print_warning "Fair content quality - review flagged issues before sending"
		;;
	"D")
		print_warning "Poor content quality - significant issues need attention"
		;;
	"F")
		print_error "Critical content issues - do not send without fixing"
		;;
	esac

	echo ""
	print_info "Score breakdown: Subject(2) + Preheader(1) + Accessibility(2)"
	print_info "  + Links(2) + Images(2) + Spam Words(1) = 10 max"

	return 0
}
