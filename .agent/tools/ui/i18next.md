---
description: i18next internationalization - translations, locales, namespaces
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

# i18next - Internationalization

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Multi-language support for React/Next.js applications
- **Libraries**: `i18next`, `react-i18next`, `next-i18n-router`
- **Docs**: Use Context7 MCP for current documentation

**Common Hazards** (from real sessions):

| Hazard | Problem | Solution |
|--------|---------|----------|
| Missing translation in some locales | Added key to `en` but forgot `de`, `es`, `fr` | Always update ALL locale files together |
| Nested key path wrong | `t("ai.sidebar.title")` returns key | Check JSON structure matches dot notation |
| Namespace not loaded | Translation returns key | Ensure namespace is loaded in component |
| Type safety | No autocomplete for keys | Use typed `useTranslation` hook |

**File Structure**:

```text
packages/i18n/src/translations/
├── en/
│   ├── common.json      # Shared UI strings
│   ├── marketing.json   # Marketing pages
│   └── dashboard.json   # Dashboard-specific
├── de/
│   └── common.json
├── es/
│   └── common.json
└── fr/
    └── common.json
```

**Adding New Translation Key**:

```bash
# 1. Add to English first
# packages/i18n/src/translations/en/common.json

# 2. Find same location in other locales
grep -n '"feedback":' packages/i18n/src/translations/*/common.json

# 3. Add to ALL locales at same position
```

**Translation JSON Pattern**:

```json
{
  "ai": {
    "sidebar": {
      "title": "Awards AI",
      "subtitle": "Your awards assistant",
      "open": "Open AI assistant",
      "close": "Close AI assistant",
      "placeholder": "Ask me anything...",
      "prompts": {
        "search": "Find relevant awards",
        "help": "Writing tips"
      }
    }
  }
}
```

**Usage in Components**:

```tsx
import { useTranslation } from "@workspace/i18n";

function Component() {
  const { t } = useTranslation("common");
  
  return (
    <div>
      <h1>{t("ai.sidebar.title")}</h1>
      <p>{t("ai.sidebar.subtitle")}</p>
      <button aria-label={t("ai.sidebar.open")}>
        Open
      </button>
    </div>
  );
}
```

**Locale-Specific Translations**:

| Locale | Example Key | Translation |
|--------|-------------|-------------|
| `en` | `social` | "Social" |
| `de` | `social` | "Soziale Medien" |
| `es` | `social` | "Redes sociales" |
| `fr` | `social` | "Réseaux sociaux" |

<!-- AI-CONTEXT-END -->

## Detailed Patterns

### Adding Translations to Multiple Locales

When adding a new key, update all locales:

```bash
# Find the insertion point in all locales
grep -n '"feedback"' packages/i18n/src/translations/*/common.json

# Output:
# de/common.json:44:  "feedback": "Feedback",
# en/common.json:44:  "feedback": "Feedback",
# es/common.json:44:  "feedback": "Comentarios",
# fr/common.json:44:  "feedback": "Commentaires",
```

Then add the new key after `feedback` in each file:

```json
// en/common.json
"feedback": "Feedback",
"social": "Social",

// de/common.json
"feedback": "Feedback",
"social": "Soziale Medien",

// es/common.json
"feedback": "Comentarios",
"social": "Redes sociales",

// fr/common.json
"feedback": "Commentaires",
"social": "Réseaux sociaux",
```

### Nested Translations

```json
{
  "ai": {
    "sidebar": {
      "welcome": {
        "title": "How can I help?",
        "description": "Ask me about finding awards..."
      }
    }
  }
}
```

```tsx
// Access nested keys with dot notation
t("ai.sidebar.welcome.title")
t("ai.sidebar.welcome.description")
```

### Interpolation

```json
{
  "greeting": "Hello, {{name}}!",
  "items": "You have {{count}} item",
  "items_plural": "You have {{count}} items"
}
```

```tsx
t("greeting", { name: "Marcus" })  // "Hello, Marcus!"
t("items", { count: 1 })           // "You have 1 item"
t("items", { count: 5 })           // "You have 5 items"
```

### Multiple Namespaces

```tsx
// Load multiple namespaces
const { t } = useTranslation(["common", "dashboard"]);

// Use namespace prefix
t("common:save")
t("dashboard:stats.title")
```

### Server Components (Next.js App Router)

```tsx
// Use server-side translation
import { getTranslation } from "@workspace/i18n/server";

export default async function Page({ params }) {
  const { locale } = await params;
  const { t } = await getTranslation(locale, "common");
  
  return <h1>{t("title")}</h1>;
}
```

### Type-Safe Translations

```tsx
// Define translation keys type
type TranslationKeys = 
  | "ai.sidebar.title"
  | "ai.sidebar.subtitle"
  | "ai.sidebar.open"
  | "ai.sidebar.close";

// Use with typed hook
const { t } = useTranslation<TranslationKeys>("common");
t("ai.sidebar.title"); // Autocomplete works!
```

## Common Mistakes

1. **Forgetting locale files**
   - Always update en, de, es, fr (or all configured locales)
   - Use grep to find insertion points

2. **Wrong namespace**
   - Check which JSON file contains the key
   - Use correct namespace in `useTranslation`

3. **Missing "use client"**
   - `useTranslation` hook requires client component
   - Use server translation for server components

4. **Key not found returns key**
   - Check JSON structure matches dot notation
   - Verify namespace is loaded

## Validation Script

```bash
# Check for missing keys across locales
for locale in de es fr; do
  echo "=== Missing in $locale ==="
  diff <(jq -r 'paths | join(".")' en/common.json | sort) \
       <(jq -r 'paths | join(".")' $locale/common.json | sort) \
       | grep "^<" | sed 's/^< //'
done
```

## Related

- `tools/ui/nextjs-layouts.md` - Locale routing in Next.js
- Context7 MCP for i18next documentation
