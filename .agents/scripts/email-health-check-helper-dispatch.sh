#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# Email Health Check -- Dispatch, Scoring, and UI
# =============================================================================
# Combined/dispatch functions, score summaries, help text, and
# command routing for the email health check CLI.
#
# Usage: source "${SCRIPT_DIR}/email-health-check-helper-dispatch.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - email-health-check-helper.sh (add_score, print_header, command_exists,
#     HEALTH_SCORE, HEALTH_MAX, HELP_SHOW_MESSAGE, USAGE_COMMAND_OPTIONS, HELP_USAGE_INFO)
#   - email-health-check-helper-infrastructure.sh (check_* infra functions)
#   - email-health-check-helper-content.sh (check_* content functions,
#     CONTENT_SCORE, CONTENT_MAX)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_EMAIL_HEALTH_DISPATCH_LIB_LOADED:-}" ]] && return 0
_EMAIL_HEALTH_DISPATCH_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Dispatch error message constants (deduplicated for string-literal gate) ---

_ERR_DOMAIN_REQUIRED="Domain required"
_ERR_HTML_REQUIRED="HTML file required"

# --- Functions ---

# Combined precheck: infrastructure + content
check_precheck() {
	local domain="$1"
	local file="$2"

	if [[ -z "$domain" ]]; then
		print_error "Domain required for precheck"
		return 1
	fi
	if [[ -z "$file" ]]; then
		print_error "HTML file required for precheck"
		print_info "Usage: $0 precheck <domain> <html-file>"
		return 1
	fi

	print_header "Full Email Precheck: $domain + $file"
	echo ""

	# Run infrastructure checks
	check_full "$domain"

	local infra_score="$HEALTH_SCORE"
	local infra_max="$HEALTH_MAX"

	# Run content checks
	echo ""
	check_content "$file"

	# Print combined summary
	print_header "Combined Precheck Summary"
	echo ""

	local combined_score=$((infra_score + CONTENT_SCORE))
	local combined_max=$((infra_max + CONTENT_MAX))

	if [[ "$combined_max" -eq 0 ]]; then
		print_warning "No checks were scored"
		return 0
	fi

	local infra_pct=0
	if [[ "$infra_max" -gt 0 ]]; then
		infra_pct=$(((infra_score * 100) / infra_max))
	fi
	local content_pct=0
	if [[ "$CONTENT_MAX" -gt 0 ]]; then
		content_pct=$(((CONTENT_SCORE * 100) / CONTENT_MAX))
	fi
	local combined_pct=$(((combined_score * 100) / combined_max))

	local combined_grade
	if [[ "$combined_pct" -ge 90 ]]; then
		combined_grade="A"
	elif [[ "$combined_pct" -ge 80 ]]; then
		combined_grade="B"
	elif [[ "$combined_pct" -ge 70 ]]; then
		combined_grade="C"
	elif [[ "$combined_pct" -ge 60 ]]; then
		combined_grade="D"
	else
		combined_grade="F"
	fi

	echo "  Infrastructure: $infra_score/$infra_max ($infra_pct%)"
	echo "  Content:        $CONTENT_SCORE/$CONTENT_MAX ($content_pct%)"
	echo "  Combined:       $combined_score/$combined_max ($combined_pct%) - Grade: $combined_grade"

	return 0
}

