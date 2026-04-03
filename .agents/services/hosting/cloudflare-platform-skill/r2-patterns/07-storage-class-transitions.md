# R2 Pattern: Storage Class Transitions

Uses S3-compatible API (not Workers binding):

```typescript
const s3 = new S3Client({...});
await s3.send(new CopyObjectCommand({
  Bucket: 'my-bucket',
  Key: key,
  CopySource: `/my-bucket/${key}`,
  StorageClass: 'STANDARD_IA'
}));
```
