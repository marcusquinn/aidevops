---
description: i18next internationalization - translations, locales, namespaces
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

# i18next - Internationalization

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Libraries**: `i18next`, `react-i18next`, `next-i18n-router`
- **Docs**: Use Context7 MCP for current documentation

**Common Hazards**:

| Hazard | Problem | Fix |
|--------|---------|-----|
| Missing locale | Added key to `en` but forgot `de`, `es`, `fr` | Update ALL locale files together |
| Wrong key path | `t("ai.sidebar.title")` returns key | Check JSON structure matches dot notation |
| Namespace not loaded | Translation returns key | Ensure namespace is loaded in component |
| No type safety | No autocomplete for keys | Use typed `useTranslation` hook |

**File Structure**:

```text
packages/i18n/src/translations/
├── en/
│   ├── common.json      # Shared UI strings
│   ├── marketing.json   # Marketing pages
│   └── dashboard.json   # Dashboard-specific
├── de/
├── es/
└── fr/
    └── common.json      # (same namespaces per locale)
```

**Adding a New Key** — update all locales at the same position:

```bash
# Find insertion point across all locales
grep -n '"feedback":' packages/i18n/src/translations/*/common.json
# Then add the new key after "feedback" in each locale file
```

<!-- AI-CONTEXT-END -->

## Patterns

### Translation JSON + Component Usage

```json
{
  "ai": {
    "sidebar": {
      "title": "Awards AI",
      "subtitle": "Your awards assistant",
      "open": "Open AI assistant",
      "close": "Close AI assistant",
      "placeholder": "Ask me anything...",
      "prompts": { "search": "Find relevant awards", "help": "Writing tips" }
    }
  }
}
```

```tsx
import { useTranslation } from "@workspace/i18n";

function Component() {
  const { t } = useTranslation("common");
  return (
    <div>
      <h1>{t("ai.sidebar.title")}</h1>
      <button aria-label={t("ai.sidebar.open")}>Open</button>
    </div>
  );
}
```

### Nested Keys

```tsx
// Access nested keys with dot notation
t("ai.sidebar.welcome.title")
t("ai.sidebar.welcome.description")
```

### Interpolation + Plurals

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
const { t } = useTranslation(["common", "dashboard"]);
t("common:save")
t("dashboard:stats.title")
```

### Server Components (Next.js App Router)

```tsx
import { getTranslation } from "@workspace/i18n/server";

// Next.js 15+: params is a Promise
export default async function Page({ params }: { params: { locale: string } }) {
  const { locale } = params;
  const { t } = await getTranslation(locale, "common");
  return <h1>{t("title")}</h1>;
}

// Next.js 14 and earlier: params is NOT a Promise
// const { t } = await getTranslation(params.locale, "common");
```

### Type-Safe Translations

```tsx
type TranslationKeys =
  | "ai.sidebar.title"
  | "ai.sidebar.subtitle"
  | "ai.sidebar.open"
  | "ai.sidebar.close";

const { t } = useTranslation<TranslationKeys>("common");
t("ai.sidebar.title"); // Autocomplete works!
```

## Validation Script

```bash
#!/usr/bin/env bash
set -euo pipefail

# Check for missing translation keys across locales
# Run from repository root

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }

BASE_LOCALE="en"
TARGET_LOCALES=("de" "es" "fr")
NAMESPACE="common"

cd packages/i18n/src/translations

if [[ ! -f "${BASE_LOCALE}/${NAMESPACE}.json" ]]; then
  echo "Error: Base locale file ${BASE_LOCALE}/${NAMESPACE}.json not found" >&2
  exit 1
fi

for locale in "${TARGET_LOCALES[@]}"; do
  if [[ ! -f "${locale}/${NAMESPACE}.json" ]]; then
    echo "Warning: ${locale}/${NAMESPACE}.json not found, skipping" >&2
    continue
  fi
  echo "=== Missing in ${locale} ==="
  diff <(jq -r 'paths | join(".")' "${BASE_LOCALE}/${NAMESPACE}.json" | sort) \
       <(jq -r 'paths | join(".")' "${locale}/${NAMESPACE}.json" | sort) \
       | grep "^<" | sed 's/^< //' || true
done
```

## Related

- `tools/ui/nextjs-layouts.md` - Locale routing in Next.js
- Context7 MCP for i18next documentation
