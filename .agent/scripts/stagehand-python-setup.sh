#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Stagehand Python Setup Script for AI DevOps Framework
# Comprehensive setup and configuration for Stagehand Python AI browser automation

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/../../.agent/scripts/shared-constants.sh"

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Print functions
print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

# Stagehand Python configuration
readonly STAGEHAND_PYTHON_CONFIG_DIR="${HOME}/.aidevops/stagehand-python"
readonly STAGEHAND_PYTHON_EXAMPLES_DIR="${STAGEHAND_PYTHON_CONFIG_DIR}/examples"
readonly STAGEHAND_PYTHON_TEMPLATES_DIR="${STAGEHAND_PYTHON_CONFIG_DIR}/templates"

# Create advanced Python example scripts
create_python_examples() {
    print_info "Creating advanced Stagehand Python example scripts..."
    
    mkdir -p "$STAGEHAND_PYTHON_EXAMPLES_DIR"
    mkdir -p "$STAGEHAND_PYTHON_TEMPLATES_DIR"
    
    # Basic example with Pydantic
    cat > "${STAGEHAND_PYTHON_EXAMPLES_DIR}/basic_example.py" << 'EOF'
#!/usr/bin/env python3
"""
Basic Stagehand Python Example
Simple example demonstrating core Stagehand Python functionality
"""

import asyncio
import os
from dotenv import load_dotenv
from pydantic import BaseModel, Field

from stagehand import StagehandConfig, Stagehand

# Load environment variables
load_dotenv()

# Define Pydantic models for structured data extraction
class PageInfo(BaseModel):
    title: str = Field(..., description="Page title")
    heading: str = Field(..., description="Main heading text")
    description: str = Field(..., description="Page description or summary")

async def main():
    """Main function demonstrating basic Stagehand usage"""
    print("🤘 Testing Stagehand Python AI Browser Automation...")
    
    # Create configuration
    config = StagehandConfig(
        env="LOCAL",  # or "BROWSERBASE"
        api_key=os.getenv("BROWSERBASE_API_KEY"),
        project_id=os.getenv("BROWSERBASE_PROJECT_ID"),
        model_name="google/gemini-2.5-flash-preview-05-20",
        model_api_key=os.getenv("GOOGLE_API_KEY"),
        headless=False,
        verbose=1
    )
    
    stagehand = Stagehand(config)
    
    try:
        print("\nInitializing 🤘 Stagehand...")
        await stagehand.init()
        
        if stagehand.env == "BROWSERBASE":
            print(f"🌐 View your live browser: https://www.browserbase.com/sessions/{stagehand.session_id}")
        
        page = stagehand.page
        
        # Navigate to a test page
        await page.goto("https://example.com")
        print("✅ Successfully navigated to example.com")
        
        # Use natural language to interact
        await page.act("scroll down to see more content")
        print("✅ Performed scroll action")
        
        # Extract structured data
        page_info = await page.extract(
            "extract the page title, main heading, and description",
            schema=PageInfo
        )
        
        print(f"\n📊 Extracted Data:")
        print(f"Title: {page_info.title}")
        print(f"Heading: {page_info.heading}")
        print(f"Description: {page_info.description}")
        
        # Use observe to discover elements
        elements = await page.observe("find all clickable links")
        print(f"\n🔍 Observed Elements: {elements}")
        
        print("\n🎉 Stagehand Python test completed successfully!")
        
    except Exception as e:
        print(f"❌ Error: {str(e)}")
        raise
    finally:
        print("\nClosing 🤘 Stagehand...")
        await stagehand.close()

if __name__ == "__main__":
    asyncio.run(main())
EOF

    # E-commerce automation example
    cat > "${STAGEHAND_PYTHON_EXAMPLES_DIR}/ecommerce_automation.py" << 'EOF'
#!/usr/bin/env python3
"""
E-commerce Automation with Stagehand Python
Product research and price comparison automation
"""

import asyncio
import json
import os
from datetime import datetime
from typing import List
from dotenv import load_dotenv
from pydantic import BaseModel, Field

from stagehand import StagehandConfig, Stagehand

# Load environment variables
load_dotenv()

class Product(BaseModel):
    name: str = Field(..., description="Product name")
    price: float = Field(..., description="Price in USD")
    rating: float = Field(..., description="Star rating out of 5")
    review_count: int = Field(..., description="Number of reviews")
    availability: str = Field(..., description="Stock status")
    url: str = Field(None, description="Product URL")

class ProductResults(BaseModel):
    products: List[Product] = Field(..., description="List of products")
    search_query: str = Field(..., description="Search query used")
    timestamp: str = Field(..., description="Search timestamp")

async def search_products(query: str, max_results: int = 5) -> ProductResults:
    """Search for products and extract structured data"""
    
    config = StagehandConfig(
        env="LOCAL",
        model_name="google/gemini-2.5-flash-preview-05-20",
        model_api_key=os.getenv("GOOGLE_API_KEY"),
        headless=True,  # Run headless for automation
        verbose=1
    )
    
    stagehand = Stagehand(config)
    
    try:
        await stagehand.init()
        page = stagehand.page
        
        # Navigate to Amazon (example)
        await page.goto("https://amazon.com")
        
        # Search for products
        await page.act(f'search for "{query}"')
        
        # Wait for results to load
        await asyncio.sleep(3)
        
        # Extract product information
        products_data = await page.extract(
            f"extract the first {max_results} products with their details",
            schema=ProductResults
        )
        
        # Add metadata
        products_data.search_query = query
        products_data.timestamp = datetime.now().isoformat()
        
        # Save results
        results_dir = f"{os.path.expanduser('~')}/.aidevops/stagehand-python/results"
        os.makedirs(results_dir, exist_ok=True)
        
        filename = f"product-search-{query.replace(' ', '-')}-{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        filepath = os.path.join(results_dir, filename)
        
        with open(filepath, 'w') as f:
            json.dump(products_data.dict(), f, indent=2)
        
        print(f"Found {len(products_data.products)} products:")
        for i, product in enumerate(products_data.products, 1):
            print(f"{i}. {product.name} - ${product.price} ({product.rating}⭐)")
        
        print(f"Results saved to: {filepath}")
        return products_data
        
    except Exception as e:
        print(f"Error during product search: {e}")
        raise
    finally:
        await stagehand.close()

async def main():
    """Main function for product search"""
    import sys
    
    query = sys.argv[1] if len(sys.argv) > 1 else "wireless headphones"
    max_results = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    
    results = await search_products(query, max_results)
    print(f"\nProduct search completed for: {results.search_query}")

if __name__ == "__main__":
    asyncio.run(main())
EOF

    # Web scraping template
    cat > "${STAGEHAND_PYTHON_TEMPLATES_DIR}/web_scraping_template.py" << 'EOF'
#!/usr/bin/env python3
"""
Web Scraping Template with Stagehand Python
Adaptable template for various websites with structured data extraction
"""

import asyncio
import json
import os
from datetime import datetime
from typing import List, Optional
from dotenv import load_dotenv
from pydantic import BaseModel, Field

from stagehand import StagehandConfig, Stagehand

# Load environment variables
load_dotenv()

class ScrapedItem(BaseModel):
    title: str = Field(..., description="Item title")
    description: str = Field(..., description="Item description or content")
    url: Optional[str] = Field(None, description="Item URL")
    metadata: Optional[dict] = Field(None, description="Additional metadata")

class ScrapingResults(BaseModel):
    items: List[ScrapedItem] = Field(..., description="List of scraped items")
    source_url: str = Field(..., description="Source URL")
    extraction_prompt: str = Field(..., description="Extraction prompt used")
    timestamp: str = Field(..., description="Scraping timestamp")

async def scrape_website(url: str, extraction_prompt: str, max_items: int = 10) -> ScrapingResults:
    """Generic website scraping function"""
    
    config = StagehandConfig(
        env="LOCAL",
        model_name="google/gemini-2.5-flash-preview-05-20",
        model_api_key=os.getenv("GOOGLE_API_KEY"),
        headless=True,
        verbose=1
    )
    
    stagehand = Stagehand(config)
    
    try:
        await stagehand.init()
        page = stagehand.page
        
        print(f"Navigating to: {url}")
        await page.goto(url)
        
        # Wait for page to load
        await asyncio.sleep(3)
        
        # Handle cookie banners or popups
        try:
            await page.act("close any cookie banners or popups")
        except Exception:
            print("No popups to close")
        
        # Extract data based on the prompt
        results = await page.extract(
            extraction_prompt,
            schema=ScrapingResults
        )
        
        # Add metadata
        results.source_url = url
        results.extraction_prompt = extraction_prompt
        results.timestamp = datetime.now().isoformat()
        
        print(f"Extracted {len(results.items)} items:")
        for i, item in enumerate(results.items, 1):
            print(f"{i}. {item.title}")
            print(f"   {item.description[:100]}...")
        
        return results
        
    except Exception as e:
        print(f"Error during web scraping: {e}")
        raise
    finally:
        await stagehand.close()

async def main():
    """Main function for web scraping"""
    import sys
    
    url = sys.argv[1] if len(sys.argv) > 1 else "https://news.ycombinator.com"
    prompt = sys.argv[2] if len(sys.argv) > 2 else "extract the top stories with titles and descriptions"
    max_items = int(sys.argv[3]) if len(sys.argv) > 3 else 10
    
    results = await scrape_website(url, prompt, max_items)
    
    # Save results
    results_dir = f"{os.path.expanduser('~')}/.aidevops/stagehand-python/results"
    os.makedirs(results_dir, exist_ok=True)
    
    filename = f"scraping-results-{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    filepath = os.path.join(results_dir, filename)
    
    with open(filepath, 'w') as f:
        json.dump(results.dict(), f, indent=2)
    
    print(f"Results saved to: {filepath}")

if __name__ == "__main__":
    asyncio.run(main())
EOF

    print_success "Created advanced Stagehand Python examples"
    return 0
}

