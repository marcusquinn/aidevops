---
description: Unstract - LLM-powered document data extraction via MCP
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  unstract_tool: true
mcp:
  unstract: true
---

# Unstract - Document Processing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract structured data from unstructured documents (PDFs, images, DOCX, etc.)
- **MCP Server**: `unstract/mcp-server` (Docker) or `@unstract/mcp-server` (npx)
- **Tool**: `unstract_tool` - submits files to Unstract API, polls for completion, returns structured JSON
- **Credentials**: `UNSTRACT_API_KEY` + `API_BASE_URL` in `~/.config/aidevops/mcp-env.sh` (chmod 600)
- **Docs**: https://docs.unstract.com/unstract/unstract_platform/mcp/unstract_platform_mcp_server/
- **GitHub**: https://github.com/Zipstack/unstract

**On-demand loading**: This MCP is disabled globally and enabled per-agent when document extraction is needed.

<!-- AI-CONTEXT-END -->

## What is Unstract?

Unstract is a no-code LLM platform that structures unstructured documents. It provides:

- **Prompt Studio**: Visual environment to define extraction schemas
- **API Deployments**: Turn any document into JSON via REST API
- **ETL Pipelines**: Batch process documents into databases
- **MCP Server**: Integrate extraction into AI agent workflows

## Supported File Types

| Category | Formats |
|----------|---------|
| Documents | PDF, DOCX, DOC, ODT, TXT, CSV, JSON |
| Spreadsheets | XLSX, XLS, ODS |
| Presentations | PPTX, PPT, ODP |
| Images | PNG, JPG, JPEG, TIFF, BMP, GIF, WEBP |

## MCP Tool

### `unstract_tool`

Submits a file to the Unstract API, polls for completion, and returns structured extraction results.

**Parameters**:
- `file_path` (required): Path to the document to process
- `include_metadata` (optional): Include extraction metadata in response
- `include_metrics` (optional): Include processing metrics (tokens, cost)

**Example prompt**: "Process the document /tmp/invoice.pdf"

## Setup

The MCP server is a thin client that connects to any Unstract API endpoint - cloud or self-hosted.

### Option A: Cloud (Quick Start)

1. Sign up at https://unstract.com/start-for-free/ (14-day free trial)
2. Create a Prompt Studio project and define your extraction schema
3. Deploy as an API endpoint
4. Copy the API key and deployment URL

```bash
# Add to ~/.config/aidevops/mcp-env.sh:
export UNSTRACT_API_KEY="your_api_key_here"
export API_BASE_URL="https://us-central.unstract.com/deployment/api/your-deployment-id/"
chmod 600 ~/.config/aidevops/mcp-env.sh
```

### Option B: Self-Hosted (Local) - Recommended

Install and run the full Unstract platform locally (requires Docker, 8GB RAM):

```bash
# One-command install via aidevops helper:
~/.aidevops/agents/scripts/unstract-helper.sh install

# Or via the MCP integrations setup:
~/.aidevops/agents/scripts/setup-mcp-integrations.sh unstract
```

This clones Unstract to `~/.aidevops/unstract/`, disables analytics, starts Docker Compose, and configures the MCP to point at your local instance.

Visit http://frontend.unstract.localhost (login: unstract/unstract)

**Management commands:**

```bash
unstract-helper.sh start          # Start containers
unstract-helper.sh stop           # Stop containers
unstract-helper.sh status         # Check status
unstract-helper.sh logs           # View logs
unstract-helper.sh configure-llm  # Help adding LLM adapters
unstract-helper.sh uninstall      # Remove everything
```

Self-hosted gives full data privacy - no documents leave your machine.

### Using Your Existing LLM API Keys

Unstract uses "Adapters" to connect to LLM providers. Your existing API keys from `~/.config/aidevops/mcp-env.sh` work directly - just add them as adapters in the Unstract UI (Settings > Adapters):

| Your Key | Unstract Adapter |
|----------|-----------------|
| `OPENAI_API_KEY` | OpenAI (GPT-4, GPT-4o) |
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `GOOGLE_API_KEY` / Vertex credentials | Google VertexAI / Gemini |
| `AZURE_OPENAI_API_KEY` | Azure OpenAI |
| AWS credentials | AWS Bedrock |
| Ollama (local, no key) | Ollama (http://host.docker.internal:11434) |

Run `unstract-helper.sh configure-llm` to see which keys you already have configured.

For fully local/offline operation, use **Ollama** as the LLM adapter - no cloud API keys needed.

### 2. Store Credentials

Whichever option you chose, ensure credentials are in `~/.config/aidevops/mcp-env.sh`:

```bash
export UNSTRACT_API_KEY="your_api_key_here"
export API_BASE_URL="http://backend.unstract.localhost/deployment/api/your-id/"
chmod 600 ~/.config/aidevops/mcp-env.sh
```

**Note**: The MCP expects `API_BASE_URL` (not prefixed). This matches the official Unstract spec.

### 3. OpenCode Configuration (On-Demand)

The MCP is configured in OpenCode but disabled globally. It loads on-demand when this subagent is invoked.

See `configs/mcp-templates/unstract.json` for the configuration template.

### 4. Claude Desktop Configuration (Docker)

```json
{
  "mcpServers": {
    "unstract_tool": {
      "command": "/usr/local/bin/docker",
      "args": [
        "run", "-i", "--rm",
        "-v", "/tmp:/tmp",
        "-e", "UNSTRACT_API_KEY",
        "-e", "API_BASE_URL",
        "unstract/mcp-server",
        "unstract"
      ],
      "env": {
        "UNSTRACT_API_KEY": "",
        "API_BASE_URL": "https://us-central.unstract.com/deployment/api/.../"
      }
    }
  }
}
```

## Use Cases

- **Invoice processing**: Extract line items, totals, vendor info from invoices
- **Bank statement parsing**: Structure transaction data from varied bank formats
- **Insurance claims**: Extract claim details from forms and supporting documents
- **KYC/onboarding**: Parse identity documents and application forms
- **Contract analysis**: Extract key terms, dates, parties from legal documents

## Analytics / Telemetry

The MCP server itself (`unstract/mcp-server` Docker image) contains **no analytics or telemetry code** - it is a clean API client that submits files and returns results.

For **self-hosted** Unstract deployments, disable frontend analytics:

```bash
# In frontend/.env of your self-hosted Unstract instance:
REACT_APP_ENABLE_POSTHOG=false
```

The **cloud API** (`us-central.unstract.com`) may collect server-side usage metrics as part of their platform. Use self-hosted if this is a concern.

## Integration with aidevops

This subagent is referenced by agents that need document extraction capabilities. The MCP loads only when document processing tasks are detected.

**Trigger keywords**: document, extract, parse, invoice, statement, PDF, OCR, unstructured

## Related

- `tools/context/mcp-discovery.md` - On-demand MCP loading pattern
- `.agent/aidevops/mcp-integrations.md` - All MCP integrations
- `configs/mcp-templates/unstract.json` - OpenCode config template
