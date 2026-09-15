// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

function textFromContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((part) => part?.type === "text").map((part) => part.text).join("\n");
}

export function toV2ToolResult(value) {
  if (value && typeof value === "object" && ("content" in value || "output" in value || "metadata" in value)) {
    return {
      ...(value.output === undefined ? {} : { output: value.output }),
      ...(value.content === undefined ? {} : { content: value.content }),
      ...(value.metadata === undefined ? {} : { metadata: value.metadata }),
    };
  }
  return { content: typeof value === "string" ? value : JSON.stringify(value ?? null) };
}

export function legacyToolOutput(result) {
  return {
    output: textFromContent(result?.content),
    metadata: result?.metadata || {},
    title: "",
  };
}

export function applyLegacyToolOutput(result, legacyOutput) {
  if (legacyOutput.output !== textFromContent(result.content)) result.content = legacyOutput.output;
  result.metadata = legacyOutput.metadata || {};
}

export function addV1ToolsToV2Editor(editor, tools, schema, context = {}) {
  for (const [name, definition] of Object.entries(tools)) {
    editor.add({
      name,
      description: definition.description,
      input: schema.object(definition.args || {}),
      async execute(args, toolContext) {
        return toV2ToolResult(await definition.execute(args, {
          ...toolContext,
          directory: context.directory,
          worktree: context.worktree,
        }));
      },
    });
  }
}
