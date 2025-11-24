#!/bin/bash

# Web Hosting Verification Script
# Verifies local domain setup and provides detailed troubleshooting

# Source shared constants if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

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

print_info() {
    local message="$1"
    echo -e "${BLUE}[INFO]${NC} $message"
    return 0
}

print_success() {
    local message="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $message"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARNING]${NC} $message"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" >&2
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
    
    print_header "Verifying $domain Setup"
    
    local all_checks_passed=true
    
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
    local nginx_conf="$NGINX_CONF_DIR/route.$domain.conf"
    if [[ -f "$nginx_conf" ]]; then
        print_success "Nginx configuration exists"
        
        # Check port configuration
        local port
        port=$(grep "proxy_pass" "$nginx_conf" | head -1 | sed 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/')
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
        
        # Check certificate validity
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
    
    # Check 6: Development server (if hosts file is correct)
    if grep -q "$domain" /etc/hosts && [[ -n "$port" ]]; then
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
        https_response=$(curl -k -s -o /dev/null -w "%{http_code}" "https://$domain" 2>/dev/null || echo "000")
        if [[ "$https_response" == "200" ]]; then
            print_success "HTTPS connection successful (200)"
        else
            print_warning "HTTPS connection test failed (got $https_response)"
            if [[ "$https_response" == "000" ]]; then
                print_info "This may be normal if development server is not running"
            fi
        fi
    fi
    
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
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
