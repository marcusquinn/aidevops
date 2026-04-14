/**
 * Server message dispatching and exec rejection for cursor/proxy.js.
 * Extracted to keep per-file complexity below the threshold.
 */

import { create, toBinary, fromBinary } from "@bufbuild/protobuf";
import {
  AgentClientMessageSchema, AgentServerMessageSchema,
  ExecClientMessageSchema, KvClientMessageSchema,
  GetBlobResultSchema, SetBlobResultSchema,
  RequestContextSchema, RequestContextResultSchema, RequestContextSuccessSchema,
  McpResultSchema, McpSuccessSchema, McpErrorSchema, McpTextContentSchema, McpToolResultContentItemSchema,
  BackgroundShellSpawnResultSchema, DeleteResultSchema, DeleteRejectedSchema,
  DiagnosticsResultSchema, FetchErrorSchema, FetchResultSchema,
  GrepErrorSchema, GrepResultSchema, LsRejectedSchema, LsResultSchema,
  ReadRejectedSchema, ReadResultSchema, ShellRejectedSchema, ShellResultSchema,
  WriteRejectedSchema, WriteResultSchema, WriteShellStdinErrorSchema, WriteShellStdinResultSchema,
  ConversationStateStructureSchema,
} from "./proto/agent_pb.js";
import { frameConnectMessage } from "./proxy-bridge.js";
import { decodeMcpArgsMap } from "./proxy-messages.js";
import { resolveToolAlias } from "./proxy-bridge.js";

export { AgentServerMessageSchema, ConversationStateStructureSchema };

/** Send an exec client message back to Cursor. */
export function sendExecResult(execMsg, messageCase, value, sendFrame) {
  const execClientMessage = create(ExecClientMessageSchema, {
    id: execMsg.id, execId: execMsg.execId,
    message: { case: messageCase, value },
  });
  const clientMessage = create(AgentClientMessageSchema, {
    message: { case: "execClientMessage", value: execClientMessage },
  });
  sendFrame(frameConnectMessage(toBinary(AgentClientMessageSchema, clientMessage)));
}

/** Send a KV client response back to Cursor. */
function sendKvResponse(kvMsg, messageCase, value, sendFrame) {
  const response = create(KvClientMessageSchema, {
    id: kvMsg.id, message: { case: messageCase, value },
  });
  const clientMsg = create(AgentClientMessageSchema, {
    message: { case: "kvClientMessage", value: response },
  });
  sendFrame(frameConnectMessage(toBinary(AgentClientMessageSchema, clientMsg)));
}

export function handleInteractionUpdate(update, onText) {
  const updateCase = update.message?.case;
  if (updateCase === "textDelta") {
    const delta = update.message.value.text || "";
    if (delta) onText(delta, false);
  } else if (updateCase === "thinkingDelta") {
    const delta = update.message.value.text || "";
    if (delta) onText(delta, true);
  }
}

export function handleKvMessage(kvMsg, blobStore, sendFrame) {
  const kvCase = kvMsg.message.case;
  if (kvCase === "getBlobArgs") {
    const blobId = kvMsg.message.value.blobId;
    const blobData = blobStore.get(Buffer.from(blobId).toString("hex"));
    sendKvResponse(kvMsg, "getBlobResult", create(GetBlobResultSchema, blobData ? { blobData } : {}), sendFrame);
  } else if (kvCase === "setBlobArgs") {
    const { blobId, blobData } = kvMsg.message.value;
    blobStore.set(Buffer.from(blobId).toString("hex"), blobData);
    sendKvResponse(kvMsg, "setBlobResult", create(SetBlobResultSchema, {}), sendFrame);
  }
}

export function handleRequestContext(execMsg, mcpTools, sendFrame) {
  console.error(`[proxy] requestContextArgs: providing ${mcpTools.length} MCP tools to Cursor`);
  const requestContext = create(RequestContextSchema, {
    rules: [], repositoryInfo: [], tools: mcpTools, gitRepos: [],
    projectLayouts: [], mcpInstructions: [], fileContents: {}, customSubagents: [],
  });
  const result = create(RequestContextResultSchema, {
    result: { case: "success", value: create(RequestContextSuccessSchema, { requestContext }) },
  });
  sendExecResult(execMsg, "requestContextResult", result, sendFrame);
}

export function handleMcpArgs(execMsg, onMcpExec) {
  const mcpArgs = execMsg.message.value;
  const decoded = decodeMcpArgsMap(mcpArgs.args ?? {});
  const rawToolName = mcpArgs.toolName || mcpArgs.name;
  const resolvedToolName = resolveToolAlias(rawToolName);
  onMcpExec({
    execId: execMsg.execId, execMsgId: execMsg.id,
    toolCallId: mcpArgs.toolCallId || crypto.randomUUID(),
    toolName: resolvedToolName, decodedArgs: JSON.stringify(decoded),
  });
}

