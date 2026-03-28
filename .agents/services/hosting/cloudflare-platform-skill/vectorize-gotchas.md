# Vectorize Gotchas & Troubleshooting

## Common Mistakes

**Do:**

1. Create metadata indexes BEFORE inserting vectors (existing vectors not retroactively indexed)
2. Use `upsert` for updates -- `insert` ignores duplicates
3. Batch 1000-2500 vectors per operation for optimal throughput
4. Use `returnMetadata: "indexed"` for speed, `"all"` only when needed
5. Use namespace filtering instead of metadata when possible (faster)
6. Handle async operations -- inserts/upserts take seconds to be queryable

**Don't:**

1. Pass wrong data shape: Workers AI -> `embeddings.data[0]`; OpenAI -> `response.data[0].embedding`
2. Return all values/metadata by default -- impacts performance and topK limit
3. Use high-cardinality range queries -- bucket or use discrete values
4. Forget `npx wrangler types` after config changes

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Vectors not appearing | Wait 5-10s; check `wrangler vectorize info <index>` for mutation processing |
| Dimension mismatch | Verify query vector length matches index dimensions exactly |
| Filter not working | Verify metadata index exists (`list-metadata-index`); re-upsert vectors after creating index |
| Performance issues | Reduce topK with returnValues/returnMetadata; simplify filters; batch operations |
