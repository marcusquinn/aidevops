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

- **Purpose**: Research findings for OCR invoice/receipt extraction pipeline
- **Recommendation**: Hybrid approach -- Docling (parse) + LLM vision (extract) + Pydantic (validate)
- **Reference implementation**: Midday.ai `packages/documents/` (Gemini + Mistral, Zod schemas)
- **Existing aidevops docs**: `extraction-schemas.md`, `document-extraction.md`, `extraction-workflow.md`
- **Task**: t012 OCR Invoice/Receipt Extraction Pipeline

<!-- AI-CONTEXT-END -->

## Approach Categories

There are four distinct approaches to OCR-based document extraction, each with different trade-offs:

### 1. Traditional OCR + Rule-Based Parsing

**How it works**: OCR engine extracts raw text, then regex/template rules parse fields.

| Tool | Stars | License | Language | Notes |
|------|-------|---------|----------|-------|
| Tesseract | 64k+ | Apache-2.0 | C++ | Google's OCR engine, 100+ languages |
| PaddleOCR | 47k+ | Apache-2.0 | Python | Baidu, strong on CJK scripts |
| EasyOCR | 25k+ | Apache-2.0 | Python | 80+ languages, simple API |

**Pros**: Free, fully local, fast, no API costs.
**Cons**: Brittle rules break on new invoice formats; no semantic understanding; poor on complex layouts.
**Verdict**: Not recommended as primary approach. Useful as a fallback OCR layer.

### 2. Layout-Aware Document Parsing + LLM Extraction

**How it works**: Document parser preserves layout/structure, then LLM extracts structured data using schema contracts.

| Tool | Stars | License | Language | Notes |
|------|-------|---------|----------|-------|
| Docling | 52.7k | MIT | Python | IBM Research, PDF/DOCX/PPTX/images, table detection, OCR, MCP server |
| MinerU | 54.2k | AGPL-3.0 | Python | PDF to markdown/JSON, layout-aware, formula support, 109 OCR languages |
| ExtractThinker | 1.5k | Apache-2.0 | Python | ORM-style LLM extraction, Pydantic contracts, multi-loader support |

**Pros**: Best accuracy for structured documents; handles diverse formats; schema-validated output.
**Cons**: Requires LLM API calls (cost); Python dependency; slower than pure OCR.
**Verdict**: Recommended primary approach. Matches existing aidevops pipeline design (Docling + ExtractThinker).

### 3. Vision LLM Direct Extraction

**How it works**: Send document image directly to a vision-capable LLM, extract structured data in one pass.

| Model | Provider | Cost (per 1M tokens) | Context | Notes |
|-------|----------|---------------------|---------|-------|
| Gemini 2.5 Flash | Google | ~$0.15 input | 1M tokens | Best cost/quality for documents |
| Gemini 2.5 Pro | Google | ~$1.25 input | 1M tokens | Highest accuracy |
| GPT-4o | OpenAI | ~$2.50 input | 128k | Strong general vision |
| Claude Sonnet 4 | Anthropic | ~$3.00 input | 200k | Good structured extraction |
| GLM-OCR | Local (Ollama) | Free | ~8k | Purpose-built OCR, no structured output |
| MiniCPM-o | Local (Ollama) | Free | ~8k | Lightweight vision, 3GB VRAM |

**Pros**: Simplest pipeline (one API call); handles any format; no preprocessing needed; best for photos of receipts.
**Cons**: API costs scale with volume; no local-only option for structured output; less deterministic.
**Verdict**: Recommended for receipt images and photos. Use as primary for image inputs, fallback for PDFs.

### 4. Cloud Document AI Services

**How it works**: Managed services with pre-trained models for invoice/receipt extraction.

| Service | Provider | Pricing | Notes |
|---------|----------|---------|-------|
| Azure Document Intelligence | Microsoft | $1.50/1000 pages | Pre-built invoice/receipt models |
| AWS Textract | Amazon | $1.50/1000 pages | Expense analysis, table extraction |
| Google Document AI | Google | $1.50/1000 pages | Invoice parser, receipt parser |

