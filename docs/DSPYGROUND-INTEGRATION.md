# DSPyGround Integration Guide

## 🎯 **Overview**

DSPyGround is a visual prompt optimization playground powered by the GEPA (Genetic-Pareto Evolutionary Algorithm) optimizer. It provides an intuitive web interface for iterative prompt optimization with real-time feedback and multi-dimensional metrics.

## 🚀 **Quick Start**

### **Prerequisites**

- Node.js 18+ installed
- npm package manager
- AI Gateway API key
- OpenAI API key (optional, for voice feedback)

### **Installation**

```bash
# Install DSPyGround globally
./providers/dspyground-helper.sh install

# Verify installation
dspyground --version
```

### **Configuration**

1. **Copy configuration template:**
   ```bash
   cp configs/dspyground-config.json.txt configs/dspyground-config.json
   ```

2. **Edit configuration:**
   ```bash
   # Customize settings for your use case
   nano configs/dspyground-config.json
   ```

## 📁 **Project Structure**

```
aidevops/
├── providers/dspyground-helper.sh    # DSPyGround management script
├── configs/dspyground-config.json    # DSPyGround configuration
├── data/dspyground/                  # DSPyGround projects
│   └── my-agent/
│       ├── dspyground.config.ts      # Project configuration
│       ├── .env                      # Environment variables
│       └── .dspyground/              # Local data storage
└── package.json                      # Node.js dependencies
```

## 🛠️ **Usage**

### **Initialize New Project**

```bash
# Create a new DSPyGround project
./providers/dspyground-helper.sh init my-agent

# Navigate to project directory
cd data/dspyground/my-agent
```

### **Start Development Server**

```bash
# Start the development server
./providers/dspyground-helper.sh dev my-agent

# Or from project directory
dspyground dev
```

The playground will open at `http://localhost:3000`

### **Basic Configuration**

Create `dspyground.config.ts`:

```typescript
import { tool } from 'ai'
import { z } from 'zod'

export default {
  // System prompt for your agent
  systemPrompt: `You are a helpful DevOps assistant specialized in infrastructure management.
  
  You help users with:
  - Server configuration and deployment
  - CI/CD pipeline optimization
  - Infrastructure monitoring
  - Security best practices
  
  Always provide practical, actionable advice.`,

  // AI SDK tools (optional)
  tools: {
    checkServerStatus: tool({
      description: 'Check the status of a server',
      parameters: z.object({
        serverId: z.string().describe('The server ID to check'),
      }),
      execute: async ({ serverId }) => {
        // Implementation would connect to actual server
        return `Server ${serverId} is running normally`;
      },
    }),
  },

  // Optional: Structured output schema
  schema: z.object({
    response: z.string(),
    confidence: z.number().min(0).max(1),
    category: z.enum(['deployment', 'monitoring', 'security', 'general'])
  }),

  // Optimization preferences
  preferences: {
    selectedModel: 'openai/gpt-4o-mini',
    optimizationModel: 'openai/gpt-4o-mini',
    reflectionModel: 'openai/gpt-4o',
    batchSize: 3,
    numRollouts: 10,
    selectedMetrics: ['accuracy', 'tone'],
    useStructuredOutput: false,
  },

  // Metrics configuration
  metricsPrompt: {
    evaluation_instructions: 'You are an expert DevOps evaluator...',
    dimensions: {
      accuracy: {
        name: 'Technical Accuracy',
        description: 'Is the DevOps advice technically correct?',
        weight: 1.0
      },
      tone: {
        name: 'Professional Tone',
        description: 'Is the communication professional and clear?',
        weight: 0.8
      },
      efficiency: {
        name: 'Solution Efficiency',
        description: 'Does the solution optimize for efficiency?',
        weight: 0.9
      }
    }
  }
}
```

### **Environment Setup**

Create `.env` file:

```bash
# Required: AI Gateway API key
AI_GATEWAY_API_KEY=your_ai_gateway_api_key_here

# Optional: For voice feedback feature
# DSPyGround automatically uses your terminal session's OPENAI_API_KEY
OPENAI_API_KEY=${OPENAI_API_KEY}  # Uses your existing environment variable
OPENAI_BASE_URL=https://api.openai.com/v1
```

**Note**: DSPyGround will automatically use API keys from your terminal session environment. You only need to add `AI_GATEWAY_API_KEY` if you're using AI Gateway instead of direct OpenAI API calls.

