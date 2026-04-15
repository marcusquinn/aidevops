// t2121 driver — exercises makeStreamPullHandler + stripMcpPrefix against
// synthetic SSE chunks. Parent test extracts the function source via awk,
// prepends it to a copy of this file, and runs `node` against the result.
// The sibling test file contains only flat shell logic so the nesting-depth
// ratchet check never sees nested control-flow tokens inside heredocs.
//
// Scenarios selected by the T2121_CASE env var:
//   whole   — single chunk containing a complete SSE event (happy path)
//   split   — two chunks with the split mid-"mcp__aidevops__" token
//
// The driver writes OK / FAIL_* / ERROR to stdout and exits with a matching
// code so the test harness can assert success.

const CASE = process.env.T2121_CASE || "whole";
const EVENT = `data: {"type":"content_block_start","content_block":{"type":"tool_use","name":"mcp__aidevops__grep","input":{}}}\n`;

function buildChunks() {
  if (CASE === "split") {
    const splitAt = EVENT.indexOf("aide") + 2;
    return [EVENT.slice(0, splitAt), EVENT.slice(splitAt)];
  }
  return [EVENT];
}

async function run() {
  const encoder = new TextEncoder();
  const chunks = buildChunks();
  const stream = new ReadableStream({
    start(controller) {
      for (const c of chunks) controller.enqueue(encoder.encode(c));
      controller.close();
    },
  });

  const reader = stream.getReader();
  const pull = makeStreamPullHandler(reader, new TextDecoder(), new TextEncoder()); // eslint-disable-line no-undef
  const transformed = new ReadableStream({ pull });
  const outReader = transformed.getReader();
  const decoder = new TextDecoder();
  let output = "";
  let iter = 0;
  while (iter < 100) {
    iter++;
    const { done, value } = await outReader.read();
    if (done) break;
    output += decoder.decode(value, { stream: true });
  }
  output += decoder.decode();

  if (output.includes("mcp__aidevops__")) {
    console.log("FAIL_PREFIX_PRESENT " + JSON.stringify(output));
    process.exit(1);
  }
  if (!output.includes('"name":"grep"')) {
    console.log("FAIL_NAME_MISSING " + JSON.stringify(output));
    process.exit(2);
  }
  console.log("OK");
  process.exit(0);
}

run().catch((e) => {
  console.log("ERROR " + e.message);
  process.exit(3);
});
