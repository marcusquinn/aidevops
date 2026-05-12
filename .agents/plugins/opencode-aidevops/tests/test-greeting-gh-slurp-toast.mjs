import assert from "node:assert/strict";
import test from "node:test";

import { buildToast, classifyLines } from "../greeting.mjs";

test("old gh prerequisite warning becomes OpenCode warning toast", () => {
  const warningLine =
    "[WARN] GitHub CLI (gh) 2.50.0 is too old; gh api --paginate --slurp requires gh >= 2.51.0. Run aidevops setup to upgrade gh.";
  const buckets = classifyLines(`aidevops v3.15.32 running in OpenCode v1.14.48\n${warningLine}`);

  assert.deepEqual(buckets.warning, [warningLine]);
  assert.equal(buckets.error.length, 0);

  const toast = buildToast(buckets);
  assert.equal(toast.variant, "warning");
  assert.equal(toast.duration, 15000);
  assert.match(toast.message, /GitHub CLI \(gh\) 2\.50\.0 is too old/);
  assert.match(toast.message, /aidevops v3\.15\.32 running in OpenCode/);
});
