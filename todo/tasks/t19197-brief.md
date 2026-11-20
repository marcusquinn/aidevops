## What

`higgsfield-helper.sh` cannot run any command: `playwright-automator.mjs` fails at module load because `higgsfield-pipeline.mjs` imports `generateLipsync`, `pollAndDownloadVideos` and `submitVideoJobOnPage` from `higgsfield-video.mjs`, which stopped exporting them in the GH#19223 decomposition (#19232, April 2026).

Evidence:

```text
$ higgsfield-helper.sh credits
SyntaxError: Export named 'submitVideoJobOnPage' not found in module '.../higgsfield/higgsfield-video.mjs'.
$ node -e "import('./playwright-automator.mjs')"
IMPORT_FAIL: The requested module './higgsfield-video.mjs' does not provide an export named 'generateLipsync'
```

## How

- Import `generateLipsync` from `./higgsfield-lipsync.mjs`, and `pollAndDownloadVideos` / `submitVideoJobOnPage` from `./higgsfield-batch-video.mjs` (both are exported there today).
- Re-run `verify-cluster.sh`; it also expects `higgsfield-video.mjs` to expose batch/lipsync symbols, so align that harness with the current module ownership.
- Found during implementation: `playwright-automator.mjs` imports 12 studio commands from `higgsfield-commands.mjs` that now live in `higgsfield-studio-commands.mjs`; `higgsfield-interruptions.mjs` reads `STATE_DIR` at module scope inside a common→browser→interruptions cycle (TDZ crash); its loader also crashes on older bare-array `known-interruptions.json` files; and the headed login's 60 s manual wait is too short for the emailed verification code.

## Files Scope

- `.agents/scripts/higgsfield/higgsfield-pipeline.mjs`
- `.agents/scripts/higgsfield/playwright-automator.mjs`
- `.agents/scripts/higgsfield/higgsfield-interruptions.mjs`
- `.agents/scripts/higgsfield/higgsfield-discovery.mjs`
- `.agents/scripts/higgsfield/verify-cluster.sh`

## Verification

- `node -e "import('./playwright-automator.mjs').then(()=>console.log('IMPORT_OK'))"` in `.agents/scripts/higgsfield/` prints `IMPORT_OK`.
- `.agents/scripts/higgsfield/verify-cluster.sh` passes.
- `higgsfield-helper.sh credits` reaches the browser/auth step instead of a SyntaxError.
