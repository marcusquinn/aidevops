#!/bin/bash

# Crawl4AI Examples Script
# Demonstrates various Crawl4AI usage patterns for AI assistants
#
# This script provides practical examples of using Crawl4AI for:
# - Basic web crawling and content extraction
# - Structured data extraction with CSS selectors
# - Batch processing multiple URLs
# - Content analysis workflows
#
# Usage: ./crawl4ai-examples.sh [example]
# Examples:
#   basic-crawl     - Basic web crawling example
#   structured      - Structured data extraction
#   batch-process   - Batch processing multiple URLs
#   content-analysis - Complete content analysis workflow
#   all             - Run all examples
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
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly FRAMEWORK_ROOT="$SCRIPT_DIR/../.."
readonly CRAWL4AI_HELPER="$FRAMEWORK_ROOT/providers/crawl4ai-helper.sh"
readonly OUTPUT_DIR="$HOME/.agent/tmp/crawl4ai-examples"

# Print functions
print_success() {
    echo -e "${GREEN}✅ $1${NC}"
    return 0
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
    return 0
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
    return 0
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
    return 0
}

print_header() {
    echo -e "${PURPLE}🚀 $1${NC}"
    return 0
}

# Setup output directory
setup_output_dir() {
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
        print_success "Created output directory: $OUTPUT_DIR"
    fi
    return 0
}

# Check if Crawl4AI is available
check_crawl4ai() {
    if [[ ! -f "$CRAWL4AI_HELPER" ]]; then
        print_error "Crawl4AI helper script not found at $CRAWL4AI_HELPER"
        return 1
    fi
    
    # Check if Docker container is running
    if ! docker ps -q -f name="crawl4ai" | grep -q .; then
        print_warning "Crawl4AI Docker container is not running"
        print_info "Starting Docker container..."
        if ! "$CRAWL4AI_HELPER" docker-start; then
            print_error "Failed to start Crawl4AI Docker container"
            return 1
        fi
        sleep 5  # Wait for container to be ready
    fi
    
    return 0
}

# Example 1: Basic web crawling
example_basic_crawl() {
    print_header "Example 1: Basic Web Crawling"
    
    local url="https://httpbin.org/html"
    local output_file="$OUTPUT_DIR/basic-crawl.json"
    
    print_info "Crawling: $url"
    if "$CRAWL4AI_HELPER" crawl "$url" markdown "$output_file"; then
        print_success "Basic crawl completed"
        print_info "Output saved to: $output_file"
        
        # Show markdown content
        if command -v jq &> /dev/null; then
            local markdown_content
            markdown_content=$(jq -r '.results[0].markdown' "$output_file" 2>/dev/null)
            if [[ -n "$markdown_content" && "$markdown_content" != "null" ]]; then
                print_info "Extracted markdown (first 200 chars):"
                echo "${markdown_content:0:200}..."
            fi
        fi
    else
        print_error "Basic crawl failed"
        return 1
    fi
    
    return 0
}

# Example 2: Structured data extraction
example_structured_extraction() {
    print_header "Example 2: Structured Data Extraction"
    
    local url="https://httpbin.org/html"
    local schema='{"title": "h1", "content": "p", "links": {"selector": "a", "type": "attribute", "attribute": "href"}}'
    local output_file="$OUTPUT_DIR/structured-extraction.json"
    
    print_info "Extracting structured data from: $url"
    print_info "Schema: $schema"
    
    if "$CRAWL4AI_HELPER" extract "$url" "$schema" "$output_file"; then
        print_success "Structured extraction completed"
        print_info "Output saved to: $output_file"
        
        # Show extracted data
        if command -v jq &> /dev/null; then
            local extracted_content
            extracted_content=$(jq -r '.results[0].extracted_content' "$output_file" 2>/dev/null)
            if [[ -n "$extracted_content" && "$extracted_content" != "null" ]]; then
                print_info "Extracted data:"
                echo "$extracted_content" | jq '.' 2>/dev/null || echo "$extracted_content"
            fi
        fi
    else
        print_error "Structured extraction failed"
        return 1
    fi
    
    return 0
}

