// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// Identity of a remote-hosted endpoint for the session bus (t18898).

const APP_PATTERN = /^[a-z0-9-]{1,32}$/;
const CHANNEL_PATTERN = /^[A-Za-z0-9._:@!#+=-]{1,128}$/;

const refValue = (ref, prefix) => {
  const text = String(ref ?? "");
  return text.startsWith(prefix) ? text.slice(prefix.length) : "";
};

/**
 * t18898: identity of a remote-hosted endpoint from the overlay's agent ID and
 * interface_context. Malformed input never falls back to a local identity:
 * the result is always a valid chat app and channel (`remote` and `agent`).
 * @param {object} remote - { agent, context }
 */
export function remoteEndpoint(remote) {
  const agent = typeof remote?.agent === "string" ? remote.agent.slice(0, 80) : "";
  const app = refValue(remote?.context?.provider_ref, "provider:").toLowerCase();
  const channel = refValue(remote?.context?.conversation_ref, "conversation:");
  const agentChannel = CHANNEL_PATTERN.test(agent) ? agent : "agent";
  return {
    agent,
    interface: APP_PATTERN.test(app) ? app : "remote",
    channel: CHANNEL_PATTERN.test(channel) ? channel : agentChannel,
  };
}
