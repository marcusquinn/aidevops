# Reference

## Error Codes

| Code | Name | Description |
|------|------|-------------|
| 23505 | unique_violation | Duplicate key |
| 23503 | foreign_key_violation | FK constraint |
| 23502 | not_null_violation | NULL in NOT NULL |
| 23514 | check_violation | CHECK constraint |
| 42P01 | undefined_table | Table doesn't exist |

## PostgreSQL 18 Features

| Feature | Syntax |
|---------|--------|
| UUIDv7 | `SELECT uuidv7();` |
| Async I/O | `SET io_method = 'worker';` |
| Skip Scan | Automatic for B-tree |
| RETURNING OLD/NEW | `RETURNING OLD.col, NEW.col` |

## Quick Tips

1. **Use UUIDv7** over UUIDv4 for better index performance
2. **Use relational queries** to avoid N+1
3. **Add indexes** on foreign keys and frequently filtered columns
4. **Use partial indexes** for filtered subsets
5. **Use prepared statements** for repeated queries
6. **Set `shared_buffers`** to 25% of RAM
7. **Use `EXPLAIN ANALYZE`** to debug slow queries
8. **Use transactions** for related operations
9. **Use connection pooling** in production
10. **Run `generate` not `push`** for production migrations
