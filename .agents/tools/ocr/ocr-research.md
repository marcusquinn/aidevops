---
description: OCR research findings for invoice/receipt extraction pipeline (t012.1)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
---

# OCR Approaches Research (t012.1)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Recommendation**: Hybrid -- Docling (parse) + LLM vision (extract) + Pydantic (validate)
- **Reference implementation**: Midday.ai `packages/documents/` (Gemini + Mistral, Zod schemas)
- **Existing docs**: `extraction-schemas.md`, `document-extraction.md`, `extraction-workflow.md`

<!-- AI-CONTEXT-END -->

## Approach Categories

### 1. Traditional OCR + Rule-Based Parsing

OCR engine extracts raw text, then regex/template rules parse fields.

| Tool | Stars | License | Notes |
|------|-------|---------|-------|
| Tesseract | 64k+ | Apache-2.0 | Google, 100+ languages |
| PaddleOCR | 47k+ | Apache-2.0 | Baidu, strong CJK |
| EasyOCR | 25k+ | Apache-2.0 | 80+ languages, simple API |

**Verdict**: Not recommended as primary. Brittle rules, no semantic understanding. Useful as fallback OCR layer.

### 2. Layout-Aware Document Parsing + LLM Extraction

Document parser preserves layout/structure, then LLM extracts structured data via schema contracts.

| Tool | Stars | License | Notes |
|------|-------|---------|-------|
| Docling | 52.7k | MIT | IBM Research, PDF/DOCX/PPTX/images, table detection, MCP server |
| MinerU | 54.2k | AGPL-3.0 | PDF to markdown/JSON, layout-aware, formula support, 109 OCR languages |
| ExtractThinker | 1.5k | Apache-2.0 | ORM-style LLM extraction, Pydantic contracts, multi-loader |

**Verdict**: Recommended primary approach. Best accuracy for structured documents. Matches aidevops pipeline design (Docling + ExtractThinker). Requires LLM API calls and Python.

### 3. Vision LLM Direct Extraction

Send document image directly to vision-capable LLM, extract structured data in one pass.

| Model | Provider | Cost/1M tokens | Context | Notes |
|-------|----------|----------------|---------|-------|
| Gemini 2.5 Flash | Google | ~$0.15 in | 1M | Best cost/quality for documents |
| Gemini 2.5 Pro | Google | ~$1.25 in | 1M | Highest accuracy |
| GPT-4o | OpenAI | ~$2.50 in | 128k | Strong general vision |
| Claude Sonnet 4 | Anthropic | ~$3.00 in | 200k | Good structured extraction |
| GLM-OCR | Local (Ollama) | Free | ~8k | Purpose-built OCR, no structured output |
| MiniCPM-o | Local (Ollama) | Free | ~8k | Lightweight vision, 3GB VRAM |

**Verdict**: Recommended for receipt images/photos. Simplest pipeline (one API call), handles any format. Use as primary for images, fallback for PDFs. API costs scale with volume.

### 4. Cloud Document AI Services

Managed services with pre-trained invoice/receipt models.

| Service | Provider | Pricing | Notes |
|---------|----------|---------|-------|
| Azure Document Intelligence | Microsoft | $1.50/1k pages | Pre-built invoice/receipt models |
| AWS Textract | Amazon | $1.50/1k pages | Expense analysis, table extraction |
| Google Document AI | Google | $1.50/1k pages | Invoice parser, receipt parser |

**Verdict**: Not recommended. Vendor lock-in, data leaves infrastructure. LLM approach is more flexible and privacy-preserving.

## Midday.ai Implementation Analysis

Pontus Abrahamsson's Midday.ai (13.7k stars, AGPL-3.0) -- freelancer business tool with invoice/receipt extraction in `packages/documents/`.

### Architecture

```text
DocumentClient
├── InvoiceProcessor → BaseExtractionEngine (Primary: Gemini, Fallback: Mistral)
└── ReceiptProcessor → BaseExtractionEngine (same multi-model strategy)
```

### Key Design Decisions

1. **Zod schemas (not Pydantic)**: `z.object()` with `.describe()` -- descriptions serve as both validation AND extraction instructions
2. **Multi-model fallback**: Primary Gemini → Mistral on rate limits/failures, via `ai` SDK `generateObject()`
3. **Classification-first**: `document_type` field (invoice/receipt/other) classified before financial extraction
4. **Separate schemas**: Invoice (vendor/customer, line items with unit prices) vs Receipt (store/merchant, items with discounts, payment method)
5. **Tax type awareness**: Enum (VAT, GST, sales tax, withholding, reverse charge) -- not UK-specific
6. **Dual-input for PDFs**: Extracts text first (`extractTextFromPdf`), sends text + image to LLM for better accuracy
7. **Rate limit retry**: Dedicated `isRateLimitError()` with retry logic

