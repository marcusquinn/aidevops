---
description: Stagehand MCP usage examples and patterns
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Stagehand MCP Usage Examples

<!-- AI-CONTEXT-START -->
- Core methods: `act()`, `extract()`, `observe()`, `agent.execute()`
- Data extraction: Zod schemas for structured output
- Agent mode: `stagehand.agent({ cua: true, model: "..." })`
- Error handling: try/catch with `stagehand.close()` in finally
- Rate limiting: add delays, respect robots.txt
- Integration: Chrome DevTools, Playwright, Context7 MCPs
<!-- AI-CONTEXT-END -->

## Basic Usage

```javascript
import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

const stagehand = new Stagehand({ env: "LOCAL", verbose: 1, headless: false });
await stagehand.init();
await stagehand.page.goto("https://example.com");
await stagehand.act("click the 'Get Started' button");
await stagehand.act("fill in the email field with test@example.com");
await stagehand.act("submit the form");
await stagehand.close();
```

## Structured Data Extraction

```javascript
const productData = await stagehand.extract(
    "extract all product information from this page",
    z.object({
        products: z.array(z.object({
            name: z.string(),
            price: z.number(),
            rating: z.number(),
            availability: z.string(),
            description: z.string()
        }))
    })
);
```

## E-commerce

### Product Comparison

```javascript
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
```

### Price Monitoring

```javascript
async function monitorPrice(productUrl, targetPrice) {
    await stagehand.page.goto(productUrl);
    const { price } = await stagehand.extract(
        "extract the current product price",
        z.object({ price: z.number(), currency: z.string(), availability: z.string() })
    );
    if (price <= targetPrice) console.log(`Price alert: $${price} (target: $${targetPrice})`);
    return price;
}
```

## Data Collection

### News Scraping

```javascript
async function scrapeNews(newsUrl, maxArticles = 10) {
    await stagehand.page.goto(newsUrl);
    await stagehand.act("accept cookies if there's a banner");
    return stagehand.extract(
        `extract the first ${maxArticles} news articles`,
        z.array(z.object({
            headline: z.string(),
            summary: z.string(),
            author: z.string().optional(),
            publishDate: z.string().optional(),
            category: z.string().optional(),
            url: z.string().optional()
        })).max(maxArticles)
    );
}
```

### Social Media Analytics

```javascript
async function analyzeSocialMedia(platform, hashtag) {
    await stagehand.page.goto(`https://${platform}.com`);
    await stagehand.act(`search for posts with hashtag ${hashtag}`);
    return stagehand.extract(
        "analyze the top posts for engagement metrics",
        z.array(z.object({
            content: z.string(),
            author: z.string(),
            engagement: z.object({ likes: z.number(), comments: z.number(), shares: z.number() }),
            timestamp: z.string()
        })).max(10)
    );
}
```

## Testing & QA

### User Journey Testing

```javascript
async function testUserJourney(baseUrl) {
    const results = [];
    try {
        await stagehand.page.goto(`${baseUrl}/register`);
        await stagehand.act("fill in the registration form with test data");
        await stagehand.act("submit the registration form");
        results.push({ test: "registration", status: "passed",
            details: await stagehand.observe("check if registration was successful") });

        await stagehand.act("navigate to login page");
        await stagehand.act("login with the test credentials");
        results.push({ test: "login", status: "passed",
            details: await stagehand.observe("check if login was successful") });

        await stagehand.act("navigate to the main dashboard");
        results.push({ test: "dashboard", status: "passed",
            elements: await stagehand.observe("find all interactive elements on the dashboard") });
    } catch (error) {
        results.push({ test: "user_journey", status: "failed", error: error.message });
    }
    return results;
}
```

### Accessibility Testing

```javascript
async function testAccessibility(url) {
    await stagehand.page.goto(url);
    return stagehand.extract(
        "identify potential accessibility issues on this page",
        z.object({
            issues: z.array(z.object({
                type: z.string(),
                element: z.string(),
                severity: z.enum(["low", "medium", "high"]),
                suggestion: z.string()
            })),
            score: z.number()
        })
    );
}
```

## Autonomous Agents

### Job Application Agent

```javascript
async function autoApplyJobs(jobSearchUrl, criteria) {
    const agent = stagehand.agent({
        cua: true,
        model: "google/gemini-2.5-computer-use-preview-10-2025"
    });
    await stagehand.page.goto(jobSearchUrl);
    return agent.execute(`
        Search for ${criteria.jobTitle} jobs in ${criteria.location}.
        Filter for ${criteria.experience} experience level.
        Apply to the first 3 suitable positions matching:
        salary ${criteria.salaryRange}, remote: ${criteria.remote}, size: ${criteria.companySize}.
        For each: review description, customize cover letter, submit, save details.
    `);
}
```

### Research Agent

```javascript
async function conductResearch(topic, sources) {
    const agent = stagehand.agent({ cua: true, model: "gpt-4o" });
    return agent.execute(`
        Research: "${topic}". Visit: ${sources.join(", ")}.
        For each source: extract key info, note date/credibility, identify evidence.
        Compile report: executive summary, key findings, data, conclusions, citations.
    `);
}
```

## Framework Integration

### Quality Assurance

```javascript
async function runQualityChecks(websiteUrl) {
    const functionalTests = await testUserJourney(websiteUrl);
    const performanceData = await stagehand.extract(
        "analyze page performance metrics",
        z.object({
            loadTime: z.number(),
            coreWebVitals: z.object({ lcp: z.number(), fid: z.number(), cls: z.number() })
        })
    );
    return { functional: functionalTests, performance: performanceData, timestamp: new Date().toISOString() };
}
```

### MCP Server Integration

```javascript
// Stagehand + Chrome DevTools MCP (performance) + Playwright MCP (cross-browser) + Context7 MCP (docs)
async function comprehensiveAnalysis(url) {
    await stagehand.page.goto(url);
    const pageData = await stagehand.extract("extract all page content", z.any());
    return { content: pageData, url };
}
```

## Best Practices

### Error Handling

```javascript
async function robustAutomation(url) {
    try {
        await stagehand.init();
        await stagehand.page.goto(url);
        const pageState = await stagehand.observe("check if page loaded successfully");
        if (pageState.includes("error") || pageState.includes("404")) {
            throw new Error("Page failed to load");
        }
    } catch (error) {
        console.error("Automation failed:", error);
    } finally {
        await stagehand.close();
    }
}
```

### Rate Limiting & Ethics

```javascript
async function ethicalAutomation(urls) {
    for (const url of urls) {
        if (!await checkRobotsTxt(url)) { console.log(`Skipping ${url}`); continue; }
        await new Promise(resolve => setTimeout(resolve, 2000));
        await processUrl(url);
    }
}
```
