// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createMcpSessionRuntime, registerMcpServers } from "./mcp-registry.mjs";

export function toV2McpConfig(config) {
  const { enabled, env, ...rest } = config;
  return {
    ...rest,
    ...(env ? { environment: env } : {}),
    disabled: enabled === false,
  };
}

function statusMap(servers) {
  if (!Array.isArray(servers)) return servers || {};
  return Object.fromEntries(servers.map((server) => [server.name, server.status]));
}

export function createV2McpRuntime(ctx, workspaceDir, options = {}) {
  const runtime = createMcpSessionRuntime(workspaceDir, options);
  const registrations = [];
  const definitions = {};

  async function addTransform(callback) {
    const registration = await ctx.mcp.transform(callback);
    registrations.push(registration);
    return registration;
  }

  async function initialize() {
    const config = { mcp: definitions, tools: {} };
    registerMcpServers(config, { runtime });
    await addTransform((editor) => {
      for (const [name, definition] of Object.entries(definitions)) {
        if (!editor.get(name)) editor.set(name, toV2McpConfig(definition));
      }
    });
  }

  async function setDisabled(name, disabled) {
    if (!definitions[name]) throw new Error(`Unknown managed MCP server: ${name}`);
    await addTransform((editor) => {
      if (!editor.get(name)) editor.set(name, toV2McpConfig(definitions[name]));
      editor.update(name, (config) => {
        config.disabled = disabled;
      });
    });
    await ctx.mcp.reload();
    return {};
  }

  const client = {
    connect: ({ path }) => setDisabled(path.name, false),
    disconnect: ({ path }) => setDisabled(path.name, true),
    async status() {
      return { data: statusMap(await ctx.mcp.list()) };
    },
  };

  async function dispose() {
    for (const registration of registrations.reverse()) {
      await registration.dispose().catch(() => {});
    }
  }

  return { ...runtime, client, initialize, dispose };
}
