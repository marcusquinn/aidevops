#!/usr/bin/env bash
# Cluster verification: parse + import + qlty smells
# t2072: characterisation harness — verifies higgsfield/*.mjs cluster post-refactor
set -euo pipefail

cd "$(dirname "$0")"
fail=0

echo "=== 1. Parse check ==="
for f in higgsfield-*.mjs playwright-automator.mjs; do
	if [ -f "$f" ]; then
		if node --check "$f" 2>&1; then
			echo "PARSE_OK $f"
		else
			echo "PARSE_FAIL $f"
			fail=1
		fi
	fi
done

echo
echo "=== 2. Import resolution ==="
if node -e "import('./playwright-automator.mjs').then(() => console.log('IMPORT_OK')).catch(e => { console.error('IMPORT_FAIL:', e.message); process.exit(1); })" >/tmp/higgsfield-import.log 2>&1; then
	tail -1 /tmp/higgsfield-import.log
else
	echo "IMPORT_FAIL — see /tmp/higgsfield-import.log"
	cat /tmp/higgsfield-import.log
	fail=1
fi

echo
echo "=== 3. CLI dispatcher exports (parseArgs called) ==="
if node -e "
import('./higgsfield-common.mjs').then(m => {
  const required = ['parseArgs','withRetry','launchBrowser','dismissAllModals','BASE_URL','STATE_FILE','GENERATED_IMAGE_SELECTOR'];
  const missing = required.filter(k => typeof m[k] === 'undefined');
  if (missing.length) { console.error('MISSING from common:', missing.join(',')); process.exit(1); }
  console.log('COMMON_EXPORTS_OK');
}).catch(e => { console.error(e.message); process.exit(1); });
" 2>&1; then
	:
else
	fail=1
fi

if node -e "
import('./higgsfield-api.mjs').then(m => {
  const required = ['apiGenerateImage','apiGenerateVideo','apiStatus'];
  const missing = required.filter(k => typeof m[k] === 'undefined');
  if (missing.length) { console.error('MISSING from api:', missing.join(',')); process.exit(1); }
  console.log('API_EXPORTS_OK');
}).catch(e => { console.error(e.message); process.exit(1); });
" 2>&1; then
	:
else
	fail=1
fi

if node -e "
import('./higgsfield-image.mjs').then(m => {
  const required = ['generateImage','batchImage','waitForImageGeneration'];
  const missing = required.filter(k => typeof m[k] === 'undefined');
  if (missing.length) { console.error('MISSING from image:', missing.join(',')); process.exit(1); }
  console.log('IMAGE_EXPORTS_OK');
}).catch(e => { console.error(e.message); process.exit(1); });
" 2>&1; then
	:
else
	fail=1
fi

if node -e "
import('./higgsfield-video.mjs').then(m => {
  const required = ['generateVideo','generateLipsync','batchVideo','batchLipsync','downloadFromHistory','downloadVideoFromApiData','matchJobSetsToSubmittedJobs','downloadMatchedVideos'];
  const missing = required.filter(k => typeof m[k] === 'undefined');
  if (missing.length) { console.error('MISSING from video:', missing.join(',')); process.exit(1); }
  console.log('VIDEO_EXPORTS_OK');
}).catch(e => { console.error(e.message); process.exit(1); });
" 2>&1; then
	:
else
	fail=1
fi

if node -e "
import('./higgsfield-commands.mjs').then(m => {
  const required = ['pipeline','seedBracket','useApp','screenshot','checkCredits','listAssets','manageAssets','assetChain','mixedMediaPreset','motionPreset','cinemaStudio','motionControl','editImage','upscale','editVideo','storyboard','vibeMotion','aiInfluencer','createCharacter','featurePage','authHealthCheck','smokeTest','runSelfTests'];
  const missing = required.filter(k => typeof m[k] === 'undefined');
  if (missing.length) { console.error('MISSING from commands:', missing.join(',')); process.exit(1); }
  console.log('COMMANDS_EXPORTS_OK');
}).catch(e => { console.error(e.message); process.exit(1); });
" 2>&1; then
	:
else
	fail=1
fi

echo
echo "=== 4. qlty smells in cluster ==="
if command -v ~/.qlty/bin/qlty >/dev/null 2>&1; then
	sarif=$(cd "$(git rev-parse --show-toplevel)" && ~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null)
	if [[ -n "$sarif" ]]; then
		results=$(echo "$sarif" | jq '[.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("higgsfield/"))]')
		count=$(echo "$results" | jq 'length')
		echo "qlty smells in higgsfield/: ${count:-0}"
		if [[ "${count:-0}" -gt 0 ]]; then
			echo "$results" | jq -r '.[] | "\(.locations[0].physicalLocation.artifactLocation.uri):\(.locations[0].physicalLocation.region.startLine)\t\(.ruleId)\t\(.message.text)"'
		fi
	fi
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "=== ALL CHECKS PASSED ==="
	exit 0
else
	echo "=== CHECKS FAILED ==="
	exit 1
fi
