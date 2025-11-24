#!/bin/bash

# Crawl4AI Helper Script
# AI-powered web crawler and scraper for LLM-friendly data extraction
#
# This script provides comprehensive management for Crawl4AI including:
# - Docker deployment with monitoring dashboard
# - Python package installation and setup
# - MCP server integration for AI assistants
# - Web scraping and data extraction operations
#
# Usage: ./crawl4ai-helper.sh [command] [options]
# Commands:
#   install         - Install Crawl4AI Python package
#   docker-setup    - Setup Docker deployment with monitoring
#   docker-start    - Start Docker container
#   docker-stop     - Stop Docker container
#   mcp-setup       - Setup MCP server integration
#   crawl           - Perform web crawling operation
#   extract         - Extract structured data from URL
#   status          - Check Crawl4AI service status
#   help            - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

# Constants
readonly SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_DIR="$SCRIPT_DIR/../configs"
readonly DOCKER_IMAGE="unclecode/crawl4ai:latest"
readonly DOCKER_CONTAINER="crawl4ai"
readonly DOCKER_PORT="11235"
readonly MCP_PORT="3009"
readonly HELP_SHOW_MESSAGE="Show this help message"

# Print functions
print_success() {
    local message="$1"
    echo -e "${GREEN}✅ $message${NC}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}ℹ️  $message${NC}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠️  $message${NC}"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}❌ $message${NC}"
    return 0
}

print_header() {
    local message="$1"
    echo -e "${PURPLE}🚀 $message${NC}"
    return 0
}

# Check if Docker is available
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install Docker first."
        return 1
    fi
    
    if ! docker info &> /dev/null; then
        print_error "Docker daemon is not running. Please start Docker."
        return 1
    fi
    
    return 0
}

# Check if Python is available
check_python() {
    if ! command -v python3 &> /dev/null; then
        print_error "Python 3 is not installed. Please install Python 3.8+ first."
        return 1
    fi
    
    local python_version
    python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    
    if [[ $(echo "$python_version < 3.8" | bc -l) -eq 1 ]]; then
        print_error "Python 3.8+ is required. Current version: $python_version"
        return 1
    fi
    
    return 0
}

# Install Crawl4AI Python package
install_crawl4ai() {
    print_header "Installing Crawl4AI Python Package"
    
    if ! check_python; then
        return 1
    fi
    
    print_info "Installing Crawl4AI with pip..."
    if pip3 install -U crawl4ai; then
        print_success "Crawl4AI installed successfully"
    else
        print_error "Failed to install Crawl4AI"
        return 1
    fi
    
    print_info "Running post-installation setup..."
    if crawl4ai-setup; then
        print_success "Crawl4AI setup completed"
    else
        print_warning "Setup completed with warnings. Run 'crawl4ai-doctor' to check."
    fi
    
    print_info "Verifying installation..."
    if crawl4ai-doctor; then
        print_success "Crawl4AI installation verified"
    else
        print_warning "Installation verification completed with warnings"
    fi
    
    return 0
}

# Setup Docker deployment
docker_setup() {
    print_header "Setting up Crawl4AI Docker Deployment"
    
    if ! check_docker; then
        return 1
    fi
    
    print_info "Pulling Crawl4AI Docker image..."
    if docker pull "$DOCKER_IMAGE"; then
        print_success "Docker image pulled successfully"
    else
        print_error "Failed to pull Docker image"
        return 1
    fi
    
    # Create environment file if it doesn't exist
    local env_file="$CONFIG_DIR/.crawl4ai.env"
    if [[ ! -f "$env_file" ]]; then
        print_info "Creating environment configuration..."
        cat > "$env_file" << 'EOF'
# Crawl4AI Environment Configuration
# Add your API keys here for LLM integration

# OpenAI
# OPENAI_API_KEY=sk-your-key

# Anthropic
# ANTHROPIC_API_KEY=your-anthropic-key

# Other providers
# DEEPSEEK_API_KEY=your-deepseek-key
# GROQ_API_KEY=your-groq-key
# TOGETHER_API_KEY=your-together-key
# MISTRAL_API_KEY=your-mistral-key
# GEMINI_API_TOKEN=your-gemini-token

# Global LLM settings
# LLM_PROVIDER=openai/gpt-4o-mini
# LLM_TEMPERATURE=0.7
EOF
        print_success "Environment file created at $env_file"
        print_warning "Please edit $env_file to add your API keys"
    fi
    
    return 0
}