**Pros**: High accuracy out of the box; no model management; enterprise support.
**Cons**: Vendor lock-in; data leaves your infrastructure; per-page pricing adds up; overkill for low volume.
**Verdict**: Not recommended for aidevops. The LLM-based approach is more flexible and privacy-preserving.

## Midday.ai Implementation Analysis

Pontus Abrahamsson's Midday.ai (13.7k stars, AGPL-3.0) is a freelancer business tool with invoice/receipt extraction in `packages/documents/`. Key findings:

### Architecture

```text
DocumentClient
├── InvoiceProcessor (PDF invoices)
│   └── BaseExtractionEngine
│       ├── Primary: Gemini (google generative AI)
│       └── Fallback: Mistral
└── ReceiptProcessor (receipt images)
    └── BaseExtractionEngine
        └── Same multi-model strategy
```

### Key Design Decisions

1. **Zod schemas (not Pydantic)**: TypeScript-native, uses `z.object()` with `.describe()` for LLM prompting. The schema descriptions serve dual purpose -- validation AND extraction instructions.

2. **Multi-model extraction with fallback**: Primary model (Gemini) with automatic fallback to Mistral on rate limits or failures. Uses `ai` SDK's `generateObject()` for structured output.

3. **Document classification first**: Schema includes `document_type` field (invoice/receipt/other) that the LLM classifies before extracting financial fields. Non-financial documents get null financial fields.

4. **Separate schemas for invoices vs receipts**: Invoice schema has vendor/customer fields, line items with unit prices. Receipt schema has store/merchant fields, items with discounts, payment method.

5. **Tax type awareness**: Enum of tax types (VAT, GST, sales tax, withholding, reverse charge, etc.) -- not UK-specific like our schemas.

6. **PDF text extraction as context**: For PDF invoices, extracts text first (`extractTextFromPdf`) and provides it alongside the image to the LLM, improving accuracy.

7. **Retry with rate limit detection**: Dedicated `isRateLimitError()` check with retry logic.

### Differences from aidevops Approach

| Aspect | Midday | aidevops (planned) |
|--------|--------|-------------------|
| Language | TypeScript/Zod | Python/Pydantic |
| LLM provider | Gemini + Mistral | Configurable (Ollama, OpenAI, Anthropic, Google) |
| Privacy | Cloud-only (Gemini API) | Local-first (Ollama, Docling) |
| Tax handling | Generic (VAT/GST/sales tax) | UK-specific (VAT rates, nominal codes) |
| Accounting integration | Midday's own DB | QuickFile API |
| Document parsing | Direct vision LLM | Docling (layout-aware) + LLM |
| Batch processing | Per-document | Folder batch with auto-classification |

### Lessons to Adopt

1. **Dual-input strategy**: Send both extracted text AND image to the LLM for PDFs. Text provides exact numbers; image provides layout context.
2. **Schema-as-prompt**: Use field descriptions as extraction instructions (already in our Pydantic schemas).
3. **Classification-first**: Classify document type before extraction to select the right schema.
4. **Multi-model fallback**: Primary model + fallback chain (aligns with aidevops model routing).
5. **Rate limit handling**: Explicit rate limit detection and retry.

## Recommended Pipeline for aidevops

Based on this research, the recommended pipeline combines the best of each approach:

### Pipeline Architecture

