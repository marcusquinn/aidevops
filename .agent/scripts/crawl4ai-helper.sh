#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Crawl4AI Helper Script
# AI-powered web crawler and scraper for LLM-friendly data extraction
#
# This script provides comprehensive management for Crawl4AI including:
# - Docker deployment with monitoring dashboard
# - Python package installation and setup
# - MCP server integration for AI assistants
# - Web scraping and data extraction operations
# - CapSolver integration for CAPTCHA solving and anti-bot bypass
#
# Usage: ./crawl4ai-helper.sh [command] [options]
# Commands:
#   install         - Install Crawl4AI Python package
#   docker-setup    - Setup Docker deployment with monitoring
#   docker-start    - Start Docker container
#   docker-stop     - Stop Docker container
#   mcp-setup       - Setup MCP server integration
#   capsolver-setup - Setup CapSolver integration for CAPTCHA solving
#   crawl           - Perform web crawling operation
#   extract         - Extract structured data from URL
#   captcha-crawl   - Crawl with CAPTCHA solving capabilities
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

# Common constants
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
# Common constants
readonly CONTENT_TYPE_JSON=$CONTENT_TYPE_JSON

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
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
    return 0
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

# Setup CapSolver integration for CAPTCHA solving
capsolver_setup() {
    print_header "Setting up CapSolver Integration for CAPTCHA Solving"

    local capsolver_config="$CONFIG_DIR/capsolver-config.json"

    print_info "Creating CapSolver configuration..."
    cat > "$capsolver_config" << EOF
{
  "provider": "capsolver",
  "description": "CapSolver configuration for automated CAPTCHA solving with Crawl4AI",
  "service_type": "captcha_solver",
  "version": "latest",
  "api": {
    "base_url": "https://api.capsolver.com",
    "endpoints": {
      "create_task": "/createTask",
      "get_task_result": "/getTaskResult",
      "get_balance": "/getBalance"
    },
    "authentication": {
      "type": "api_key",
      "header": "clientKey"
    }
  },
  "supported_captcha_types": {
    "recaptcha_v2": {
      "type": "ReCaptchaV2TaskProxyLess",
      "description": "reCAPTCHA v2 checkbox solving",
      "response_field": "gRecaptchaResponse",
      "injection_target": "g-recaptcha-response",
      "pricing": "$0.5/1000 requests",
      "avg_solve_time": "< 9 seconds"
    },
    "recaptcha_v3": {
      "type": "ReCaptchaV3TaskProxyLess",
      "description": "reCAPTCHA v3 invisible solving with score ≥0.7",
      "response_field": "gRecaptchaResponse",
      "injection_method": "fetch_hook",
      "pricing": "$0.5/1000 requests",
      "avg_solve_time": "< 3 seconds"
    },
    "recaptcha_v2_enterprise": {
      "type": "ReCaptchaV2EnterpriseTaskProxyLess",
      "description": "reCAPTCHA v2 Enterprise solving",
      "response_field": "gRecaptchaResponse",
      "pricing": "$_arg1/1000 requests",
      "avg_solve_time": "< 9 seconds"
    },
    "recaptcha_v3_enterprise": {
      "type": "ReCaptchaV3EnterpriseTaskProxyLess",
      "description": "reCAPTCHA v3 Enterprise solving with score ≥0.9",
      "response_field": "gRecaptchaResponse",
      "pricing": "$_arg3/1000 requests",
      "avg_solve_time": "< 3 seconds"
    },
    "cloudflare_turnstile": {
      "type": "AntiTurnstileTaskProxyLess",
      "description": "Cloudflare Turnstile CAPTCHA solving",
      "response_field": "token",
      "injection_target": "cf-turnstile-response",
      "pricing": "$_arg3/1000 requests",
      "avg_solve_time": "< 3 seconds"
    },
    "cloudflare_challenge": {
      "type": "AntiCloudflareTask",
      "description": "Cloudflare Challenge (5s shield) solving",
      "response_field": "cookies",
      "requires_proxy": true,
      "pricing": "Contact for pricing",
      "avg_solve_time": "< 10 seconds"
    },
    "aws_waf": {
      "type": "AntiAwsWafTaskProxyLess",
      "description": "AWS WAF CAPTCHA solving",
      "response_field": "cookie",
      "injection_method": "cookie_set",
      "pricing": "Contact for pricing",
      "avg_solve_time": "< 5 seconds"
    },
    "geetest_v3": {
      "type": "GeeTestTaskProxyLess",
      "description": "GeeTest v3 CAPTCHA solving",
      "response_field": "challenge",
      "pricing": "$0.5/1000 requests",
      "avg_solve_time": "< 5 seconds"
    },
    "geetest_v4": {
      "type": "GeeTestV4TaskProxyLess",
      "description": "GeeTest v4 CAPTCHA solving",
      "response_field": "captcha_output",
      "pricing": "$0.5/1000 requests",
      "avg_solve_time": "< 5 seconds"
    },
    "image_to_text": {
      "type": "ImageToTextTask",
      "description": "OCR image CAPTCHA solving",
      "response_field": "text",
      "pricing": "$0.4/1000 requests",
      "avg_solve_time": "< 1 second"
    }
  },
  "integration_methods": {
    "api_integration": {
      "description": "Direct API integration with Python capsolver SDK",
      "advantages": ["More flexible", "Precise control", "Better error handling"],
      "recommended": true
    },
    "browser_extension": {
      "description": "CapSolver browser extension integration",
      "advantages": ["Easy setup", "Automatic detection", "No coding required"],
      "extension_url": "https://chrome.google.com/webstore/detail/capsolver/pgojnojmmhpofjgdmaebadhbocahppod"
    }
  },
  "python_sdk": {
    "installation": "pip install capsolver",
    "import": "import capsolver",
    "usage": "capsolver.api_key = 'CAP-xxxxxxxxxxxxxxxxxxxxx'"
  },
  "pricing": {
    "pay_per_usage": "Standard pricing per request",
    "package_discounts": "Up to 60% savings with packages",
    "developer_plan": "Contact for better pricing",
    "balance_check": "GET /getBalance endpoint"
  }
    return 0
}
EOF

    print_success "CapSolver configuration created at $capsolver_config"

    # Create Python example script
    local example_script="$CONFIG_DIR/capsolver-example.py"
    cat > "$example_script" << 'EOF'
#!/usr/bin/env python3
"""
CapSolver + Crawl4AI Integration Example
Demonstrates CAPTCHA solving with various types
"""

import asyncio
import capsolver
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig, CacheMode

# TODO: Set your CapSolver API key
# Get your API key from: https://dashboard.capsolver.com/dashboard/overview
CAPSOLVER_API_KEY = "CAP-xxxxxxxxxxxxxxxxxxxxx"
capsolver.api_key = CAPSOLVER_API_KEY

async def solve_recaptcha_v2_example():
    """Example: Solving reCAPTCHA v2 checkbox"""
    site_url = "https://recaptcha-demo.appspot.com/recaptcha-v2-checkbox.php"
    site_key = "6LfW6wATAAAAAHLqO2pb8bDBahxlMxNdo9g947u9"

    browser_config = BrowserConfig(
        verbose=True,
        headless=False,
        use_persistent_context=True,
    )

    async with AsyncWebCrawler(config=browser_config) as crawler:
        # Initial page load
        await crawler.arun(
            url=site_url,
            cache_mode=CacheMode.BYPASS,
            session_id="captcha_session"
        )

        # Solve CAPTCHA using CapSolver
        print("🔄 Solving reCAPTCHA v2...")
        solution = capsolver.solve({
            "type": "ReCaptchaV2TaskProxyLess",
            "websiteURL": site_url,
            "websiteKey": site_key,
        })
        token = solution["gRecaptchaResponse"]
        print(f"✅ Token obtained: {token[:50]}...")

        # Inject token and submit
        js_code = f"""
            const textarea = document.getElementById('g-recaptcha-response');
            if (textarea) {{
                textarea.value = '{token}';
                document.querySelector('button.form-field[type="submit"]').click();
            }}
        """

        wait_condition = """() => {
            const items = document.querySelectorAll('h2');
            return items.length > 1;
        }"""

        run_config = CrawlerRunConfig(
            cache_mode=CacheMode.BYPASS,
            session_id="captcha_session",
            js_code=js_code,
            js_only=True,
            wait_for=f"js:{wait_condition}"
        )

        result = await crawler.arun(url=site_url, config=run_config)
        print("🎉 CAPTCHA solved successfully!")
        return result.markdown

async def solve_cloudflare_turnstile_example():
    """Example: Solving Cloudflare Turnstile"""
    site_url = "https://clifford.io/demo/cloudflare-turnstile"
    site_key = "0x4AAAAAAAGlwMzq_9z6S9Mh"

    browser_config = BrowserConfig(
        verbose=True,
        headless=False,
        use_persistent_context=True,
    )

    async with AsyncWebCrawler(config=browser_config) as crawler:
        # Initial page load
        await crawler.arun(
            url=site_url,
            cache_mode=CacheMode.BYPASS,
            session_id="turnstile_session"
        )

        # Solve Turnstile using CapSolver
        print("🔄 Solving Cloudflare Turnstile...")
        solution = capsolver.solve({
            "type": "AntiTurnstileTaskProxyLess",
            "websiteURL": site_url,
            "websiteKey": site_key,
        })
        token = solution["token"]
        print(f"✅ Token obtained: {token[:50]}...")

        # Inject token and submit
        js_code = f"""
            document.querySelector('input[name="cf-turnstile-response"]').value = '{token}';
            document.querySelector('button[type="submit"]').click();
        """

        wait_condition = """() => {
            const items = document.querySelectorAll('h1');
            return items.length === 0;
        }"""

        run_config = CrawlerRunConfig(
            cache_mode=CacheMode.BYPASS,
            session_id="turnstile_session",
            js_code=js_code,
            js_only=True,
            wait_for=f"js:{wait_condition}"
        )

        result = await crawler.arun(url=site_url, config=run_config)
        print("🎉 Turnstile solved successfully!")
        return result.markdown

async def main():
    """Main function to run examples"""
    print("🚀 CapSolver + Crawl4AI Integration Examples")
    print("=" * 50)

    try:
        # Example 1: reCAPTCHA v2
        print("\n📋 Example 1: reCAPTCHA v2")
        result1 = await solve_recaptcha_v2_example()

        # Example 2: Cloudflare Turnstile
        print("\n📋 Example 2: Cloudflare Turnstile")
        result2 = await solve_cloudflare_turnstile_example()

        print("\n✅ All examples completed successfully!")

    except Exception as e:
        print(f"❌ Error: {e}")
        print("💡 Make sure to set your CapSolver API key!")

if __name__ == "__main__":
    asyncio.run(main())
EOF

    chmod +x "$example_script"
    print_success "Python example script created at $example_script"

    print_info "CapSolver Integration Setup Complete!"
    print_info ""
    print_info "📋 Next Steps:"
    print_info "1. Get API key: https://dashboard.capsolver.com/dashboard/overview"
    print_info "2. Install Python SDK: pip install capsolver"
    print_info "3. Set API key in example script: $example_script"
    print_info "4. Run example: python3 $example_script"
    print_info ""
    print_info "📚 Supported CAPTCHA Types:"
    print_info "• reCAPTCHA v2/v3 (including Enterprise)"
    print_info "• Cloudflare Turnstile & Challenge"
    print_info "• AWS WAF"
    print_info "• GeeTest v3/v4"
    print_info "• Image-to-Text OCR"
    print_info ""
    print_info "💰 Pricing: Starting from $0.4/1000 requests"
    print_info "🔗 Documentation: https://docs.capsolver.com/"

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
    return 0
}
EOF
)

    print_info "Sending crawl request..."
    local response
    if response=$(curl -s -X POST "$api_url" \
        -H $CONTENT_TYPE_JSON \
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
    return 0
}
EOF
)

    print_info "Sending extraction request..."
    local response
    if response=$(curl -s -X POST "$api_url" \
        -H $CONTENT_TYPE_JSON \
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

# Crawl with CAPTCHA solving capabilities
captcha_crawl() {
    local url="$1"
    local captcha_type="$2"
    local site_key="$3"
    local output_file="$4"

    if [[ -z "$url" || -z "$captcha_type" ]]; then
        print_error "URL and CAPTCHA type are required"
        print_info "Usage: captcha-crawl <url> <captcha_type> [site_key] [output_file]"
        print_info "CAPTCHA types: recaptcha_v2, recaptcha_v3, turnstile, aws_waf"
        return 1
    fi

    print_header "Crawling with CAPTCHA Solving: $url"
    print_info "CAPTCHA Type: $captcha_type"

    # Check if Docker container is running
    if ! docker ps -q -f name="$DOCKER_CONTAINER" | grep -q .; then
        print_warning "Docker container is not running. Starting it..."
        if ! docker_start; then
            return 1
        fi
        sleep 5
    fi

    # Create Python script for CAPTCHA crawling
    local temp_script="/tmp/captcha_crawl_$$.py"
    cat > "$temp_script" << EOF
#!/usr/bin/env python3
import asyncio
import capsolver
import os
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig, CacheMode

# Get CapSolver API key from environment
api_key = os.getenv('CAPSOLVER_API_KEY')
if not api_key:
    print("❌ Error: CAPSOLVER_API_KEY environment variable not set")
    print("💡 Set it with: export CAPSOLVER_API_KEY='CAP-xxxxxxxxxxxxxxxxxxxxx'")
    exit(1)

capsolver.api_key = api_key

async def crawl_with_captcha():
    url = "$url"
    captcha_type = "$captcha_type"
    site_key = "$site_key"

    browser_config = BrowserConfig(
        verbose=True,
        headless=False,
        use_persistent_context=True,
    )

    async with AsyncWebCrawler(config=browser_config) as crawler:
        # Initial page load
        print(f"🔄 Loading page: {url}")
        await crawler.arun(
            url=url,
            cache_mode=CacheMode.BYPASS,
            session_id="captcha_crawl_session"
        )

        # Solve CAPTCHA based on type
        if captcha_type == "recaptcha_v2":
            if not site_key:
                print("❌ Error: site_key required for reCAPTCHA v2")
                return

            print("🔄 Solving reCAPTCHA v2...")
            solution = capsolver.solve({
                "type": "ReCaptchaV2TaskProxyLess",
                "websiteURL": url,
                "websiteKey": site_key,
            })
            token = solution["gRecaptchaResponse"]

            js_code = f'''
                const textarea = document.getElementById('g-recaptcha-response');
                if (textarea) {{
                    textarea.value = '{token}';
                    console.log('✅ reCAPTCHA v2 token injected');
                }}
            '''

        elif captcha_type == "recaptcha_v3":
            if not site_key:
                print("❌ Error: site_key required for reCAPTCHA v3")
                return

            print("🔄 Solving reCAPTCHA v3...")
            solution = capsolver.solve({
                "type": "ReCaptchaV3TaskProxyLess",
                "websiteURL": url,
                "websiteKey": site_key,
                "pageAction": "submit",
            })
            token = solution["gRecaptchaResponse"]

            js_code = f'''
                const originalFetch = window.fetch;
                window.fetch = function(...args) {{
                    if (typeof args[0] === 'string' && args[0].includes('recaptcha')) {{
                        console.log('🔄 Hooking reCAPTCHA v3 request');
                        // Replace token in request
                    }}
                    return originalFetch.apply(this, args);
                }};
                console.log('✅ reCAPTCHA v3 hook installed');
            '''

        elif captcha_type == "turnstile":
            if not site_key:
                print("❌ Error: site_key required for Cloudflare Turnstile")
                return

            print("🔄 Solving Cloudflare Turnstile...")
            solution = capsolver.solve({
                "type": "AntiTurnstileTaskProxyLess",
                "websiteURL": url,
                "websiteKey": site_key,
            })
            token = solution["token"]

            js_code = f'''
                const input = document.querySelector('input[name="cf-turnstile-response"]');
                if (input) {{
                    input.value = '{token}';
                    console.log('✅ Turnstile token injected');
                }}
            '''

        elif captcha_type == "aws_waf":
            print("🔄 Solving AWS WAF...")
            solution = capsolver.solve({
                "type": "AntiAwsWafTaskProxyLess",
                "websiteURL": url,
            })
            cookie = solution["cookie"]

            js_code = f'''
                document.cookie = 'aws-waf-token={cookie};path=/';
                console.log('✅ AWS WAF cookie set');
                location.reload();
            '''

        else:
            print(f"❌ Error: Unsupported CAPTCHA type: {captcha_type}")
            return

        # Execute JavaScript and continue crawling
        run_config = CrawlerRunConfig(
            cache_mode=CacheMode.BYPASS,
            session_id="captcha_crawl_session",
            js_code=js_code,
            js_only=True,
        )

        result = await crawler.arun(url=url, config=run_config)
        print("🎉 CAPTCHA solved and page crawled successfully!")

        return result.markdown

if __name__ == "__main__":
    result = asyncio.run(crawl_with_captcha())
    if result:
        print("📄 Crawled content:")
        print(result[:500] + "..." if len(result) > 500 else result)
EOF

    # Check if CapSolver API key is set
    if [[ -z "$CAPSOLVER_API_KEY" ]]; then
        print_error "CAPSOLVER_API_KEY environment variable not set"
        print_info "Set it with: export CAPSOLVER_API_KEY='CAP-xxxxxxxxxxxxxxxxxxxxx'"
        print_info "Get your API key from: https://dashboard.capsolver.com/dashboard/overview"
        rm -f "$temp_script"
        return 1
    fi

    print_info "Running CAPTCHA-enabled crawl..."
    if python3 "$temp_script"; then
        print_success "CAPTCHA crawl completed successfully"
        if [[ -n "$output_file" ]]; then
            python3 "$temp_script" > "$output_file" 2>&1
            print_info "Results saved to: $output_file"
        fi
    else
        print_error "CAPTCHA crawl failed"
        rm -f "$temp_script"
        return 1
    fi

    rm -f "$temp_script"
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
    echo "  capsolver-setup            - Setup CapSolver CAPTCHA solving integration"
    echo "  crawl [url] [format] [file] - Crawl URL and extract content"
    echo "  extract [url] [schema] [file] - Extract structured data"
    echo "  captcha-crawl [url] [type] [key] [file] - Crawl with CAPTCHA solving"
    echo "  status                     - Check Crawl4AI service status"
    echo "  help                       - $HELP_SHOW_MESSAGE"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 docker-setup"
    echo "  $0 docker-start"
    echo "  $0 crawl https://example.com markdown output.json"
    echo "  $0 extract https://example.com '{\"title\":\"h1\"}' data.json"
    echo "  $0 captcha-crawl https://example.com recaptcha_v2 6LfW6wATAAAAAHLqO2pb8bDBahxlMxNdo9g947u9"
    echo "  $0 status"
    echo ""
    echo "Documentation:"
    echo "  GitHub: https://github.com/unclecode/crawl4ai"
    echo "  Docs: https://docs.crawl4ai.com/"
    echo "  Framework docs: .agent/CRAWL4AI.md"
    return 0
}

# Main function
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local param2="$2"
    local param3="$3"
    local param4="$4"
    local param5="$5"

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
        "capsolver-setup")
            capsolver_setup
            ;;
        "crawl")
            crawl_url "$param2" "$param3" "$param4"
            ;;
        "extract")
            extract_structured "$param2" "$param3" "$param4"
            ;;
        "captcha-crawl")
            captcha_crawl "$param2" "$param3" "$param4" "$param5"
            ;;
        "status")
            check_status
            ;;
        "help"|"-h"|"--help"|"")
            show_help
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            show_help
            return 1
            ;;
    esac
    return 0
}

main "$@"

exit 0
