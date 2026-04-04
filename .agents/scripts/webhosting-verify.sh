#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Web Hosting Verification Script
# Verifies local domain setup and provides detailed troubleshooting

# Source shared constants if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# Configuration
CERT_DIR="$HOME/.localhost-setup/certs"
NGINX_CONF_DIR="/Users/$(whoami)/Library/Application Support/Local/run/router/nginx/conf"
GIT_DIR="$HOME/Git"

print_header() {
	local message="$1"
	echo -e "${PURPLE}================================${NC}"
	echo -e "${PURPLE}$message${NC}"
	echo -e "${PURPLE}================================${NC}"
	return 0
}

# Checks 1-5: verify static infrastructure (directory, hosts, nginx, SSL, router)
# Args: domain project_dir nginx_conf
# Outputs: "port=<N>" on stdout; "all_checks_passed=false" if any check fails
_verify_basic_setup() {
	local domain="$1"
	local project_dir="$2"
	local nginx_conf="$3"

	local all_checks_passed=true
	local port=""

	# Check 1: Project directory exists
	echo -e "${BLUE}1. Checking project directory...${NC}"
	if [[ -d "$project_dir" ]]; then
		print_success "Project directory exists: $project_dir"
	else
		print_error "Project directory not found: $project_dir"
		all_checks_passed=false
	fi

	# Check 2: Hosts file entry
	echo -e "${BLUE}2. Checking hosts file...${NC}"
	if grep -q "$domain" /etc/hosts; then
		print_success "Domain found in /etc/hosts"
	else
		print_error "Domain NOT found in /etc/hosts"
		print_warning "Fix: echo \"127.0.0.1 $domain\" | sudo tee -a /etc/hosts"
		all_checks_passed=false
	fi

	# Check 3: Nginx configuration
	echo -e "${BLUE}3. Checking nginx configuration...${NC}"
	if [[ -f "$nginx_conf" ]]; then
		print_success "Nginx configuration exists"
		port=$(grep "proxy_pass" "$nginx_conf" 2>/dev/null | head -1 | sed 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/' || true)
		if [[ -n "$port" ]]; then
			print_info "Configured port: $port"
		else
			print_warning "Could not determine configured port"
		fi
	else
		print_error "Nginx configuration missing: $nginx_conf"
		all_checks_passed=false
	fi

	# Check 4: SSL certificates
	echo -e "${BLUE}4. Checking SSL certificates...${NC}"
	if [[ -f "$CERT_DIR/$domain.crt" && -f "$CERT_DIR/$domain.key" ]]; then
		print_success "SSL certificates exist"
		local cert_info
		if cert_info=$(openssl x509 -in "$CERT_DIR/$domain.crt" -noout -dates 2>/dev/null); then
			print_info "Certificate info: $cert_info"
		fi
	else
		print_error "SSL certificates missing"
		all_checks_passed=false
	fi

	# Check 5: LocalWP nginx router
	echo -e "${BLUE}5. Checking nginx router...${NC}"
	if pgrep -f "nginx.*router" >/dev/null; then
		print_success "Nginx router is running"
	else
		print_error "Nginx router not running"
		print_warning "Start LocalWP application or check nginx status"
		all_checks_passed=false
	fi

	printf 'port=%s\nall_checks_passed=%s\n' "$port" "$all_checks_passed"
	return 0
}

# Checks 6-9: verify live connectivity (dev server, DNS, HTTP redirect, HTTPS)
# Args: domain project_dir port
# Outputs: "all_checks_passed=false" if any check fails
_verify_connectivity() {
	local domain="$1"
	local project_dir="$2"
	local port="$3"

	local all_checks_passed=true

	# Check 6: Development server
	echo -e "${BLUE}6. Checking development server...${NC}"
	if lsof -i ":$port" >/dev/null 2>&1; then
		print_success "Development server running on port $port"
	else
		print_warning "No service running on port $port"
		print_info "Start with: cd $project_dir && PORT=$port npm run dev"
	fi

	# Check 7: DNS resolution
	echo -e "${BLUE}7. Testing DNS resolution...${NC}"
	if ping -c 1 "$domain" >/dev/null 2>&1; then
		print_success "Domain resolves to localhost"
	else
		print_error "Domain resolution failed"
		all_checks_passed=false
	fi

	# Check 8: HTTP redirect
	echo -e "${BLUE}8. Testing HTTP redirect...${NC}"
	local http_response
	# NOSONAR - Testing HTTP to HTTPS redirect behavior requires HTTP request
	http_response=$(curl -s -o /dev/null -w "%{http_code}" "http://$domain" 2>/dev/null || echo "000")
	if [[ "$http_response" == "301" ]]; then
		print_success "HTTP redirects to HTTPS (301)"
	else
		print_warning "HTTP redirect test failed (got $http_response)"
		if [[ "$http_response" == "000" ]]; then
			print_info "This may be normal if development server is not running"
		fi
	fi

	# Check 9: HTTPS connection
	echo -e "${BLUE}9. Testing HTTPS connection...${NC}"
	local https_response
	https_response=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "https://$domain" 2>/dev/null || echo "000")
	if [[ "$https_response" == "200" ]]; then
		print_success "HTTPS connection successful with valid SSL (200)"
	elif [[ "$https_response" == "000" ]]; then
		print_warning "HTTPS connection failed - SSL certificate may be invalid or self-signed"
		print_info "This may be normal for local development environments"
	else
		print_warning "HTTPS connection test failed (got $https_response)"
	fi

	printf 'all_checks_passed=%s\n' "$all_checks_passed"
	return 0
}