```text
Input (PDF/image/photo)
  │
  ├─ PDF ──────────> Docling (parse, preserve layout)
  │                    ├─ Text extraction
  │                    ├─ Table detection
  │                    └─ Image extraction
  │
  ├─ Image/Photo ──> Direct to Vision LLM
  │
  ▼
Document Classification (LLM)
  │
  ├─ purchase-invoice ──> PurchaseInvoice schema
  ├─ expense-receipt ───> ExpenseReceipt schema
  ├─ credit-note ───────> CreditNote schema
  ├─ invoice ───────────> Invoice schema
  └─ other ─────────────> Skip / generic extraction
  │
  ▼
Structured Extraction (ExtractThinker or direct LLM)
  │ Input: text + image (dual-input for PDFs)
  │ Schema: Pydantic model with field descriptions
  │ Model: Gemini Flash (primary) → Ollama (local fallback)
  │
  ▼
Validation
  │ VAT arithmetic check
  │ Date format validation
  │ Confidence scoring per field
  │ PII detection (Presidio, optional)
  │
  ▼
Output (JSON matching schema)
  │
  ▼
QuickFile Recording (t012.4)
```

### Model Selection for Extraction

| Scenario | Recommended Model | Rationale |
|----------|------------------|-----------|
| Cloud, cost-sensitive | Gemini 2.5 Flash | Best price/quality for documents |
| Cloud, accuracy-critical | Gemini 2.5 Pro | Highest accuracy, 1M context |
| Local, privacy-required | Ollama + MiniCPM-o or Qwen2-VL | Free, on-device, 3-8GB VRAM |
| Local, OCR-only (no structured output) | GLM-OCR via Ollama | Purpose-built OCR, 2GB |
| Batch processing | Gemini Flash with batching | Lowest per-document cost |

### Implementation Priority

1. **t012.1** (this task): Research complete. Deliverable: this document.
2. **t012.2** (done): Extraction schemas designed in `extraction-schemas.md`.
3. **t012.3** (next): Implement the pipeline:
   - `document-extraction-helper.sh` with Docling + ExtractThinker
   - Dual-input (text + image) for PDFs
   - Multi-model support with fallback chain
   - Confidence scoring and validation
4. **t012.4**: QuickFile integration via `quickfile-helper.sh`
5. **t012.5**: Testing with diverse invoice/receipt formats

## Tool Installation Reference

### Docling (Document Parsing)

```bash
pip install docling
# Or with all backends:
pip install "docling[all]"
# CLI usage:
docling invoice.pdf --output markdown
# MCP server available for agent integration
```

### ExtractThinker (LLM Extraction)

```bash
pip install extract_thinker
# Supports: OpenAI, Anthropic, Google, Ollama, Azure
# ORM-style: define Pydantic contract, call extractor.extract()
```

### MinerU (PDF to Markdown)

```bash
pip install mineru
# CLI:
mineru -p invoice.pdf -o output/
# Hybrid backend (recommended): combines pipeline + VLM
```

### GLM-OCR (Local OCR)

```bash
ollama pull glm-ocr
# Usage:
ollama run glm-ocr "Extract all text from this document" --images invoice.png
```

### Presidio (PII Detection)

```bash
pip install presidio-analyzer presidio-anonymizer
# Detects: names, addresses, phone numbers, emails, credit cards, etc.
```

## Cost Analysis

For a freelancer processing ~50 invoices/receipts per month:

| Approach | Monthly Cost | Notes |
|----------|-------------|-------|
| Fully local (Ollama + Docling) | $0 | Requires ~8GB RAM, slower |
| Gemini Flash | ~$0.05 | ~1000 tokens per document |
| Gemini Pro | ~$0.40 | For complex multi-page invoices |
| Azure/AWS Document AI | ~$0.08 | $1.50/1000 pages |
| Midday approach (Gemini + Mistral) | ~$0.10 | With fallback calls |

**Recommendation**: Default to Gemini Flash for cloud users, Ollama for privacy-conscious users. The cost difference is negligible at freelancer volumes.

## Related Documents

- `extraction-schemas.md` - Pydantic schema contracts with QuickFile mapping
- `document-extraction.md` - Component reference (Docling, ExtractThinker, Presidio)
- `extraction-workflow.md` - Pipeline orchestration and tool selection
- `glm-ocr.md` - Local OCR via Ollama
- `../pdf/overview.md` - PDF processing tools
- `../vision/image-understanding.md` - Vision model comparison