## 🎯 **Optimization Workflow**

### **1. Chat and Sample**
- Start conversations with your agent
- Test different scenarios and use cases
- Save good responses as positive samples
- Mark problematic responses as negative samples

### **2. Organize Samples**
- Create sample groups (e.g., "Deployment Tasks", "Security Questions")
- Categorize samples by use case or complexity
- Build a comprehensive test suite

### **3. Run Optimization**
- Click "Optimize" to start GEPA optimization
- Watch real-time progress and metrics
- Review generated candidate prompts
- Select the best performing prompt

### **4. Export Results**
- Copy optimized prompt from history
- Update your `dspyground.config.ts`
- Deploy to production systems

## 📊 **Metrics and Evaluation**

### **Built-in Metrics**

- **Accuracy**: Factual correctness and relevance
- **Tone**: Communication style and professionalism
- **Efficiency**: Resource usage and optimization
- **Tool Accuracy**: Correct tool selection and usage
- **Guardrails**: Safety and ethical compliance

### **Custom Metrics**

```typescript
metricsPrompt: {
  dimensions: {
    devops_expertise: {
      name: 'DevOps Expertise',
      description: 'Does the response demonstrate deep DevOps knowledge?',
      weight: 1.0
    },
    actionability: {
      name: 'Actionability',
      description: 'Can the user immediately act on this advice?',
      weight: 0.9
    }
  }
}
```

## 🔧 **Advanced Features**

### **Voice Feedback**
- Press and hold spacebar in feedback dialogs
- Record voice feedback for samples
- Automatic transcription and analysis

### **Structured Output**
```typescript
schema: z.object({
  task_type: z.enum(['deployment', 'monitoring', 'troubleshooting']),
  priority: z.enum(['low', 'medium', 'high', 'critical']),
  steps: z.array(z.string()),
  estimated_time: z.string(),
  risks: z.array(z.string())
})
```

### **Tool Integration**
```typescript
tools: {
  deployApp: tool({
    description: 'Deploy application to server',
    parameters: z.object({
      appName: z.string(),
      environment: z.enum(['dev', 'staging', 'prod']),
    }),
    execute: async ({ appName, environment }) => {
      // Integration with actual deployment systems
      return `Deployed ${appName} to ${environment}`;
    },
  }),
}
```

## 🎨 **UI Features**

### **Chat Interface**
- Real-time streaming responses
- Structured output visualization
- Tool call execution display
- Sample saving with feedback

### **Optimization Dashboard**
- Progress tracking with real-time updates
- Pareto frontier visualization
- Metric score evolution
- Candidate prompt comparison

### **History Management**
- Complete optimization run history
- Prompt evolution tracking
- Performance metrics over time
- Export capabilities

## 🔍 **Troubleshooting**

### **Common Issues**

1. **Server Won't Start**
   ```bash
   # Check Node.js version
   node --version  # Should be 18+
   
   # Check port availability
   lsof -i :3000
   ```

2. **API Key Issues**
   ```bash
   # Verify environment variables
   cat .env
   
   # Test API connectivity
   curl -H "Authorization: Bearer $AI_GATEWAY_API_KEY" \
        https://api.aigateway.com/v1/models
   ```

3. **Optimization Failures**
   ```typescript
   // Reduce batch size for stability
   preferences: {
     batchSize: 1,
     numRollouts: 5,
   }
   ```

## 📚 **Additional Resources**

- [DSPyGround GitHub Repository](https://github.com/Scale3-Labs/dspyground)
- [AI Gateway Documentation](https://docs.aigateway.com/)
- [AI SDK Documentation](https://sdk.vercel.ai/)
- [GEPA Algorithm Paper](https://arxiv.org/abs/2310.03714)

## 🤝 **Integration with AI DevOps**

DSPyGround complements other AI DevOps Framework components:

- **Server Management**: Optimize prompts for infrastructure tasks
- **Code Quality**: Create better prompts for code analysis
- **Documentation**: Generate optimized technical writing prompts
- **Monitoring**: Develop prompts for alert analysis and response

## 🔗 **Related Documentation**

- [DSPy Integration Guide](./DSPY-INTEGRATION.md) - Core DSPy framework integration
- [AI DevOps Framework Overview](../README.md) - Main framework documentation
- [MCP Integrations](./MCP-INTEGRATIONS.md) - Model Context Protocol integrations
