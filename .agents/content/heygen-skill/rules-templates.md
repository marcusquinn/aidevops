---
name: templates
description: Template listing and variable replacement for HeyGen videos
metadata:
  tags: templates, variables, personalization, batch
---

# Video Templates

Reusable video structures with variable placeholders for personalized generation at scale.

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/v2/templates` | List all templates |
| GET | `/v2/template/{template_id}` | Get template details |
| POST | `/v2/template/{template_id}/generate` | Generate video from template |

## List Templates

```bash
curl -X GET "https://api.heygen.com/v2/templates" \
  -H "X-Api-Key: $HEYGEN_API_KEY"
```

**Response shape:**

```json
{
  "error": null,
  "data": {
    "templates": [{
      "template_id": "template_abc123",
      "name": "Product Announcement",
      "thumbnail_url": "https://files.heygen.ai/...",
      "variables": [
        { "name": "product_name", "type": "text", "properties": { "max_length": 50 } },
        { "name": "presenter_script", "type": "text", "properties": { "max_length": 500 } },
        { "name": "product_image", "type": "image" }
      ]
    }]
  }
}
```

```typescript
interface TemplateVariable {
  name: string;
  type: "text" | "image" | "audio";
  properties?: { max_length?: number; default_value?: string };
}

interface Template {
  template_id: string;
  name: string;
  thumbnail_url: string;
  variables: TemplateVariable[];
}
```

## Generate from Template

### Request Fields

| Field | Type | Req | Description |
|-------|------|:---:|-------------|
| `variables` | object | Y | Key-value pairs matching template variable names |
| `test` | boolean | | Watermarked output, no credits consumed |
| `title` | string | | Video name for organization |
| `callback_id` | string | | Custom ID for webhook tracking |
| `callback_url` | string | | URL for completion notification |

```bash
curl -X POST "https://api.heygen.com/v2/template/{template_id}/generate" \
  -H "X-Api-Key: $HEYGEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "test": false,
    "variables": {
      "product_name": "SuperWidget Pro",
      "presenter_script": "Introducing our latest innovation!",
      "product_image": "https://example.com/product.jpg"
    }
  }'
```

```typescript
async function generateFromTemplate(
  templateId: string,
  variables: Record<string, string>,
  test = false
): Promise<string> {
  const res = await fetch(`https://api.heygen.com/v2/template/${templateId}/generate`, {
    method: "POST",
    headers: { "X-Api-Key": process.env.HEYGEN_API_KEY!, "Content-Type": "application/json" },
    body: JSON.stringify({ test, variables }),
  });
  const { error, data } = await res.json();
  if (error) throw new Error(error);
  return data.video_id;
}
```

## Variable Types

| Type | Value format | Example keys |
|------|-------------|--------------|
| `text` | Plain string (respect `max_length`) | `customer_name`, `cta_text`, `price` |
| `image` | Public URL (HTTPS) | `product_image`, `logo`, `background` |
| `audio` | Public URL (HTTPS) | `background_music`, `custom_voiceover` |

## Validation

```typescript
function validateTemplateVariables(
  template: Template,
  variables: Record<string, string>
): { valid: boolean; errors: string[] } {
  const errors: string[] = [];
  for (const v of template.variables) {
    const val = variables[v.name];
    if (!val) { errors.push(`Missing: ${v.name}`); continue; }
    if (v.type === "text" && v.properties?.max_length && val.length > v.properties.max_length)
      errors.push(`"${v.name}" exceeds max_length ${v.properties.max_length}`);
    if ((v.type === "image" || v.type === "audio") && !URL.canParse(val))
      errors.push(`"${v.name}" is not a valid URL`);
  }
  return { valid: errors.length === 0, errors };
}
```

## Batch Generation

Loop with 1s delay between requests to avoid rate limits:

```typescript
const videoIds: string[] = [];
for (const r of recipients) {
  const videoId = await generateFromTemplate(templateId, {
    recipient_name: r.name,
    company_name: r.company,
    personalized_message: r.customMessage,
  });
  videoIds.push(videoId);
  await new Promise((res) => setTimeout(res, 1000));
}
```

## Best Practices

- Use `test: true` to verify layout before production runs
- Cache template details — avoid repeated GET calls per batch item
- Validate all variables (presence + length + URL format) before generating
- Define `max_length` on text variables in the template to prevent truncation
- Use `callback_url` for large batches instead of polling

Full workflow: list templates (GET `/v2/templates`) → `validateTemplateVariables` → `generateFromTemplate` → `waitForVideo` (see `rules-video-status.md`)

## Use Cases

| Use case | Key variables |
|----------|--------------|
| Sales outreach | `recipient_name`, `company_name`, `personalized_message` |
| Customer onboarding | `customer_name`, `product_name` |
| Product announcements | `product_name`, `product_image`, `offer_details` |
| Training modules | `trainee_name`, `module_title`, `presenter_script` |
| Marketing campaigns | `cta_text`, `promo_code`, `background` |