# Print health score summary
print_score_summary() {
	local domain="$1"

	print_header "Health Score for $domain"
	echo ""

	if [[ "$HEALTH_MAX" -eq 0 ]]; then
		print_warning "No checks were scored"
		return 0
	fi

	local percentage=$(((HEALTH_SCORE * 100) / HEALTH_MAX))
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

	echo "  Score: $HEALTH_SCORE / $HEALTH_MAX ($percentage%)"
	echo "  Grade: $grade"
	echo ""

	case "$grade" in
	"A")
		print_success "Excellent email health - all critical checks pass"
		;;
	"B")
		print_success "Good email health - minor improvements possible"
		;;
	"C")
		print_warning "Fair email health - some issues need attention"
		;;
	"D")
		print_warning "Poor email health - significant issues found"
		;;
	"F")
		print_error "Critical email health issues - immediate action needed"
		;;
	esac

	echo ""
	print_info "Score breakdown: SPF(2) + DKIM(2) + DMARC(3) + MX(1) + Blacklist(2)"
	print_info "  + BIMI(1) + MTA-STS(1) + TLS-RPT(1) + DANE(1) + rDNS(1) = 15 max"

	return 0
}

# Full health check using checkdmarc if available
check_full() {
	local domain="$1"

	print_header "Full Email Health Check for $domain"
	echo ""

	if check_checkdmarc; then
		print_info "Using checkdmarc for comprehensive analysis..."
		echo ""
		checkdmarc "$domain" 2>/dev/null || true
		echo ""
	fi

	# Reset score for full check
	HEALTH_SCORE=0
	HEALTH_MAX=0

	# Run individual checks for detailed output
	# Core checks (required)
	check_spf "$domain" || true
	check_dkim "$domain" || true
	check_dmarc "$domain" || true
	check_mx "$domain" || true
	check_blacklist "$domain" || true

	# Enhanced checks (recommended)
	check_bimi "$domain" || true
	check_mta_sts "$domain" || true
	check_tls_rpt "$domain" || true
	check_dane "$domain" || true
	check_reverse_dns "$domain" || true

	# Print score summary
	print_score_summary "$domain"

	print_header "Next Steps"
	print_info "For detailed deliverability testing, send a test email to mail-tester.com"
	print_info "For MX diagnostics: https://mxtoolbox.com/SuperTool.aspx?action=mx:$domain"
	print_info "For design rendering tests: email-test-suite-helper.sh test-design <html-file>"
	print_info "For inbox placement analysis: email-test-suite-helper.sh check-placement $domain"
	print_info "For email accessibility audit: $0 accessibility <html-file>"

	return 0
}

# Email accessibility check (delegates to accessibility-helper.sh)
check_email_accessibility() {
	local html_file="$1"

	print_header "Email Accessibility Check"

	if [[ ! -f "$html_file" ]]; then
		print_error "HTML file not found: $html_file"
		return 1
	fi

	local a11y_helper="${SCRIPT_DIR}/accessibility-helper.sh"
	if [[ -x "$a11y_helper" ]]; then
		"$a11y_helper" email "$html_file"
		local exit_code=$?

		print_header "Accessibility Next Steps"
		print_info "For contrast ratio checks: accessibility-helper.sh contrast '#fg' '#bg'"
		print_info "For design rendering tests: email-test-suite-helper.sh test-design $html_file"
		print_info "For full web accessibility audit: accessibility-helper.sh audit <url>"

		return $exit_code
	else
		print_error "accessibility-helper.sh not found at: $a11y_helper"
		print_info "Run email accessibility checks manually with: accessibility-helper.sh email $html_file"
		return 1
	fi
}

# Guide for mail-tester.com
mail_tester_guide() {
	print_header "Mail-Tester.com Guide"

	print_info "Mail-Tester provides comprehensive deliverability scoring (1-10)"
	echo ""
	echo "Steps:"
	echo "  1. Visit https://mail-tester.com"
	echo "  2. Copy the unique test email address shown"
	echo "  3. Send a test email from your domain to that address"
	echo "  4. Click 'Then check your score' on the website"
	echo "  5. Review the detailed report"
	echo ""
	print_info "Aim for a score of 9/10 or higher"
	echo ""
	echo "Common issues that reduce score:"
	echo "  - Missing or invalid SPF record"
	echo "  - Missing DKIM signature"
	echo "  - No DMARC policy"
	echo "  - Blacklisted IP"
	echo "  - Spam-like content"
	echo "  - Missing unsubscribe header"

	return 0
}

