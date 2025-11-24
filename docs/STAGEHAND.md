# 🤘 Stagehand AI Browser Automation Integration

**AI-powered browser automation with natural language control - Available in both JavaScript and Python**

> **🆕 NEW**: Stagehand is now available in both JavaScript and Python! Choose the language that best fits your workflow.

## 🚀 **Choose Your Language**

| **JavaScript** | **Python** |
|----------------|------------|
| ✅ Native web ecosystem | ✅ Data science & ML integration |
| ✅ npm/yarn package management | ✅ Pydantic schema validation |
| ✅ TypeScript + Zod validation | ✅ async/await patterns |
| ✅ Node.js runtime | ✅ Rich Python ecosystem |
| **Best for**: Web developers, Node.js projects | **Best for**: Data scientists, Python developers |

### **Quick Setup**

```bash
# JavaScript Version
bash providers/stagehand-helper.sh setup

# Python Version
bash providers/stagehand-python-helper.sh setup

# Both Versions
bash .agent/scripts/setup-mcp-integrations.sh stagehand-both
```

## 🎯 **Overview**

Stagehand is a revolutionary browser automation framework that combines the power of AI with the precision of code. Unlike traditional automation tools that require brittle selectors, or pure AI agents that can be unpredictable, Stagehand lets you choose exactly how much AI to use in your automation workflows.

### **🌟 Key Features**

- **🧠 AI-Powered Actions**: Use natural language to interact with web pages
- **📊 Structured Data Extraction**: Pull data with schemas using Zod validation
- **🔍 Intelligent Observation**: Discover available actions on any page
- **🤖 Autonomous Agents**: Automate entire workflows with AI decision-making
- **🔒 Local-First**: Works with local browsers for complete privacy
- **⚡ Self-Healing**: Adapts when websites change, reducing maintenance

### **🆚 Stagehand vs Traditional Tools**

| Feature | Traditional Tools | Stagehand | Pure AI Agents |
|---------|------------------|-----------|----------------|
| **Reliability** | Brittle selectors | ✅ Self-healing | Unpredictable |
| **Flexibility** | Manual updates | ✅ AI adaptation | High but chaotic |
| **Control** | Full control | ✅ Precise control | Limited control |
| **Maintenance** | High | ✅ Low | Variable |
| **Debugging** | Complex | ✅ Transparent | Difficult |

## 🚀 **Quick Start**

### **Installation**

```bash
# Complete setup (recommended)
bash providers/stagehand-helper.sh setup

# Or step by step
bash providers/stagehand-helper.sh install
bash providers/stagehand-helper.sh create-example
```

### **Basic Usage**

```javascript
import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

const stagehand = new Stagehand({
    env: "LOCAL", // Use local browser
    verbose: 1
});

await stagehand.init();

// Navigate and interact with natural language
await stagehand.page.goto("https://example.com");
await stagehand.act("click the login button");

// Extract structured data
const data = await stagehand.extract(
    "get the price and title",
    z.object({
        price: z.number(),
        title: z.string()
    })
);

await stagehand.close();
```

## 🛠️ **Core Primitives**

### **1. Act - Natural Language Actions**

Execute actions using natural language descriptions:

```javascript
// Simple actions
await stagehand.act("click the submit button");
await stagehand.act("fill in the email field with user@example.com");
await stagehand.act("scroll down to see more content");

// Complex interactions
await stagehand.act("select 'Premium' from the subscription dropdown");
await stagehand.act("upload the file from the desktop");
```

### **2. Extract - Structured Data Extraction**

Pull structured data from pages with schema validation:

```javascript
// Simple extraction
const price = await stagehand.extract(
    "extract the product price",
    z.number()
);

// Complex structured data
const productInfo = await stagehand.extract(
    "extract product details",
    z.object({
        name: z.string().describe("Product name"),
        price: z.number().describe("Price in USD"),
        rating: z.number().describe("Star rating out of 5"),
        reviews: z.array(z.string()).describe("Customer review texts"),
        inStock: z.boolean().describe("Whether item is in stock")
    })
);
```

### **3. Observe - Discover Available Actions**

Find out what actions are possible on the current page:

```javascript
// Discover all interactive elements
const actions = await stagehand.observe();

// Find specific types of actions
const buttons = await stagehand.observe("find all clickable buttons");
const forms = await stagehand.observe("find all form fields");
const links = await stagehand.observe("find navigation links");
```

### **4. Agent - Autonomous Workflows**

Let AI handle entire workflows autonomously:

```javascript
const agent = stagehand.agent({
    cua: true, // Enable Computer Use Agent
    model: "google/gemini-2.5-computer-use-preview-10-2025"
});

// High-level task execution
await agent.execute("complete the checkout process");
await agent.execute("find and apply for software engineer jobs");
await agent.execute("research competitor pricing and create a report");
```

## 🔧 **Configuration**

### **Environment Variables**

Create `~/.aidevops/stagehand/.env`:

```bash
# AI Provider (choose one)
OPENAI_API_KEY=your_openai_api_key_here
ANTHROPIC_API_KEY=your_anthropic_api_key_here

# Browser Configuration
STAGEHAND_ENV=LOCAL          # LOCAL or BROWSERBASE
STAGEHAND_HEADLESS=false     # Show browser window
STAGEHAND_VERBOSE=1          # Logging level
STAGEHAND_DEBUG_DOM=true     # Debug DOM interactions

# Optional: Browserbase (for cloud browsers)
BROWSERBASE_API_KEY=your_browserbase_api_key_here
BROWSERBASE_PROJECT_ID=your_browserbase_project_id_here
```