# Start Docker container
docker_start() {
    print_header "Starting Crawl4AI Docker Container"
    
    if ! check_docker; then
        return 1
    fi
    
    # Stop existing container if running
    if docker ps -q -f name="$DOCKER_CONTAINER" | grep -q .; then
        print_info "Stopping existing container..."
        docker stop "$DOCKER_CONTAINER" > /dev/null 2>&1
        docker rm "$DOCKER_CONTAINER" > /dev/null 2>&1
    fi
    
    local env_file="$CONFIG_DIR/.crawl4ai.env"
    local docker_args=(
        "-d"
        "-p" "$DOCKER_PORT:$DOCKER_PORT"
        "--name" "$DOCKER_CONTAINER"
        "--shm-size=1g"
    )
    
    if [[ -f "$env_file" ]]; then
        docker_args+=("--env-file" "$env_file")
    fi
    
    docker_args+=("$DOCKER_IMAGE")
    
    print_info "Starting Docker container..."
    if docker run "${docker_args[@]}"; then
        print_success "Crawl4AI container started successfully"
        print_info "Dashboard: http://localhost:$DOCKER_PORT/dashboard"
        print_info "Playground: http://localhost:$DOCKER_PORT/playground"
        print_info "API: http://localhost:$DOCKER_PORT"
    else
        print_error "Failed to start Docker container"
        return 1
    fi
    
    return 0
}

# Stop Docker container
docker_stop() {
    print_header "Stopping Crawl4AI Docker Container"

    if ! check_docker; then
        return 1
    fi

    if docker ps -q -f name="$DOCKER_CONTAINER" | grep -q .; then
        print_info "Stopping container..."
        if docker stop "$DOCKER_CONTAINER" && docker rm "$DOCKER_CONTAINER"; then
            print_success "Container stopped and removed"
        else
            print_error "Failed to stop container"
            return 1
        fi
    else
        print_warning "Container is not running"
    fi

    return 0
}

# Setup MCP server integration
mcp_setup() {
    print_header "Setting up Crawl4AI MCP Server Integration"

    local mcp_config="$CONFIG_DIR/crawl4ai-mcp-config.json"

    print_info "Creating MCP server configuration..."
    cat > "$mcp_config" << EOF
{
  "provider": "crawl4ai",
  "description": "Crawl4AI MCP server for AI-powered web crawling and data extraction",
  "mcp_server": {
    "name": "crawl4ai",
    "command": "npx",
    "args": ["crawl4ai-mcp-server@latest"],
    "port": $MCP_PORT,
    "transport": "stdio",
    "description": "Crawl4AI MCP server for web scraping and LLM-friendly data extraction",
    "env": {
      "CRAWL4AI_API_URL": "http://localhost:$DOCKER_PORT",
      "CRAWL4AI_TIMEOUT": "60"
    }
  },
  "capabilities": [
    "web_crawling",
    "markdown_generation",
    "structured_extraction",
    "llm_extraction",
    "screenshot_capture",
    "pdf_generation",
    "javascript_execution"
  ]
}
EOF

    print_success "MCP configuration created at $mcp_config"
    print_info "To use with Claude Desktop, add this to your MCP settings:"
    print_info "  \"crawl4ai\": {"
    print_info "    \"command\": \"npx\","
    print_info "    \"args\": [\"crawl4ai-mcp-server@latest\"]"
    print_info "  }"

    return 0
}

# Perform web crawling operation
crawl_url() {
    local url="$1"
    local output_file="$3"

    if [[ -z "$url" ]]; then
        print_error "URL is required"
        return 1
    fi

    print_header "Crawling URL: $url"

    # Check if Docker container is running
    if ! docker ps -q -f name="$DOCKER_CONTAINER" | grep -q .; then
        print_warning "Docker container is not running. Starting it..."
        if ! docker_start; then
            return 1
        fi
        sleep 5  # Wait for container to be ready
    fi

    local api_url="http://localhost:$DOCKER_PORT/crawl"
    local payload
    payload=$(cat << EOF
{
  "urls": ["$url"],
  "crawler_config": {
    "type": "CrawlerRunConfig",
    "params": {
      "cache_mode": "bypass"
    }
  }
}
EOF
)

    print_info "Sending crawl request..."
    local response
    if response=$(curl -s -X POST "$api_url" \
        -H "Content-Type: application/json" \
        -d "$payload"); then

        if [[ -n "$output_file" ]]; then
            echo "$response" > "$output_file"
            print_success "Results saved to $output_file"
        else
            echo "$response" | jq '.'
        fi

        print_success "Crawl completed successfully"
    else
        print_error "Failed to crawl URL"
        return 1
    fi

    return 0
}

