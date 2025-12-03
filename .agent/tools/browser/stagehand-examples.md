# Stagehand MCP Usage Examples

<!-- AI-CONTEXT-START -->

## Quick Reference

- Stagehand examples for AI-powered browser automation (JavaScript)
- Core methods: `act()`, `extract()`, `observe()`, `agent.execute()`
- Data extraction: Use Zod schemas for structured output
- Agent mode: `stagehand.agent({ cua: true, model: "..." })`
- Example categories:
  - E-commerce: Product search, price monitoring, comparison
  - Data collection: News scraping, social media analytics
  - Testing: User journey, accessibility, QA automation
  - Autonomous agents: Job applications, research, reports
- Error handling: Use try/catch with `stagehand.close()` in finally
- Rate limiting: Add delays, respect robots.txt
- Integration: Works with Chrome DevTools, Playwright, Context7 MCPs
<!-- AI-CONTEXT-END -->

## AI-Powered Browser Automation

### **Basic Natural Language Automation**

```javascript
// Use Stagehand through MCP for natural language browser control
import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

const stagehand = new Stagehand({
    env: "LOCAL",
    verbose: 1,
    headless: false
});

await stagehand.init();

// Navigate and interact with natural language
await stagehand.page.goto("https://example.com");
await stagehand.act("click the 'Get Started' button");
await stagehand.act("fill in the email field with test@example.com");
await stagehand.act("submit the form");

await stagehand.close();
```

### **Structured Data Extraction**

```javascript
// Extract structured data from web pages
const productData = await stagehand.extract(
    "extract all product information from this page",
    z.object({
        products: z.array(z.object({
            name: z.string().describe("Product name"),
            price: z.number().describe("Price in USD"),
            rating: z.number().describe("Star rating out of 5"),
            availability: z.string().describe("Stock status"),
            description: z.string().describe("Product description")
        }))
    })
);

console.log("Extracted products:", productData.products);
```

## 🛒 **E-commerce Automation Examples**

### **Product Research Automation**

```javascript
// Automated product comparison across multiple sites
async function compareProducts(productQuery, sites = ["amazon.com", "ebay.com"]) {
    const results = [];
    
    for (const site of sites) {
        await stagehand.page.goto(`https://${site}`);
        await stagehand.act(`search for "${productQuery}"`);
        
        const products = await stagehand.extract(
            "extract the first 5 products with prices and ratings",
            z.array(z.object({
                name: z.string(),
                price: z.number(),
                rating: z.number().optional(),
                url: z.string().optional()
            })).max(5)
        );
        
        results.push({ site, products });
    }
    
    return results;
}

// Usage
const comparison = await compareProducts("wireless headphones");
console.log("Product comparison:", comparison);
```

### **Price Monitoring**

```javascript
// Monitor product prices and get alerts
async function monitorPrice(productUrl, targetPrice) {
    await stagehand.page.goto(productUrl);
    
    const currentPrice = await stagehand.extract(
        "extract the current product price",
        z.object({
            price: z.number().describe("Current price in USD"),
            currency: z.string().describe("Currency symbol"),
            availability: z.string().describe("Stock status")
        })
    );
    
    if (currentPrice.price <= targetPrice) {
        console.log(`🎉 Price alert! Product is now $${currentPrice.price} (target: $${targetPrice})`);
        // Could integrate with notification systems here
    }
    
    return currentPrice;
}
```

## 📊 **Data Collection & Research**

### **News Article Scraping**

```javascript
// Collect news articles with AI-powered extraction
async function scrapeNews(newsUrl, maxArticles = 10) {
    await stagehand.page.goto(newsUrl);
    
    // Handle cookie banners automatically
    await stagehand.act("accept cookies if there's a banner");
    
    const articles = await stagehand.extract(
        `extract the first ${maxArticles} news articles`,
        z.array(z.object({
            headline: z.string().describe("Article headline"),
            summary: z.string().describe("Article summary or excerpt"),
            author: z.string().optional().describe("Article author"),
            publishDate: z.string().optional().describe("Publication date"),
            category: z.string().optional().describe("Article category"),
            url: z.string().optional().describe("Article URL")
        })).max(maxArticles)
    );
    
    return articles;
}