# Example 3: Batch processing
example_batch_processing() {
    print_header "Example 3: Batch Processing Multiple URLs"
    
    local urls=(
        "https://httpbin.org/html"
        "https://httpbin.org/json"
        "https://httpbin.org/xml"
    )
    
    print_info "Processing ${#urls[@]} URLs..."
    
    local i=1
    for url in "${urls[@]}"; do
        local output_file="$OUTPUT_DIR/batch-$i.json"
        print_info "[$i/${#urls[@]}] Processing: $url"
        
        if "$CRAWL4AI_HELPER" crawl "$url" markdown "$output_file"; then
            print_success "Processed: $url"
        else
            print_warning "Failed to process: $url"
        fi
        
        ((i++))
        sleep 1  # Rate limiting
    done
    
    print_success "Batch processing completed"
    return 0
}

# Example 4: Content analysis workflow
example_content_analysis() {
    print_header "Example 4: Complete Content Analysis Workflow"
    
    local url="https://httpbin.org/html"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    
    # Step 1: Basic crawl
    print_info "Step 1: Basic content crawl"
    local raw_output="$OUTPUT_DIR/analysis-raw-$timestamp.json"
    if ! "$CRAWL4AI_HELPER" crawl "$url" markdown "$raw_output"; then
        print_error "Failed to crawl content"
        return 1
    fi
    
    # Step 2: Structured extraction
    print_info "Step 2: Structured data extraction"
    local structured_schema='{"title": "h1", "headings": "h2, h3", "paragraphs": "p", "links": {"selector": "a", "type": "attribute", "attribute": "href"}}'
    local structured_output="$OUTPUT_DIR/analysis-structured-$timestamp.json"
    if ! "$CRAWL4AI_HELPER" extract "$url" "$structured_schema" "$structured_output"; then
        print_error "Failed to extract structured data"
        return 1
    fi
    
    # Step 3: Analysis summary
    print_info "Step 3: Generating analysis summary"
    local summary_file="$OUTPUT_DIR/analysis-summary-$timestamp.txt"
    
    cat > "$summary_file" << EOF
Content Analysis Summary
========================
Timestamp: $(date)
URL: $url

Files Generated:
- Raw content: $raw_output
- Structured data: $structured_output

Analysis Complete!
EOF
    
    print_success "Content analysis workflow completed"
    print_info "Summary saved to: $summary_file"
    
    return 0
}

# Show help
show_help() {
    echo "Crawl4AI Examples Script"
    echo "Usage: $0 [example]"
    echo ""
    echo "Examples:"
    echo "  basic-crawl      - Basic web crawling example"
    echo "  structured       - Structured data extraction"
    echo "  batch-process    - Batch processing multiple URLs"
    echo "  content-analysis - Complete content analysis workflow"
    echo "  all              - Run all examples"
    echo "  help             - Show this help message"
    echo ""
    echo "Output Directory: $OUTPUT_DIR"
    echo ""
    echo "Prerequisites:"
    echo "  - Crawl4AI Docker container running"
    echo "  - Internet connection for test URLs"
    echo ""
    echo "To start Crawl4AI:"
    echo "  $CRAWL4AI_HELPER docker-start"
    return 0
}

# Main function
main() {
    local example="${1:-help}"
    
    # Setup
    setup_output_dir
    
    case "$example" in
        "basic-crawl")
            if check_crawl4ai; then
                example_basic_crawl
            fi
            ;;
        "structured")
            if check_crawl4ai; then
                example_structured_extraction
            fi
            ;;
        "batch-process")
            if check_crawl4ai; then
                example_batch_processing
            fi
            ;;
        "content-analysis")
            if check_crawl4ai; then
                example_content_analysis
            fi
            ;;
        "all")
            if check_crawl4ai; then
                example_basic_crawl
                echo ""
                example_structured_extraction
                echo ""
                example_batch_processing
                echo ""
                example_content_analysis
            fi
            ;;
        "help"|"-h"|"--help"|"")
            show_help
            ;;
        *)
            print_error "Unknown example: $example"
            show_help
            return 1
            ;;
    esac
    return 0
}

main "$@"

exit 0