# Show help
show_help() {
	echo "Email Health Check Helper Script"
	echo "$USAGE_COMMAND_OPTIONS"
	echo ""
	echo "Infrastructure Commands (domain checks):"
	echo "  check [domain]              Full infrastructure health check with score"
	echo "  spf [domain]                Check SPF record only"
	echo "  dkim [domain] [selector]    Check DKIM record (optional: specific selector)"
	echo "  dmarc [domain]              Check DMARC record only"
	echo "  mx [domain]                 Check MX records only"
	echo "  blacklist [domain]          Check blacklist status"
	echo "  bimi [domain]               Check BIMI record (brand logo in inbox)"
	echo "  mta-sts [domain]            Check MTA-STS (TLS enforcement for inbound)"
	echo "  tls-rpt [domain]            Check TLS-RPT (TLS failure reporting)"
	echo "  dane [domain]               Check DANE/TLSA records"
	echo "  reverse-dns [domain]        Check reverse DNS for mail server"
	echo ""
	echo "Content Commands (HTML email file checks):"
	echo "  content-check [file]        Full content precheck with score (all below)"
	echo "  check-subject [file]        Check subject line quality"
	echo "  check-preheader [file]      Check preheader/preview text"
	echo "  check-accessibility [file]  Check email accessibility (alt text, lang, roles)"
	echo "  check-links [file]          Validate links (empty, placeholder, unsubscribe)"
	echo "  check-images [file]         Validate images (alt, dimensions, size, ratio)"
	echo "  check-spam-words [file]     Scan for spam trigger words"
	echo ""
	echo "Combined Commands:"
	echo "  precheck [domain] [file]    Full precheck: infrastructure + content"
	echo "  accessibility [html-file]   Check email HTML accessibility (WCAG 2.1)"
	echo ""
	echo "Other:"
	echo "  mail-tester                 Guide for using mail-tester.com"
	echo "  help                        $HELP_SHOW_MESSAGE"
	echo ""
	echo "Examples:"
	echo "  $0 check example.com                    # Infrastructure check"
	echo "  $0 content-check newsletter.html        # Content check"
	echo "  $0 precheck example.com newsletter.html # Combined check"
	echo "  $0 spf example.com"
	echo "  $0 dkim example.com google"
	echo "  $0 accessibility newsletter.html"
	echo "  $0 check-subject newsletter.html"
	echo "  $0 check-links campaign.html"
	echo ""
	echo "Infrastructure Score (out of 15):"
	echo "  SPF(2) + DKIM(2) + DMARC(3) + MX(1) + Blacklist(2)"
	echo "  + BIMI(1) + MTA-STS(1) + TLS-RPT(1) + DANE(1) + rDNS(1)"
	echo ""
	echo "Content Score (out of 10):"
	echo "  Subject(2) + Preheader(1) + Accessibility(2)"
	echo "  + Links(2) + Images(2) + Spam Words(1)"
	echo ""
	echo "Combined Score (out of 25):"
	echo "  Grade: A(90%+) B(80%+) C(70%+) D(60%+) F(<60%)"
	echo ""
	echo "Dependencies:"
	echo "  Required: dig (usually pre-installed), sed, grep"
	echo "  Optional: checkdmarc (pip install checkdmarc), curl (for MTA-STS)"
	echo ""
	echo "Common DKIM selectors by provider:"
	echo "  Google Workspace: google, google1, google2"
	echo "  Microsoft 365:    selector1, selector2"
	echo "  Mailchimp:        k1, k2, k3"
	echo "  SendGrid:         s1, s2, smtpapi"
	echo "  Postmark:         pm, pm2"
	echo ""
	echo "Related:"
	echo "  email-test-suite-helper.sh  Design rendering and delivery testing"
	echo "  accessibility-helper.sh     WCAG accessibility auditing (web + email)"

	return 0
}