# Create requirements.txt for the project
create_requirements_file() {
    local requirements_file="${STAGEHAND_PYTHON_CONFIG_DIR}/requirements.txt"
    
    cat > "$requirements_file" << 'EOF'
# Stagehand Python AI Browser Automation
stagehand>=0.5.0

# Core dependencies
pydantic>=2.0.0
python-dotenv>=1.0.0
playwright>=1.40.0

# Optional dependencies for enhanced functionality
aiofiles>=23.0.0
httpx>=0.25.0
rich>=13.0.0

# Development dependencies (optional)
pytest>=7.0.0
pytest-asyncio>=0.21.0
black>=23.0.0
isort>=5.12.0
mypy>=1.5.0
EOF

    print_success "Created requirements.txt at: $requirements_file"
    return 0
}

# Main setup function
main() {
    local command="${1:-setup}"
    
    case "$command" in
        "setup")
            print_info "Setting up Stagehand Python advanced configuration..."
            create_python_examples
            create_requirements_file
            print_success "Stagehand Python advanced setup completed!"
            print_info "Next steps:"
            print_info "1. Run: bash .agent/scripts/stagehand-python-helper.sh install"
            print_info "2. Configure API keys in ~/.aidevops/stagehand-python/.env"
            print_info "3. Activate venv: source ~/.aidevops/stagehand-python/.venv/bin/activate"
            print_info "4. Try examples: cd ~/.aidevops/stagehand-python && python examples/basic_example.py" || exit
            ;;
        "examples")
            create_python_examples
            ;;
        "requirements")
            create_requirements_file
            ;;
        "help")
            cat << EOF
Stagehand Python Setup Script

USAGE:
    $0 [COMMAND]

COMMANDS:
    setup           Complete advanced setup (default)
    examples        Create example scripts only
    requirements    Create requirements.txt only
    help            Show this help

EOF
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            return 1
            ;;
    esac
    
    return 0
}

# Execute main function
main "$@"
