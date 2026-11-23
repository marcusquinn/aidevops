// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import net from 'node:net';

const hostLabel = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const decimalOnly = /^\d+(?:\.\d+)*$/;
const reservedSuffix = /(?:^|\.)(?:localhost|local|internal|test|invalid)$/;

// One ordered rule per rejection, not a boolean chain and not a ladder of early
// returns: this decides the single hostname a worker may reach, so each clause
// has to stay individually readable and auditable. `every` short-circuits in
// order, so the type rule still runs before any string operation, and a hostname
// is accepted only if it survives every rule.
const providerHostRules = [
  host => typeof host === 'string',
  host => host.length > 0 && host.length <= 253,
  host => host === host.toLowerCase(),
  host => !net.isIP(host),
  // Refuse bare-decimal address forms such as 2130706433.
  host => !decimalOnly.test(host),
  host => !reservedSuffix.test(host),
  host => host.split('.').length >= 2,
  host => host.split('.').every(label => hostLabel.test(label)),
];

export function isProviderHostname(host) {
  if (!providerHostRules.every(rule => rule(host))) return false;
  try { return !net.isIP(new URL('https://' + host).hostname); }
  catch { return false; }
}
