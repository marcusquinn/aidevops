#!/bin/bash

# Web Hosting Helper Script
# Manages .local domains for web applications in ~/Git
# Compatible with LocalWP and standalone nginx setups

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
CONFIG_FILE="../configs/webhosting-config.json"

print_header() {
    echo -e "${PURPLE}================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}================================${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if LocalWP is available
check_localwp() {
    if [[ -d "/Applications/Local.app" ]] || [[ -d "$HOME/Applications/Local.app" ]]; then
        if [[ -d "$NGINX_CONF_DIR" ]]; then
            print_success "LocalWP nginx router detected - using existing setup"
            return 0
        else
            print_warning "LocalWP found but nginx router not running"
            return 1
        fi
    else
        print_info "LocalWP not found - standalone mode"
        return 1
    fi
}

# Detect web application type and default port
detect_webapp_type() {
    local project_dir="$1"
    
    if [[ -f "$project_dir/package.json" ]]; then
        if grep -q "next" "$project_dir/package.json"; then
            echo "nextjs:3000"
        elif grep -q "react" "$project_dir/package.json"; then
            echo "react:3000"
        elif grep -q "vue" "$project_dir/package.json"; then
            echo "vue:3000"
        elif grep -q "nuxt" "$project_dir/package.json"; then
            echo "nuxt:3000"
        elif grep -q "svelte" "$project_dir/package.json"; then
            echo "svelte:5173"
        elif grep -q "vite" "$project_dir/package.json"; then
            echo "vite:5173"
        else
            echo "node:3000"
        fi
    elif [[ -f "$project_dir/Gemfile" ]]; then
        echo "rails:3000"
    elif [[ -f "$project_dir/requirements.txt" ]] || [[ -f "$project_dir/pyproject.toml" ]]; then
        echo "python:8000"
    elif [[ -f "$project_dir/Cargo.toml" ]]; then
        echo "rust:8000"
    elif [[ -f "$project_dir/go.mod" ]]; then
        echo "go:8080"
    elif [[ -f "$project_dir/composer.json" ]]; then
        echo "php:8000"
    else
        echo "unknown:3000"
    fi
}

# Generate SSL certificate
generate_ssl_cert() {
    local domain="$1"
    
    print_info "Generating SSL certificate for $domain..."
    mkdir -p "$CERT_DIR"
    
    if [[ -f "$CERT_DIR/$domain.crt" ]]; then
        print_warning "SSL certificate already exists for $domain"
        return 0
    fi
    
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$CERT_DIR/$domain.key" \
        -out "$CERT_DIR/$domain.crt" \
        -days 365 -nodes \
        -subj "/C=US/ST=Local/L=Local/O=Local Development/CN=$domain" \
        2>/dev/null
    
    print_success "SSL certificate generated for $domain"
}

# Create nginx configuration for LocalWP router
create_localwp_nginx_config() {
    local domain="$1"
    local port="$2"
    local webapp_type="$3"
    
    print_info "Creating LocalWP nginx configuration for $domain..."
    
    local nginx_conf="$NGINX_CONF_DIR/route.$domain.conf"
    
    if [[ -f "$nginx_conf" ]]; then
        print_warning "Nginx configuration exists, backing up..."
        cp "$nginx_conf" "$nginx_conf.backup.$(date +%s)"
    fi
    
    # Create nginx configuration based on webapp type
    cat > "$nginx_conf" << EOF
# Local Development Site: $domain ($webapp_type)
server {
    listen 80;
    server_name $domain;
    
    # Redirect HTTP to HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name $domain;
    
    # SSL Configuration
    ssl_certificate "$CERT_DIR/$domain.crt";
    ssl_certificate_key "$CERT_DIR/$domain.key";
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # Proxy to local development server
    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }
EOF

    # Add framework-specific configurations
    case "$webapp_type" in
        "nextjs"|"react"|"vue"|"nuxt")
            cat >> "$nginx_conf" << EOF
    
    # Handle WebSocket connections for hot reload
    location /_next/webpack-hmr {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
EOF
            ;;
        "vite"|"svelte")
            cat >> "$nginx_conf" << EOF
    
    # Handle Vite HMR WebSocket
    location /vite-dev-server {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
EOF
            ;;
    esac
    
    echo "}" >> "$nginx_conf"
    
    print_success "LocalWP nginx configuration created for $domain"
}

# Add domain to hosts file
add_to_hosts() {
    local domain="$1"

    if grep -q "$domain" /etc/hosts; then
        print_warning "Domain $domain already exists in hosts file"
        return 0
    fi

    print_info "Adding $domain to /etc/hosts (requires sudo)..."
    echo "127.0.0.1 $domain" | sudo tee -a /etc/hosts > /dev/null
    print_success "Domain added to hosts file"
}

# Reload nginx
reload_nginx() {
    print_info "Reloading nginx configuration..."

    local nginx_pid=$(pgrep -f "nginx.*router" | head -1)
    if [[ -n "$nginx_pid" ]]; then
        kill -HUP "$nginx_pid"
        print_success "Nginx configuration reloaded"
    else
        print_warning "Nginx router not running - configuration will be loaded when it starts"
    fi
}

# Setup a new local domain
setup_domain() {
    local project_name="$1"
    local port="$2"

    if [[ -z "$project_name" ]]; then
        print_error "Project name is required"
        exit 1
    fi

    local project_dir="$GIT_DIR/$project_name"
    local domain="$project_name.local"

    if [[ ! -d "$project_dir" ]]; then
        print_error "Project directory does not exist: $project_dir"
        exit 1
    fi

    print_header "Setting up $domain"

    # Detect webapp type and default port if not specified
    local webapp_info=$(detect_webapp_type "$project_dir")
    local webapp_type="${webapp_info%:*}"
    local default_port="${webapp_info#*:}"

    # Use provided port or default
    port="${port:-$default_port}"

    print_info "Detected: $webapp_type application"
    print_info "Using port: $port"

    # Generate SSL certificate
    generate_ssl_cert "$domain"

    # Check if LocalWP is available and create appropriate config
    if check_localwp; then
        create_localwp_nginx_config "$domain" "$port" "$webapp_type"
        reload_nginx
    else
        print_warning "LocalWP not available - manual nginx setup required"
        print_info "See documentation for standalone nginx setup"
    fi

    # Add to hosts file
    add_to_hosts "$domain"

    print_success "Local domain setup complete!"
    echo ""
    echo -e "${GREEN}✅ Domain configured: https://$domain${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  CRITICAL STEP REQUIRED:${NC}"
    echo -e "${RED}The domain is NOT yet accessible because it's missing from /etc/hosts${NC}"
    echo ""
    echo -e "${BLUE}📝 Complete these steps to finish setup:${NC}"
    echo ""
    echo -e "${YELLOW}1. Add domain to hosts file (REQUIRED):${NC}"
    echo "   echo \"127.0.0.1 $domain\" | sudo tee -a /etc/hosts"
    echo ""
    echo -e "${YELLOW}2. Start your development server on port $port:${NC}"
    echo "   cd ~/Git/$project_name"
    echo "   PORT=$port npm run dev  # or pnpm dev, yarn dev"
    echo ""
    echo -e "${YELLOW}3. Visit https://$domain in your browser${NC}"
    echo ""
    echo -e "${YELLOW}4. Handle SSL certificate warning:${NC}"
    echo "   Browser will show: \"Your connection is not private\""
    echo "   Click: \"Proceed to $domain (unsafe)\""
    echo ""
    echo -e "${GREEN}5. Verify success:${NC}"
    echo "   - HTTP redirect: http://$domain → https://$domain"
    echo "   - HTTPS access: https://$domain shows your app"
    echo ""
}

# List configured domains
list_domains() {
    print_header "Configured Local Domains"

    if check_localwp; then
        local found_domains=false

        for conf_file in "$NGINX_CONF_DIR"/route.*.local.conf; do
            if [[ -f "$conf_file" ]]; then
                local domain=$(basename "$conf_file" | sed 's/route\.\(.*\)\.conf/\1/')
                local port=$(grep "proxy_pass" "$conf_file" | head -1 | sed 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/')
                local status="❌ Not running"

                # Check if port is in use
                if lsof -i ":$port" >/dev/null 2>&1; then
                    status="✅ Running"
                fi

                echo -e "${BLUE}🌐 https://$domain${NC} → Port $port $status"
                found_domains=true
            fi
        done

        if [[ "$found_domains" == false ]]; then
            print_warning "No local domains configured"
        fi
    else
        print_warning "LocalWP not available - cannot list domains"
    fi
}

# Remove a domain
remove_domain() {
    local project_name="$1"

    if [[ -z "$project_name" ]]; then
        print_error "Project name is required"
        exit 1
    fi

    local domain="$project_name.local"

    print_header "Removing $domain"

    if check_localwp; then
        local nginx_conf="$NGINX_CONF_DIR/route.$domain.conf"

        # Remove nginx configuration
        if [[ -f "$nginx_conf" ]]; then
            rm "$nginx_conf"
            print_success "Nginx configuration removed"
            reload_nginx
        else
            print_warning "Nginx configuration not found"
        fi
    fi

    # Remove SSL certificates
    if [[ -f "$CERT_DIR/$domain.crt" ]]; then
        rm "$CERT_DIR/$domain.crt" "$CERT_DIR/$domain.key"
        print_success "SSL certificates removed"
    else
        print_warning "SSL certificates not found"
    fi

    # Remove from hosts file (requires manual intervention due to sudo)
    if grep -q "$domain" /etc/hosts; then
        print_warning "Please manually remove '$domain' from /etc/hosts"
        print_info "Run: sudo sed -i '' '/$domain/d' /etc/hosts"
    fi

    print_success "Domain removal complete!"
}

# Show help
show_help() {
    echo "Web Hosting Helper - Local Domain Management"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  setup <project-name> [port]  Setup local domain for project"
    echo "  list                         List all configured domains"
    echo "  remove <project-name>        Remove local domain configuration"
    echo "  help                         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 setup myapp 3000"
    echo "  $0 setup webapp-source 3001"
    echo "  $0 list"
    echo "  $0 remove myapp"
    echo ""
    echo "Supported frameworks:"
    echo "  - Next.js, React, Vue, Nuxt (port 3000)"
    echo "  - Vite, Svelte (port 5173)"
    echo "  - Rails (port 3000)"
    echo "  - Python/Django (port 8000)"
    echo "  - Go (port 8080)"
    echo "  - PHP (port 8000)"
    echo ""
    echo "Requirements:"
    echo "  - LocalWP (recommended) or standalone nginx"
    echo "  - OpenSSL for certificate generation"
    echo "  - sudo access for hosts file modification"
    echo ""
}

# Main script logic
case "${1:-help}" in
    "setup")
        setup_domain "$2" "$3"
        ;;
    "list")
        list_domains
        ;;
    "remove")
        remove_domain "$2"
        ;;
    "help"|*)
        show_help
        ;;
esac