# Extract structured data
extract_structured() {
    local url="$1"
    local schema="$2"
    local output_file="$3"

    if [[ -z "$url" || -z "$schema" ]]; then
        print_error "URL and schema are required"
        return 1
    fi

    print_header "Extracting structured data from: $url"

    # Check if Docker container is running
    if ! docker ps -q -f name="$DOCKER_CONTAINER" | grep -q .; then
        print_warning "Docker container is not running. Starting it..."
        if ! docker_start; then
            return 1
        fi
        sleep 5
    fi

    local api_url="http://localhost:$DOCKER_PORT/crawl"
    local payload
    payload=$(cat << EOF
{
  "urls": ["$url"],
  "crawler_config": {
    "type": "CrawlerRunConfig",
    "params": {
      "extraction_strategy": {
        "type": "JsonCssExtractionStrategy",
        "params": {
          "schema": {
            "type": "dict",
            "value": $schema
          }
        }
      },
      "cache_mode": "bypass"
    }
  }
}
EOF
)

    print_info "Sending extraction request..."
    local response
    if response=$(curl -s -X POST "$api_url" \
        -H "Content-Type: application/json" \
        -d "$payload"); then

        if [[ -n "$output_file" ]]; then
            echo "$response" > "$output_file"
            print_success "Results saved to $output_file"
        else
            echo "$response" | jq '.results[0].extracted_content'
        fi

        print_success "Extraction completed successfully"
    else
        print_error "Failed to extract data"
        return 1
    fi

    return 0
}

# Check service status
check_status() {
    print_header "Checking Crawl4AI Service Status"

    # Check Python package
    if command -v crawl4ai-doctor &> /dev/null; then
        print_info "Python package: Installed"
        if crawl4ai-doctor &> /dev/null; then
            print_success "Python package: Working"
        else
            print_warning "Python package: Issues detected"
        fi
    else
        print_warning "Python package: Not installed"
    fi

    # Check Docker container
    if check_docker; then
        if docker ps -q -f name="$DOCKER_CONTAINER" | grep -q .; then
            print_success "Docker container: Running"

            # Check API health
            local health_url="http://localhost:$DOCKER_PORT/health"
            if curl -s "$health_url" &> /dev/null; then
                print_success "API endpoint: Healthy"
                print_info "Dashboard: http://localhost:$DOCKER_PORT/dashboard"
                print_info "Playground: http://localhost:$DOCKER_PORT/playground"
            else
                print_warning "API endpoint: Not responding"
            fi
        else
            print_warning "Docker container: Not running"
        fi
    else
        print_warning "Docker: Not available"
    fi

    # Check MCP configuration
    local mcp_config="$CONFIG_DIR/crawl4ai-mcp-config.json"
    if [[ -f "$mcp_config" ]]; then
        print_success "MCP configuration: Available"
    else
        print_warning "MCP configuration: Not setup"
    fi

    return 0
}

# Show help
show_help() {
    echo "Crawl4AI Helper Script"
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install                     - Install Crawl4AI Python package"
    echo "  docker-setup               - Setup Docker deployment with monitoring"
    echo "  docker-start               - Start Docker container"
    echo "  docker-stop                - Stop Docker container"
    echo "  mcp-setup                  - Setup MCP server integration"
    echo "  crawl [url] [format] [file] - Crawl URL and extract content"
    echo "  extract [url] [schema] [file] - Extract structured data"
    echo "  status                     - Check Crawl4AI service status"
    echo "  help                       - $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 docker-setup"
    echo "  $0 docker-start"
    echo "  $0 crawl https://example.com markdown output.json"
    echo "  $0 extract https://example.com '{\"title\":\"h1\"}' data.json"
    echo "  $0 status"
    echo ""
    echo "Documentation:"
    echo "  GitHub: https://github.com/unclecode/crawl4ai"
    echo "  Docs: https://docs.crawl4ai.com/"
    echo "  Framework docs: docs/CRAWL4AI.md"
    return 0
}

# Main function
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local param2="$2"
    local param3="$3"
    local param4="$4"

    # Main command handler
    case "$command" in
        "install")
            install_crawl4ai
            ;;
        "docker-setup")
            docker_setup
            ;;
        "docker-start")
            docker_start
            ;;
        "docker-stop")
            docker_stop
            ;;
        "mcp-setup")
            mcp_setup
            ;;
        "crawl")
            crawl_url "$param2" "$param3" "$param4"
            ;;
        "extract")
            extract_structured "$param2" "$param3" "$param4"
            ;;
        "status")
            check_status
            ;;
        "help"|"-h"|"--help"|"")
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

exit 0