// Usage
const news = await scrapeNews("https://news.ycombinator.com", 5);
console.log("Latest tech news:", news);
```

### **Social Media Analytics**

```javascript
// Analyze social media engagement (ethical use only)
async function analyzeSocialMedia(platform, hashtag) {
    await stagehand.page.goto(`https://${platform}.com`);
    
    // Navigate to hashtag or search
    await stagehand.act(`search for posts with hashtag ${hashtag}`);
    
    const posts = await stagehand.extract(
        "analyze the top posts for engagement metrics",
        z.array(z.object({
            content: z.string().describe("Post content preview"),
            author: z.string().describe("Post author"),
            engagement: z.object({
                likes: z.number().describe("Number of likes"),
                comments: z.number().describe("Number of comments"),
                shares: z.number().describe("Number of shares")
            }),
            timestamp: z.string().describe("Post timestamp")
        })).max(10)
    );
    
    return posts;
}
```

## 🧪 **Testing & Quality Assurance**

### **Automated User Journey Testing**

```javascript
// Test complete user workflows
async function testUserJourney(baseUrl) {
    const testResults = [];
    
    try {
        // Test registration flow
        await stagehand.page.goto(`${baseUrl}/register`);
        await stagehand.act("fill in the registration form with test data");
        await stagehand.act("submit the registration form");
        
        const registrationResult = await stagehand.observe("check if registration was successful");
        testResults.push({ test: "registration", status: "passed", details: registrationResult });
        
        // Test login flow
        await stagehand.act("navigate to login page");
        await stagehand.act("login with the test credentials");
        
        const loginResult = await stagehand.observe("check if login was successful");
        testResults.push({ test: "login", status: "passed", details: loginResult });
        
        // Test main functionality
        await stagehand.act("navigate to the main dashboard");
        const dashboardElements = await stagehand.observe("find all interactive elements on the dashboard");
        testResults.push({ test: "dashboard", status: "passed", elements: dashboardElements });
        
    } catch (error) {
        testResults.push({ test: "user_journey", status: "failed", error: error.message });
    }
    
    return testResults;
}
```

### **Accessibility Testing**

```javascript
// Test website accessibility with AI assistance
async function testAccessibility(url) {
    await stagehand.page.goto(url);
    
    const accessibilityIssues = await stagehand.extract(
        "identify potential accessibility issues on this page",
        z.object({
            issues: z.array(z.object({
                type: z.string().describe("Type of accessibility issue"),
                element: z.string().describe("Affected element"),
                severity: z.enum(["low", "medium", "high"]).describe("Issue severity"),
                suggestion: z.string().describe("Suggested fix")
            })),
            score: z.number().describe("Overall accessibility score out of 100")
        })
    );
    
    return accessibilityIssues;
}
```

## 🤖 **Autonomous Agent Examples**

### **Job Application Agent**

```javascript
// Autonomous job application workflow
async function autoApplyJobs(jobSearchUrl, criteria) {
    const agent = stagehand.agent({
        cua: true, // Enable Computer Use Agent
        model: "google/gemini-2.5-computer-use-preview-10-2025"
    });
    
    await stagehand.page.goto(jobSearchUrl);
    
    // Let the agent handle the entire workflow
    const result = await agent.execute(`
        Search for ${criteria.jobTitle} jobs in ${criteria.location}.
        Filter for ${criteria.experience} experience level.
        Apply to the first 3 suitable positions that match:
        - Salary range: ${criteria.salaryRange}
        - Remote work: ${criteria.remote}
        - Company size: ${criteria.companySize}
        
        For each application:
        1. Review the job description
        2. Customize the cover letter
        3. Submit the application
        4. Save the job details for tracking
    `);
    
    return result;
}

