#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Stagehand Setup Script for AI DevOps Framework
# Comprehensive setup and configuration for Stagehand AI browser automation

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

# Stagehand configuration
readonly STAGEHAND_CONFIG_DIR="${HOME}/.aidevops/stagehand"
readonly STAGEHAND_EXAMPLES_DIR="${STAGEHAND_CONFIG_DIR}/examples"
readonly STAGEHAND_TEMPLATES_DIR="${STAGEHAND_CONFIG_DIR}/templates"

# Create advanced example scripts
create_advanced_examples() {
    print_info "Creating advanced Stagehand example scripts..."
    
    mkdir -p "$STAGEHAND_EXAMPLES_DIR"
    mkdir -p "$STAGEHAND_TEMPLATES_DIR"
    
    # E-commerce automation example
    cat > "${STAGEHAND_EXAMPLES_DIR}/ecommerce-automation.js" << 'EOF'
// E-commerce Automation with Stagehand
// Product research and price comparison

import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";
import fs from 'fs';

const ProductSchema = z.object({
    name: z.string().describe("Product name"),
    price: z.number().describe("Price in USD"),
    rating: z.number().describe("Star rating out of 5"),
    reviewCount: z.number().describe("Number of reviews"),
    availability: z.string().describe("Stock status"),
    imageUrl: z.string().optional().describe("Product image URL")
});

async function searchProducts(query, maxResults = 5) {
    const stagehand = new Stagehand({
        env: "LOCAL",
        verbose: 1,
        headless: false
    });

    try {
        await stagehand.init();
        
        // Navigate to Amazon (example)
        await stagehand.page.goto("https://amazon.com");
        
        // Search for products
        await stagehand.act(`search for "${query}"`);
        
        // Wait for results to load
        await stagehand.page.waitForTimeout(2000);
        
        // Extract product information
        const products = await stagehand.extract(
            `extract the first ${maxResults} products with their details`,
            z.array(ProductSchema)
        );
        
        // Save results to file
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const filename = `product-search-${query.replace(/\s+/g, '-')}-${timestamp}.json`;
        const filepath = `${process.env.HOME}/.aidevops/stagehand/results/${filename}`;
        
        // Ensure results directory exists
        fs.mkdirSync(`${process.env.HOME}/.aidevops/stagehand/results`, { recursive: true });
        fs.writeFileSync(filepath, JSON.stringify(products, null, 2));
        
        console.log(`Found ${products.length} products:`);
        products.forEach((product, index) => {
            console.log(`${index + 1}. ${product.name} - $${product.price} (${product.rating}⭐)`);
        });
        
        console.log(`Results saved to: ${filepath}`);
        return products;
        
    } catch (error) {
        console.error("Error during product search:", error);
        throw error;
    } finally {
        await stagehand.close();
    }
    return 0
}

// Example usage
if (import.meta.url === `file://${process.argv[1]}`) {
    const query = process.argv[2] || "wireless headphones";
    const maxResults = parseInt(process.argv[3]) || 5;
    
    searchProducts(query, maxResults)
        .then(() => console.log("Product search completed"))
        .catch(console.error);
}

export { searchProducts };
EOF

    # Social media automation example
    cat > "${STAGEHAND_EXAMPLES_DIR}/social-media-automation.js" << 'EOF'
// Social Media Automation with Stagehand
// Ethical LinkedIn engagement automation

import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

const PostSchema = z.object({
    author: z.string().describe("Post author name"),
    content: z.string().describe("Post content preview"),
    engagement: z.object({
        likes: z.number().describe("Number of likes"),
        comments: z.number().describe("Number of comments"),
        shares: z.number().describe("Number of shares")
    }).describe("Engagement metrics"),
    timestamp: z.string().describe("When the post was published")
});

async function analyzeLinkedInFeed(maxPosts = 10) {
    const stagehand = new Stagehand({
        env: "LOCAL",
        verbose: 1,
        headless: false
    });

    try {
        await stagehand.init();
        
        // Navigate to LinkedIn feed
        console.log("Navigating to LinkedIn feed...");
        await stagehand.page.goto("https://linkedin.com/feed");
        
        // Wait for login if needed
        const currentUrl = stagehand.page.url();
        if (currentUrl.includes('login') || currentUrl.includes('authwall')) {
            console.log("Please log in to LinkedIn manually, then press Enter to continue...");
            await new Promise(resolve => {
                process.stdin.once('data', () => resolve());
            });
        }
        
        // Scroll to load more posts
        console.log("Loading posts...");
        for (let i = 0; i < 3; i++) {
            await stagehand.act("scroll down to load more posts");
            await stagehand.page.waitForTimeout(2000);
        }
        
        // Analyze posts
        const posts = await stagehand.extract(
            `analyze the first ${maxPosts} posts in the feed`,
            z.array(PostSchema)
        );
        
        console.log(`Analyzed ${posts.length} posts:`);
        posts.forEach((post, index) => {
            console.log(`\n${index + 1}. ${post.author}`);
            console.log(`   Content: ${post.content.substring(0, 100)}...`);
            console.log(`   Engagement: ${post.engagement.likes} likes, ${post.engagement.comments} comments`);
        });
        
        // Find posts about AI/technology for engagement
        const techPosts = posts.filter(post => 
            post.content.toLowerCase().includes('ai') ||
            post.content.toLowerCase().includes('technology') ||
            post.content.toLowerCase().includes('software')
        );
        
        if (techPosts.length > 0) {
            console.log(`\nFound ${techPosts.length} tech-related posts for potential engagement`);
            
            // Ethical engagement - like one relevant post
            await stagehand.act("like the first post about AI or technology");
            console.log("Engaged with one relevant post");
        }
        
        return posts;
        
    } catch (error) {
        console.error("Error during LinkedIn analysis:", error);
        throw error;
    } finally {
        await stagehand.close();
    }
}

// Example usage
if (import.meta.url === `file://${process.argv[1]}`) {
    const maxPosts = parseInt(process.argv[2]) || 10;
    
    analyzeLinkedInFeed(maxPosts)
        .then(() => console.log("LinkedIn analysis completed"))
        .catch(console.error);
}

export { analyzeLinkedInFeed };
EOF

    # Web scraping template
    cat > "${STAGEHAND_TEMPLATES_DIR}/web-scraping-template.js" << 'EOF'
// Web Scraping Template with Stagehand
// Adaptable template for various websites

import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

// Define your data schema here
const DataSchema = z.object({
    title: z.string().describe("Page or item title"),
    description: z.string().describe("Description or content"),
    url: z.string().describe("Source URL"),
    metadata: z.object({
        author: z.string().optional(),
        date: z.string().optional(),
        category: z.string().optional()
    }).optional()
});

async function scrapeWebsite(url, extractionPrompt, maxItems = 10) {
    const stagehand = new Stagehand({
        env: "LOCAL",
        verbose: 1,
        headless: true // Set to false for debugging
    });

    try {
        await stagehand.init();
        
        console.log(`Navigating to: ${url}`);
        await stagehand.page.goto(url);
        
        // Wait for page to load
        await stagehand.page.waitForTimeout(3000);
        
        // Handle cookie banners or popups
        try {
            await stagehand.act("close any cookie banners or popups", { timeout: 5000 });
        } catch (error) {
            console.log("No popups to close");
        }
        
        // Extract data based on the prompt
        const data = await stagehand.extract(
            extractionPrompt,
            z.array(DataSchema).max(maxItems)
        );
        
        console.log(`Extracted ${data.length} items:`);
        data.forEach((item, index) => {
            console.log(`${index + 1}. ${item.title}`);
            console.log(`   ${item.description.substring(0, 100)}...`);
        });
        
        return data;
        
    } catch (error) {
        console.error("Error during web scraping:", error);
        throw error;
    } finally {
        await stagehand.close();
    }
}

// Example usage
if (import.meta.url === `file://${process.argv[1]}`) {
    const url = process.argv[2] || "https://news.ycombinator.com";
    const prompt = process.argv[3] || "extract the top stories with titles and descriptions";
    const maxItems = parseInt(process.argv[4]) || 10;
    
    scrapeWebsite(url, prompt, maxItems)
        .then(() => console.log("Web scraping completed"))
        .catch(console.error);
}

export { scrapeWebsite };
EOF

    print_success "Created advanced Stagehand examples"
    return 0
}

