---
mode: subagent
---
# Product Requirements Document: Document Extraction Subagent & Workflow

Based on [ai-dev-tasks](https://github.com/snarktank/ai-dev-tasks) PRD format, with time tracking.

<!--TOON:prd{id,feature,author,status,est,est_ai,est_test,logged}:
prd-document-extraction,Document Extraction Subagent & Workflow,aidevops,draft,3h,1h,2h,2026-01-25T01:00Z
-->

## Overview

**Feature:** Document Extraction Subagent & Workflow
**Author:** aidevops
**Date:** 2026-01-25
**Status:** Draft
**Estimate:** ~3h (ai:1h test:2h)

### Problem Statement

Organizations need to extract structured data from unstructured documents (PDFs, images, scanned documents) while maintaining data privacy. Current solutions either:
1. Require cloud APIs that expose sensitive data (GDPR/HIPAA concerns)
2. Lack intelligent extraction capabilities (basic OCR without understanding)
3. Don't integrate with AI agent workflows

aidevops already has Unstract integration for document processing, but lacks:
- Local/on-premise LLM support for privacy-sensitive extraction
- PII detection and anonymization before cloud processing
- Document parsing with layout understanding (tables, formulas, reading order)
- Orchestration framework for multi-step extraction pipelines

### Goal

Create a comprehensive document extraction capability in aidevops that:
1. Supports fully local/on-premise processing for sensitive documents
2. Integrates PII detection and anonymization (Microsoft Presidio)
3. Uses advanced document parsing (Docling) for layout understanding
4. Provides LLM-powered extraction (ExtractThinker) with contract-based schemas
5. Supports multiple LLM backends (Ollama local, Cloudflare Workers AI, cloud APIs)

**Success criteria:**
- Extract structured data from invoices, receipts, contracts, IDs with >95% accuracy
- Process documents without any data leaving local machine (when configured)
- Detect and redact PII before optional cloud processing
- Support batch processing of document folders

## User Stories

### Primary User Story

As a developer working with sensitive documents, I want to extract structured data locally so that I can maintain GDPR/HIPAA compliance without sacrificing extraction quality.

### Additional User Stories

- As a finance team member, I want to batch-process invoices and receipts so that I can automate expense tracking.
- As a compliance officer, I want to detect and redact PII from documents before sharing so that I can prevent data leaks.
- As a legal professional, I want to extract key terms from contracts so that I can quickly review agreements.
- As a developer, I want to define custom extraction schemas so that I can extract domain-specific data.

## Functional Requirements

### Core Requirements

1. **Document Parsing (Docling)**
   - Parse PDF, DOCX, PPTX, XLSX, HTML, images (PNG, JPEG, TIFF)
   - Detect tables, formulas, reading order, code blocks
   - Export to Markdown, JSON, DocTags for downstream processing
   - Support OCR for scanned documents via Tesseract or EasyOCR

2. **LLM-Powered Extraction (ExtractThinker)**
   - Define extraction contracts using Pydantic models
   - Support document classification (invoice vs receipt vs contract)
   - Implement splitting strategies (lazy/eager) for multi-page documents
   - Handle pagination for small context window models
   - Support vision models for image-based extraction

3. **PII Detection & Anonymization (Presidio)**
   - Detect PII entities: names, SSN, credit cards, phone numbers, addresses, etc.
   - Support multiple anonymization operators: redact, replace, hash, encrypt
   - Allow custom recognizers for domain-specific PII
   - Provide reversible anonymization (decrypt) when needed

4. **Local LLM Support**
   - Ollama integration for fully local processing
   - Support models: Phi-4 (14B), Llama 3.x, Qwen 2.5, Moondream (vision)
   - Cloudflare Workers AI as privacy-preserving cloud option
   - Fallback to cloud APIs (OpenAI, Anthropic) when configured

### Secondary Requirements

5. **Workflow Orchestration**
   - Pipeline: Load -> Parse -> Detect PII -> Anonymize -> Extract -> De-anonymize
   - Configurable pipeline stages (skip PII for non-sensitive docs)
   - Batch processing with progress tracking
   - Error handling and retry logic

6. **Integration with aidevops**
   - Helper script: `document-extraction-helper.sh`
   - Subagent: `tools/document-extraction/document-extraction.md`
   - MCP integration for AI agent workflows
   - Memory integration for extraction patterns

## Non-Goals (Out of Scope)

- Real-time document streaming (batch processing only)
- Document generation/creation (extraction only)
- Training custom ML models (use pre-trained only)
- GUI/web interface (CLI and agent integration only)
- Document storage/management (extraction only, storage is user's responsibility)

## Design Considerations

### Architecture

```
tools/document-extraction/
├── document-extraction.md      # Main orchestrator subagent
├── docling.md                  # Document parsing subagent
├── extractthinker.md           # LLM extraction subagent
├── presidio.md                 # PII detection/anonymization subagent
├── local-llm.md                # Local LLM configuration subagent
└── contracts/                  # Example extraction contracts
    ├── invoice.md
    ├── receipt.md
    ├── driver-license.md
    └── contract.md

scripts/
├── document-extraction-helper.sh  # CLI wrapper
├── docling-helper.sh              # Docling operations
├── presidio-helper.sh             # PII operations
└── extractthinker-helper.sh       # Extraction operations
```

### Pipeline Flow

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Document  │───▶│   Docling   │───▶│  Presidio   │───▶│ExtractThinker│
│   Input     │    │   Parse     │    │  PII Scan   │    │   Extract   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
                          │                  │                  │
                          ▼                  ▼                  ▼
                    Markdown/JSON      PII Report        Structured JSON
                    + Layout Info      + Anonymized      + Contract Data
```

### LLM Backend Options

| Backend | Privacy | Speed | Quality | Cost |
|---------|---------|-------|---------|------|
| Ollama (local) | Full | Slow | Good | Free |
| Cloudflare Workers AI | High | Fast | Good | Low |
| OpenAI API | Medium | Fast | Excellent | Medium |
| Anthropic API | Medium | Fast | Excellent | Medium |
| Azure OpenAI | High (VPC) | Fast | Excellent | Medium |

## Technical Considerations

### Dependencies

- **Docling**: `pip install docling` (Python 3.10+, MIT license)
- **ExtractThinker**: `pip install extract-thinker` (Python 3.9+, Apache 2.0)
- **Presidio**: `pip install presidio-analyzer presidio-anonymizer` (MIT license)
- **Ollama**: `brew install ollama` or Docker (MIT license)
- **Tesseract**: `brew install tesseract` for OCR (Apache 2.0)

### Python Environment

Create isolated environment to avoid conflicts:

```bash
# Create venv in aidevops workspace
python3 -m venv ~/.aidevops/.agent-workspace/python-env/document-extraction
source ~/.aidevops/.agent-workspace/python-env/document-extraction/bin/activate
pip install docling extract-thinker presidio-analyzer presidio-anonymizer
```

### Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| RAM | 8GB | 16GB+ |
| GPU | None (CPU) | NVIDIA 8GB+ VRAM |
| Storage | 10GB | 50GB (for models) |

### Constraints

- Docling requires Python 3.10+ (dropped 3.9 in v2.70.0)
- ExtractThinker requires Python 3.9+
- Large models (70B) require significant VRAM or quantization
- OCR accuracy depends on document quality

### Security Considerations

- All credentials stored in `~/.config/aidevops/mcp-env.sh` (chmod 600)
- PII detection runs before any cloud API calls
- Local processing mode available for air-gapped environments
- Audit logging for all extraction operations

## Time Estimate Breakdown

| Phase | AI Time | Test Time | Total |
|-------|---------|-----------|-------|
| All subagents + scripts | 1h | - | 1h |
| Integration testing | - | 2h | 2h |
| **Total** | **1h** | **2h** | **3h** |

<!--TOON:time_breakdown[2]{phase,ai,test,total}:
implementation,1h,,1h
testing,,2h,2h
-->

## Success Metrics

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Invoice extraction accuracy | >95% | Test against 50 sample invoices |
| PII detection recall | >98% | Test against annotated dataset |
| Local processing speed | <30s/page | Benchmark on M1 Mac |
| Memory usage | <4GB | Monitor during batch processing |
| User adoption | 10+ users | GitHub stars/issues |

## Open Questions

- [ ] Should we support GPU acceleration via MLX on Apple Silicon?
- [ ] Should Presidio run as a separate service (Docker) or embedded?
- [ ] How to handle multi-language documents (OCR language detection)?
- [ ] Should we integrate with existing Unstract subagent or keep separate?
- [ ] What's the best approach for handling encrypted PDFs?

## Appendix

### Related Documents

- [Unstract Subagent](../../.agent/services/document-processing/unstract.md)
- [OCR Invoice/Receipt Extraction Pipeline](../PLANS.md#ocr-invoicereceipt-extraction-pipeline)
- [Pandoc Conversion Tool](../../.agent/tools/conversion/pandoc.md)

### External References

- [Docling Documentation](https://docling-project.github.io/docling/)
- [ExtractThinker Documentation](https://enoch3712.github.io/ExtractThinker/)
- [Microsoft Presidio Documentation](https://microsoft.github.io/presidio/)
- [Building On-Premise Document Intelligence Stack](https://pub.towardsai.net/building-an-on-premise-document-intelligence-stack-with-docling-ollama-phi-4-extractthinker-6ab60b495751)

### Revision History

| Date | Author | Changes |
|------|--------|---------|
| 2026-01-25 | aidevops | Initial draft |