const PATH_REJECTIONS = {
  readArgs:   { resultCase: "readResult",   resultSchema: ReadResultSchema,   rejectedSchema: ReadRejectedSchema },
  lsArgs:     { resultCase: "lsResult",     resultSchema: LsResultSchema,     rejectedSchema: LsRejectedSchema },
  writeArgs:  { resultCase: "writeResult",  resultSchema: WriteResultSchema,  rejectedSchema: WriteRejectedSchema },
  deleteArgs: { resultCase: "deleteResult", resultSchema: DeleteResultSchema, rejectedSchema: DeleteRejectedSchema },
};
const SHELL_REJECTIONS = {
  shellArgs:                { resultCase: "shellResult",                resultSchema: ShellResultSchema },
  shellStreamArgs:          { resultCase: "shellResult",                resultSchema: ShellResultSchema },
  backgroundShellSpawnArgs: { resultCase: "backgroundShellSpawnResult", resultSchema: BackgroundShellSpawnResultSchema },
};
const ERROR_REJECTIONS = {
  grepArgs:            { resultCase: "grepResult",           resultSchema: GrepResultSchema,           errorSchema: GrepErrorSchema },
  writeShellStdinArgs: { resultCase: "writeShellStdinResult", resultSchema: WriteShellStdinResultSchema, errorSchema: WriteShellStdinErrorSchema },
};
const MISC_RESULT_CASES = {
  listMcpResourcesExecArgs: "listMcpResourcesExecResult",
  readMcpResourceExecArgs:  "readMcpResourceExecResult",
  recordScreenArgs:         "recordScreenResult",
  computerUseArgs:          "computerUseResult",
};

function rejectPathTool(execMsg, schemas, reason, sendFrame) {
  const args = execMsg.message.value;
  const result = create(schemas.resultSchema, {
    result: { case: "rejected", value: create(schemas.rejectedSchema, { path: args.path, reason }) },
  });
  sendExecResult(execMsg, schemas.resultCase, result, sendFrame);
}

function rejectShellTool(execMsg, schemas, reason, sendFrame) {
  const args = execMsg.message.value;
  const result = create(schemas.resultSchema, {
    result: { case: "rejected", value: create(ShellRejectedSchema, {
      command: args.command ?? "", workingDirectory: args.workingDirectory ?? "",
      reason, isReadonly: false,
    })},
  });
  sendExecResult(execMsg, schemas.resultCase, result, sendFrame);
}

function rejectErrorTool(execMsg, schemas, errorFields, sendFrame) {
  const result = create(schemas.resultSchema, {
    result: { case: "error", value: create(schemas.errorSchema, errorFields) },
  });
  sendExecResult(execMsg, schemas.resultCase, result, sendFrame);
}

function handleMiscExecRejection(execCase, execMsg, sendFrame, reason) {
  const errorEntry = ERROR_REJECTIONS[execCase];
  if (errorEntry) { rejectErrorTool(execMsg, errorEntry, { error: reason }, sendFrame); return true; }
  if (execCase === "fetchArgs") {
    const args = execMsg.message.value;
    rejectErrorTool(execMsg, { resultCase: "fetchResult", resultSchema: FetchResultSchema, errorSchema: FetchErrorSchema }, { url: args.url ?? "", error: reason }, sendFrame);
    return true;
  }
  if (execCase === "diagnosticsArgs") {
    sendExecResult(execMsg, "diagnosticsResult", create(DiagnosticsResultSchema, {}), sendFrame);
    return true;
  }
  const miscResultCase = MISC_RESULT_CASES[execCase];
  if (miscResultCase) { sendExecResult(execMsg, miscResultCase, create(McpResultSchema, {}), sendFrame); return true; }
  return false;
}

export function rejectNativeCursorTool(execCase, execMsg, sendFrame) {
  const REJECT_REASON = "Tool not available in this environment. Use the MCP tools provided instead.";
  const pathEntry = PATH_REJECTIONS[execCase];
  if (pathEntry) { rejectPathTool(execMsg, pathEntry, REJECT_REASON, sendFrame); return true; }
  const shellEntry = SHELL_REJECTIONS[execCase];
  if (shellEntry) { rejectShellTool(execMsg, shellEntry, REJECT_REASON, sendFrame); return true; }
  return handleMiscExecRejection(execCase, execMsg, sendFrame, REJECT_REASON);
}

export function processServerMessage(msg, transport, handlers) {
  const { blobStore, mcpTools, sendFrame } = transport;
  const { onText, onMcpExec, onCheckpoint } = handlers;
  const msgCase = msg.message.case;
  if (msgCase === "interactionUpdate") {
    handleInteractionUpdate(msg.message.value, onText);
  } else if (msgCase === "kvServerMessage") {
    handleKvMessage(msg.message.value, blobStore, sendFrame);
  } else if (msgCase === "execServerMessage") {
    handleExecMessage(msg.message.value, mcpTools, sendFrame, onMcpExec);
  } else if (msgCase === "conversationCheckpointUpdate" && onCheckpoint) {
    onCheckpoint(toBinary(ConversationStateStructureSchema, msg.message.value));
  }
}

export function handleExecMessage(execMsg, mcpTools, sendFrame, onMcpExec) {
  const execCase = execMsg.message.case;
  console.error(`[proxy] execMessage: case=${execCase}`);
  if (execCase === "requestContextArgs") { handleRequestContext(execMsg, mcpTools, sendFrame); return; }
  if (execCase === "mcpArgs") { handleMcpArgs(execMsg, onMcpExec); return; }
  if (rejectNativeCursorTool(execCase, execMsg, sendFrame)) return;
  console.error(`[proxy] unhandled exec: ${execCase}`);
}

/** Build MCP result messages for tool results to resume a bridge. */
export function buildMcpResults(pendingExecs, toolResults) {
  const { McpResultSchema: MRS, McpSuccessSchema: MSS, McpErrorSchema: MES } = { McpResultSchema, McpSuccessSchema, McpErrorSchema };
  return pendingExecs.map((exec) => {
    const result = toolResults.find((r) => r.toolCallId === exec.toolCallId);
    return result
      ? create(MRS, { result: { case: "success", value: create(MSS, {
          content: [create(McpToolResultContentItemSchema, {
            content: { case: "text", value: create(McpTextContentSchema, { text: result.content }) },
          })], isError: false,
        })}})
      : create(MRS, { result: { case: "error", value: create(MES, { error: "Tool result not provided" }) }});
  });
}