### Differences from aidevops

| Aspect | Midday | aidevops (planned) |
|--------|--------|-------------------|
| Language | TypeScript/Zod | Python/Pydantic |
| LLM provider | Gemini + Mistral | Configurable (Ollama, OpenAI, Anthropic, Google) |
| Privacy | Cloud-only | Local-first (Ollama, Docling) |
| Tax handling | Generic (VAT/GST/sales tax) | UK-specific (VAT rates, nominal codes) |
| Accounting | Midday's own DB | QuickFile API |
| Document parsing | Direct vision LLM | Docling (layout-aware) + LLM |
| Batch processing | Per-document | Folder batch with auto-classification |

### Lessons to Adopt

1. **Dual-input**: Send both extracted text AND image to LLM for PDFs (text = exact numbers, image = layout context)
2. **Schema-as-prompt**: Field descriptions as extraction instructions (already in our Pydantic schemas)
3. **Classification-first**: Classify document type before extraction to select right schema
4. **Multi-model fallback**: Primary + fallback chain (aligns with aidevops model routing)
5. **Rate limit handling**: Explicit detection and retry

## Recommended Pipeline

```text
Input (PDF/image/photo)
  │
  ├─ PDF ──────────> Docling (parse, preserve layout, text + table + image extraction)
  ├─ Image/Photo ──> Direct to Vision LLM
  ▼
Document Classification (LLM)
  ├─ purchase-invoice ──> PurchaseInvoice schema
  ├─ expense-receipt ───> ExpenseReceipt schema
  ├─ credit-note ───────> CreditNote schema
  ├─ invoice ───────────> Invoice schema
  └─ other ─────────────> Skip / generic extraction
  ▼
Structured Extraction (ExtractThinker or direct LLM)
  │ Input: text + image (dual-input for PDFs)
  │ Schema: Pydantic model with field descriptions
  │ Model: Gemini Flash (primary) → Ollama (local fallback)
  ▼
Validation (VAT arithmetic, date format, confidence scoring, PII detection via Presidio)
  ▼
Output (JSON matching schema) → QuickFile Recording (t012.4)
```

### Model Selection

| Scenario | Model | Rationale |
|----------|-------|-----------|
| Cloud, cost-sensitive | Gemini 2.5 Flash | Best price/quality |
| Cloud, accuracy-critical | Gemini 2.5 Pro | Highest accuracy, 1M context |
| Local, privacy-required | Ollama + MiniCPM-o or Qwen2-VL | Free, on-device, 3-8GB VRAM |
| Local, OCR-only | GLM-OCR via Ollama | Purpose-built, 2GB |
| Batch processing | Gemini Flash with batching | Lowest per-document cost |

### Implementation Priority

1. **t012.1** (this task): Research complete -- this document
2. **t012.2** (done): Extraction schemas in `extraction-schemas.md`
3. **t012.3** (next): Pipeline implementation -- `document-extraction-helper.sh` with Docling + ExtractThinker, dual-input, multi-model fallback, confidence scoring
4. **t012.4**: QuickFile integration via `quickfile-helper.sh`
5. **t012.5**: Testing with diverse invoice/receipt formats

## Tool Installation

```bash
pip install docling                    # Document parsing (or "docling[all]" for all backends)
pip install extract-thinker            # LLM extraction (OpenAI, Anthropic, Google, Ollama, Azure)
pip install mineru                     # PDF to markdown (CLI: mineru -p invoice.pdf -o output/)
ollama pull glm-ocr                    # Local OCR (ollama run glm-ocr "Extract text" --images doc.png)
pip install presidio-analyzer presidio-anonymizer  # PII detection
```

## Cost Analysis (~50 invoices/receipts per month)

| Approach | Monthly Cost | Notes |
|----------|-------------|-------|
| Fully local (Ollama + Docling) | $0 | ~8GB RAM, slower |
| Gemini Flash | ~$0.05 | ~1000 tokens/doc |
| Gemini Pro | ~$0.40 | Complex multi-page invoices |
| Azure/AWS Document AI | ~$0.08 | $1.50/1000 pages |
| Midday approach (Gemini + Mistral) | ~$0.10 | With fallback calls |

**Recommendation**: Default to Gemini Flash (cloud) or Ollama (privacy). Cost difference negligible at freelancer volumes.

## Related Documents

- `extraction-schemas.md` -- Pydantic schema contracts with QuickFile mapping
- `document-extraction.md` -- Component reference (Docling, ExtractThinker, Presidio)
- `extraction-workflow.md` -- Pipeline orchestration and tool selection
- `glm-ocr.md` -- Local OCR via Ollama
- `../pdf/overview.md` -- PDF processing tools
- `../vision/image-understanding.md` -- Vision model comparison