# Dispatch infrastructure (domain) commands
_dispatch_infrastructure_cmd() {
	local command="$1"
	local arg2="$2"
	local arg3="$3"

	case "$command" in
	"check" | "full")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			echo "$HELP_USAGE_INFO"
			exit 1
		fi
		check_full "$arg2"
		;;
	"spf")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			exit 1
		fi
		check_spf "$arg2"
		;;
	"dkim")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			exit 1
		fi
		check_dkim "$arg2" "$arg3"
		;;
	"dmarc")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			exit 1
		fi
		check_dmarc "$arg2"
		;;
	"mx")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			exit 1
		fi
		check_mx "$arg2"
		;;
	"blacklist" | "bl")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			exit 1
		fi
		check_blacklist "$arg2"
		;;
	"bimi")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			exit 1
		fi
		check_bimi "$arg2"
		;;
	"mta-sts" | "mtasts")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			exit 1
		fi
		check_mta_sts "$arg2"
		;;
	"tls-rpt" | "tlsrpt")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			exit 1
		fi
		check_tls_rpt "$arg2"
		;;
	"dane" | "tlsa")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			exit 1
		fi
		check_dane "$arg2"
		;;
	"reverse-dns" | "rdns" | "ptr")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_DOMAIN_REQUIRED"
			exit 1
		fi
		check_reverse_dns "$arg2"
		;;
	*)
		return 1
		;;
	esac

	return 0
}

# Dispatch content (HTML file) commands
_dispatch_content_cmd() {
	local command="$1"
	local arg2="$2"

	case "$command" in
	"content-check" | "content")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_HTML_REQUIRED"
			echo "Usage: $0 content-check <html-file>"
			exit 1
		fi
		check_content "$arg2"
		;;
	"check-subject")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_HTML_REQUIRED"
			exit 1
		fi
		check_subject "$arg2"
		;;
	"check-preheader")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_HTML_REQUIRED"
			exit 1
		fi
		check_preheader "$arg2"
		;;
	"check-accessibility" | "check-a11y")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_HTML_REQUIRED"
			exit 1
		fi
		check_accessibility "$arg2"
		;;
	"check-links")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_HTML_REQUIRED"
			exit 1
		fi
		check_links "$arg2"
		;;
	"check-images" | "check-imgs")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_HTML_REQUIRED"
			exit 1
		fi
		check_images "$arg2"
		;;
	"check-spam-words" | "check-spam")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_HTML_REQUIRED"
			exit 1
		fi
		check_spam_words "$arg2"
		;;
	*)
		return 1
		;;
	esac

	return 0
}

# Dispatch combined, accessibility, and utility commands
_dispatch_combined_cmd() {
	local command="$1"
	local arg2="$2"
	local arg3="$3"

	case "$command" in
	"precheck")
		if [[ -z "$arg2" ]]; then
			print_error "Domain and HTML file required"
			echo "Usage: $0 precheck <domain> <html-file>"
			exit 1
		fi
		check_precheck "$arg2" "$arg3"
		;;
	"accessibility" | "a11y")
		if [[ -z "$arg2" ]]; then
			print_error "$_ERR_HTML_REQUIRED"
			echo "$HELP_USAGE_INFO"
			exit 1
		fi
		check_email_accessibility "$arg2"
		;;
	"mail-tester" | "mailtester")
		mail_tester_guide
		;;
	"help" | "-h" | "--help" | "")
		show_help
		;;
	*)
		# Assume first arg is domain if it looks like one (contains dot, no file extension)
		if [[ "$command" == *"."* && ! -f "$command" ]]; then
			check_full "$command"
		elif [[ -f "$command" ]]; then
			check_content "$command"
		else
			print_error "Unknown command: $command"
			echo "$HELP_USAGE_INFO"
			exit 1
		fi
		;;
	esac

	return 0
}