// Usage
const jobCriteria = {
    jobTitle: "Software Engineer",
    location: "San Francisco",
    experience: "mid-level",
    salaryRange: "$120k-180k",
    remote: "hybrid",
    companySize: "startup"
};

const applicationResults = await autoApplyJobs("https://linkedin.com/jobs", jobCriteria);
```

### **Research Agent**

```javascript
// Autonomous research and report generation
async function conductResearch(topic, sources) {
    const agent = stagehand.agent({
        cua: true,
        model: "gpt-4o"
    });
    
    const research = await agent.execute(`
        Research the topic: "${topic}"
        
        Visit these sources: ${sources.join(", ")}
        
        For each source:
        1. Extract key information and statistics
        2. Note the publication date and credibility
        3. Identify supporting evidence and counterarguments
        
        Compile a comprehensive research report with:
        - Executive summary
        - Key findings
        - Supporting data
        - Conclusions and recommendations
        - Source citations
    `);
    
    return research;
}

// Usage
const researchTopic = "Impact of AI on Software Development";
const sources = [
    "https://stackoverflow.blog",
    "https://github.blog",
    "https://research.google.com"
];

const report = await conductResearch(researchTopic, sources);
```

## 🔧 **Integration with AI DevOps Framework**

### **Quality Assurance Integration**

```javascript
// Integrate with framework's quality tools
async function runQualityChecks(websiteUrl) {
    // Use Stagehand for functional testing
    const functionalTests = await testUserJourney(websiteUrl);
    
    // Use PageSpeed MCP for performance
    const performanceData = await stagehand.extract(
        "analyze page performance metrics",
        z.object({
            loadTime: z.number(),
            coreWebVitals: z.object({
                lcp: z.number(),
                fid: z.number(),
                cls: z.number()
            })
        })
    );
    
    // Combine results
    return {
        functional: functionalTests,
        performance: performanceData,
        timestamp: new Date().toISOString()
    };
}
```

### **MCP Server Integration**

```javascript
// Use Stagehand with other MCP servers
async function comprehensiveAnalysis(url) {
    // Stagehand for browser automation
    await stagehand.page.goto(url);
    const pageData = await stagehand.extract("extract all page content", z.any());
    
    // Chrome DevTools MCP for performance
    // Playwright MCP for cross-browser testing
    // Context7 MCP for documentation lookup
    
    return {
        content: pageData,
        url: url,
        analysis: "comprehensive"
    };
}
```

## 🎯 **Best Practices**

### **Error Handling**

```javascript
async function robustAutomation(url) {
    try {
        await stagehand.init();
        await stagehand.page.goto(url);
        
        // Use observe to check page state
        const pageState = await stagehand.observe("check if page loaded successfully");
        
        if (pageState.includes("error") || pageState.includes("404")) {
            throw new Error("Page failed to load properly");
        }
        
        // Continue with automation...
        
    } catch (error) {
        console.error("Automation failed:", error);
        // Implement retry logic or fallback
        
    } finally {
        await stagehand.close();
    }
}
```

### **Rate Limiting & Ethics**

```javascript
// Implement ethical automation practices
async function ethicalAutomation(urls) {
    for (const url of urls) {
        // Respect robots.txt
        const robotsAllowed = await checkRobotsTxt(url);
        if (!robotsAllowed) {
            console.log(`Skipping ${url} - robots.txt disallows`);
            continue;
        }
        
        // Add delays between requests
        await new Promise(resolve => setTimeout(resolve, 2000));
        
        // Process URL...
        await processUrl(url);
    }
}
```

---

**🎉 These examples demonstrate the power of combining Stagehand's AI-driven browser automation with the AI DevOps Framework's comprehensive tooling ecosystem!**
