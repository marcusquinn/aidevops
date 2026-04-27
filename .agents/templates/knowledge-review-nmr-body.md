<!-- aidevops:knowledge-review source_id:{{SOURCE_ID}} -->

## Knowledge Source Review Request

A new knowledge source requires review before promotion to `sources/`.

| Field | Value |
|-------|-------|
| Source ID | `{{SOURCE_ID}}` |
| Kind | {{KIND}} |
| SHA256 | `{{SHA256}}` |
| Size | {{SIZE_BYTES}} bytes |
| Ingested by | {{INGESTED_BY}} |
| Sensitivity | {{SENSITIVITY}} |
| Trust class | {{TRUST_CLASS}} |

## Why This Requires Review

Trust class `{{TRUST_CLASS}}` requires maintainer sign-off before the source
can be promoted to versioned `sources/` storage. Review the preview below and
verify the content is safe to commit.

## Review Actions

**Approve** (promote source to `sources/` and close this issue):

```bash
sudo aidevops approve issue <this-issue-number>
```

This triggers `knowledge-review-helper.sh promote {{SOURCE_ID}}`, which moves
the source from `_knowledge/staging/{{SOURCE_ID}}/` to
`_knowledge/sources/{{SOURCE_ID}}/` and updates the audit log.

**Reject** (keep source in staging, do not promote):

Close the issue without approving. The source stays in
`_knowledge/staging/{{SOURCE_ID}}/` indefinitely.

## Source Location

Staged at: `_knowledge/staging/{{SOURCE_ID}}/`

<!-- preview appended by knowledge-review-helper.sh -->