### **Advanced Configuration**

```javascript
const stagehand = new Stagehand({
    env: "LOCAL",
    verbose: 1,
    debugDom: true,
    headless: false,
    browserOptions: {
        args: [
            "--disable-web-security",
            "--disable-features=VizDisplayCompositor"
        ]
    },
    modelName: "gpt-4o", // or "claude-3-5-sonnet-20241022"
    modelClientOptions: {
        apiKey: process.env.OPENAI_API_KEY
    }
});
```

## 📚 **Examples**

### **E-commerce Automation**

```javascript
// Product research automation
await stagehand.page.goto("https://amazon.com");
await stagehand.act("search for 'wireless headphones'");

const products = await stagehand.extract(
    "extract top 5 products with details",
    z.array(z.object({
        name: z.string(),
        price: z.number(),
        rating: z.number(),
        reviewCount: z.number()
    }))
);

console.log("Found products:", products);
```

### **Social Media Automation**

```javascript
// LinkedIn post engagement
await stagehand.page.goto("https://linkedin.com/feed");
await stagehand.act("scroll down to see more posts");

const posts = await stagehand.observe("find posts with engagement buttons");
await stagehand.act("like the first post about AI technology");
```

### **Data Collection**

```javascript
// News article scraping
await stagehand.page.goto("https://news-website.com");

const articles = await stagehand.extract(
    "extract all article headlines and summaries",
    z.array(z.object({
        headline: z.string(),
        summary: z.string(),
        author: z.string(),
        publishDate: z.string()
    }))
);
```

## 🔗 **Integration with AI DevOps Framework**

### **MCP Integration**

Stagehand can be integrated with the framework's MCP system:

```bash
# Add Stagehand MCP server (if available)
bash .agent/scripts/setup-mcp-integrations.sh stagehand
```

### **Browser Automation Ecosystem**

Stagehand complements existing browser automation tools:

- **Chrome DevTools MCP**: For debugging and performance analysis
- **Playwright MCP**: For cross-browser testing
- **Local Browser Automation**: For privacy-focused automation
- **Stagehand**: For AI-powered, natural language automation

### **Quality Integration**

```bash
# Run quality checks on Stagehand scripts
bash .agent/scripts/quality-check.sh ~/.aidevops/stagehand/

# Lint JavaScript/TypeScript files
bash .agent/scripts/linter-manager.sh install javascript
```

## 🎯 **Use Cases**

### **🛒 E-commerce & Shopping**

- Product research and price comparison
- Automated purchasing workflows
- Inventory monitoring
- Review and rating analysis

### **📊 Data Collection & Research**

- Web scraping with AI adaptation
- Competitive analysis automation
- Market research data gathering
- Content aggregation

### **🧪 Testing & QA**

- User journey testing
- Form validation testing
- Cross-browser compatibility
- Accessibility testing

### **📱 Social Media Management**

- Content scheduling and posting
- Engagement automation (ethical)
- Analytics data collection
- Community management

### **💼 Business Process Automation**

- Lead generation workflows
- CRM data entry automation
- Report generation
- Administrative task automation

## 🔒 **Security & Privacy**

### **Local-First Approach**

- **Complete Privacy**: All automation runs on your local machine
- **No Data Transmission**: Sensitive data never leaves your environment
- **Full Control**: You control all browser instances and data
- **Enterprise Ready**: Perfect for confidential business processes

### **Ethical Guidelines**

- **Respect Terms of Service**: Always comply with website ToS
- **Rate Limiting**: Use appropriate delays between actions
- **Authentic Interactions**: Focus on genuine, valuable automation
- **Legal Compliance**: Ensure all automation is legally compliant

## 🛠️ **Helper Commands**

```bash
# Installation and setup
bash providers/stagehand-helper.sh install      # Install Stagehand
bash providers/stagehand-helper.sh setup        # Complete setup
bash providers/stagehand-helper.sh status       # Check installation

# Development and testing
bash providers/stagehand-helper.sh create-example  # Create example script
bash providers/stagehand-helper.sh run-example     # Run basic example
bash providers/stagehand-helper.sh logs            # View logs

# Maintenance
bash providers/stagehand-helper.sh clean        # Clean cache and logs
```

## 📖 **Resources**

### **Official Documentation**

- **Stagehand Docs**: https://docs.stagehand.dev
- **GitHub Repository**: https://github.com/browserbase/stagehand
- **Quickstart Guide**: https://docs.stagehand.dev/v3/first-steps/quickstart

### **AI DevOps Framework Integration**

- **Browser Automation**: docs/BROWSER-AUTOMATION.md
- **MCP Integrations**: docs/MCP-INTEGRATIONS.md
- **Quality Standards**: .agent/spec/code-quality.md

### **Community & Support**

- **Discord**: https://discord.gg/stagehand
- **Slack**: https://join.slack.com/t/stagehand-dev/shared_invite/...
- **GitHub Issues**: https://github.com/browserbase/stagehand/issues

---

**🎉 Ready to revolutionize your browser automation with AI? Get started with Stagehand today!**

```bash
bash providers/stagehand-helper.sh setup
```