# Print final summary after all checks
# Args: all_checks_passed domain project_dir port project_name
_verify_summary() {
	local all_checks_passed="$1"
	local domain="$2"
	local project_dir="$3"
	local port="$4"
	local project_name="$5"

	echo ""
	if [[ "$all_checks_passed" == true ]]; then
		print_success "All critical checks passed!"
		echo ""
		echo -e "${GREEN}✅ Domain is ready: https://$domain${NC}"
		echo ""
		echo -e "${BLUE}Next steps:${NC}"
		echo "1. Start development server: cd $project_dir && PORT=$port npm run dev"
		echo "2. Visit: https://$domain"
		echo "3. Accept SSL certificate warning in browser"
	else
		print_error "Some checks failed - see messages above for fixes"
		echo ""
		echo -e "${YELLOW}Common fixes:${NC}"
		echo "• Add to hosts: echo \"127.0.0.1 $domain\" | sudo tee -a /etc/hosts"
		echo "• Setup domain: ./webhosting-helper.sh setup $project_name"
		echo "• Start LocalWP application"
	fi
	return 0
}

# Verify domain setup
verify_domain() {
	local project_name="$1"

	if [[ -z "$project_name" ]]; then
		print_error "Project name is required"
		exit 1
	fi

	local domain="$project_name.local"
	local project_dir="$GIT_DIR/$project_name"
	local nginx_conf="$NGINX_CONF_DIR/route.$domain.conf"

	print_header "Verifying $domain Setup"

	# Checks 1-5: static infrastructure
	local basic_out
	basic_out=$(_verify_basic_setup "$domain" "$project_dir" "$nginx_conf")
	local port=""
	local all_checks_passed=true
	while IFS='=' read -r key val; do
		case "$key" in
		port) port="$val" ;;
		all_checks_passed) all_checks_passed="$val" ;;
		esac
	done <<EOF
$basic_out
EOF

	# Checks 6-9: live connectivity (only if hosts entry and port are known)
	if grep -q "$domain" /etc/hosts && [[ -n "$port" ]]; then
		local conn_out
		conn_out=$(_verify_connectivity "$domain" "$project_dir" "$port")
		local conn_passed
		conn_passed=$(printf '%s\n' "$conn_out" | grep '^all_checks_passed=' | cut -d= -f2)
		if [[ "$conn_passed" == "false" ]]; then
			all_checks_passed=false
		fi
	fi

	_verify_summary "$all_checks_passed" "$domain" "$project_dir" "$port" "$project_name"
	return 0
}

# Show help
show_help() {
	echo "Web Hosting Verification Script"
	echo ""
	echo "Usage: $0 [command] [options]"
	echo ""
	echo "Commands:"
	echo "  verify <project-name>    Verify local domain setup"
	echo "  help                     Show this help message"
	echo ""
	echo "Examples:"
	echo "  $0 verify myapp"
	echo "  $0 verify turbostarter-source"
	echo ""
	return 0
}

# Main script logic
main() {
	local command="${1:-help}"
	local project_name="$2"

	case "$command" in
	"verify")
		verify_domain "$project_name"
		;;
	"help" | *)
		show_help
		;;
	esac
	return 0
}

main "$@"
