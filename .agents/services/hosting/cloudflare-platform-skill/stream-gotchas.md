<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Stream Gotchas

Common errors, troubleshooting, limits, and security.

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `ERR_NON_VIDEO` | Not a valid video format | Use MP4, MKV, MOV, AVI, FLV, MPEG-2 TS/PS, MXF, LXF, GXF, 3GP, WebM, MPG, or QuickTime |
| `ERR_DURATION_EXCEED_CONSTRAINT` | Exceeds `maxDurationSeconds` | Increase `maxDurationSeconds` or trim video |
| `ERR_FETCH_ORIGIN_ERROR` | Cannot download from URL | Ensure URL is publicly accessible and uses HTTPS |
| `ERR_MALFORMED_VIDEO` | Corrupted or improperly encoded | Re-encode with FFmpeg; check source file integrity |
| `ERR_DURATION_TOO_SHORT` | Under 0.1 seconds | Ensure video has valid duration |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Stuck in "inprogress" | Processing large/complex video | Wait up to 5 min; use webhooks instead of polling |
| Signed URL returns 403 | Token expired or invalid signature | Check expiration, verify JWK, ensure clock sync |
| Live stream won't connect | Invalid RTMPS URL or stream key | Use exact URL/key from API; allow outbound port 443 |
| Webhook signature fails | Wrong secret or timestamp window | Use exact secret from setup; allow 5-min timestamp drift |
| Uploaded but not visible | `requireSignedURLs` enabled without token | Generate signed token or set `requireSignedURLs: false` |
| Player infinite loading | CORS / `allowedOrigins` mismatch | Add your domain to `allowedOrigins` |

## Limits

| Resource | Limit |
|----------|-------|
| Max file size | 30 GB |
| Max frame rate | 60 fps (recommended) |
| Max duration (direct upload) | Configurable via `maxDurationSeconds` |
| Token generation (API) | 1,000/day recommended (signing keys for higher) |
| Live input outputs (simulcast) | 5 per live input |
| Webhook retries | 5 (exponential backoff) |
| Webhook timeout | 30 seconds |
| Caption file size | 5 MB |
| Watermark image size | 2 MB |
| Metadata keys per video | Unlimited |
| Search results per page | Max 1,000 |

## Performance

| Issue | Fix |
|-------|-----|
| Slow upload | Use TUS resumable upload; compress video; check bandwidth |
| Playback buffering | Use ABR (HLS/DASH); reduce max bitrate |
| High processing time | Pre-encode with H.264; reduce resolution |

## Type Safety

```typescript
// Error response type
interface StreamError {
  success: false;
  errors: Array<{
    code: number;
    message: string;
  }>;
}

// Handle errors
async function uploadWithErrorHandling(url: string, file: File) {
  const formData = new FormData();
  formData.append('file', file);
  const response = await fetch(url, { method: 'POST', body: formData });
  const result = await response.json();

  if (!result.success) {
    throw new Error(result.errors[0]?.message || 'Upload failed');
  }
  return result;
}
```

## Security Gotchas

1. **Never expose API token in frontend** — use direct creator uploads
2. **Always verify webhook signatures** — prevent spoofed notifications
3. **Set short token expiration** — minimize exposure window
4. **Use `requireSignedURLs` for private content** — prevent unauthorized access
5. **Whitelist `allowedOrigins`** — prevent hotlinking on unauthorized sites

## In This Reference

- [stream.md](./stream.md) — Overview and quick start
- [stream-patterns.md](./stream-patterns.md) — Full-stack flows, best practices

## See Also

- [workers](../workers/) — Deploy Stream APIs securely