# Create package.json template
create_package_template() {
    local package_file="${STAGEHAND_TEMPLATES_DIR}/package.json"
    
    cat > "$package_file" << 'EOF'
{
  "name": "stagehand-automation-project",
  "version": "1.0.0",
  "description": "AI-powered browser automation with Stagehand",
  "type": "module",
  "main": "index.js",
  "scripts": {
    "start": "node index.js",
    "search-products": "node examples/ecommerce-automation.js",
    "analyze-linkedin": "node examples/social-media-automation.js",
    "scrape-website": "node templates/web-scraping-template.js",
    "test": "echo \"Error: no test specified\" && exit 1"
  },
  "dependencies": {
    "@browserbasehq/stagehand": "^3.0.0",
    "zod": "^3.22.0",
    "dotenv": "^16.3.0"
  },
  "devDependencies": {
    "@types/node": "^20.0.0"
  },
  "keywords": [
    "browser-automation",
    "ai",
    "web-scraping",
    "stagehand"
  ],
  "author": "AI DevOps Framework",
  "license": "MIT"
    return 0
}
EOF

    print_success "Created package.json template"
    return 0
}

# Setup MCP integration for Stagehand
setup_mcp_integration() {
    print_info "Setting up Stagehand MCP integration..."
    
    # Create MCP configuration for Stagehand
    local mcp_config="${HOME}/.aidevops/mcp/stagehand-config.json"
    mkdir -p "$(dirname "$mcp_config")"
    
    cat > "$mcp_config" << 'EOF'
{
  "mcpServers": {
    "stagehand": {
      "command": "node",
      "args": [
        "-e",
        "const { Stagehand } = require('@browserbasehq/stagehand'); console.log('Stagehand MCP Server Ready');"
      ],
      "env": {
        "STAGEHAND_ENV": "LOCAL",
        "STAGEHAND_VERBOSE": "1"
      }
    }
  }
    return 0
}
EOF

    print_success "Created Stagehand MCP configuration"
    return 0
}

# Main setup function
main() {
    local command="${1:-setup}"
    
    case "$command" in
        "setup")
            print_info "Setting up Stagehand advanced configuration..."
            create_advanced_examples
            create_package_template
            setup_mcp_integration
            print_success "Stagehand advanced setup completed!"
            print_info "Next steps:"
            print_info "1. Run: bash .agent/scripts/stagehand-helper.sh install"
            print_info "2. Configure API keys in ~/.aidevops/stagehand/.env"
            print_info "3. Try examples: cd ~/.aidevops/stagehand && npm run search-products" || exit
            ;;
        "examples")
            create_advanced_examples
            ;;
        "mcp")
            setup_mcp_integration
            ;;
        "help")
            cat << EOF
Stagehand Setup Script

USAGE:
    $0 [COMMAND]

COMMANDS:
    setup       Complete advanced setup (default)
    examples    Create example scripts only
    mcp         Setup MCP integration only
    help        Show this help

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
