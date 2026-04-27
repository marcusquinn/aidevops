# Markdoc Tag Schemas

Canonical JSON schemas for the aidevops Markdoc tag namespace. These schemas define the attributes, types, scope rules, and examples for each tag. All subsequent phases (validator, extractor, migration, consumers) parse against these schemas as the single source of truth.

## Namespace Convention

Tags follow the [Markdoc tag grammar](https://markdoc.dev/docs/tags):

- **Block tags** (wrap content): `{% tag attr="value" %} ... {% /tag %}`
- **Self-closing tags** (inline markers): `{% tag attr="value" /%}`

Tag names are lowercase, hyphenated. Attribute values use double quotes for strings; numbers are unquoted.

## Tag Inventory

| Tag | Scope | Description |
|-----|-------|-------------|
| `sensitivity` | file, section, inline | Data-sensitivity classification tier |
| `provenance` | file, section | Source origin and extraction metadata |
| `case-attach` | section, inline | Links content to a legal/business case |
| `citation` | inline | Inline source citation with optional page reference |
| `redaction` | section, inline | Marks content for redaction in output |
| `draft-status` | file, section | Editorial lifecycle status tracking |
| `link` | inline | Typed link with semantic kind classification |

## Schema Structure

Each JSON schema file contains:

- `name` — tag identifier (matches filename without extension)
- `description` — purpose and usage context
- `attributes` — object with each attribute's `type`, `required`, `enum` (where applicable), and `description`
- `scope_rules` — `allowed` array (file/section/inline) and scope `description`
- `example` — valid Markdoc syntax demonstrating the tag

## Validation

```bash
# Verify all schemas are valid JSON
for f in .agents/tools/markdoc/schemas/*.json; do jq . "$f" > /dev/null && echo "OK: $f"; done
```

## Parent Task

Decomposition child of t2874 (parent: GH#20966). Phase 1 of 5.
