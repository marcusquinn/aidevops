// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
// Shared fixed-error contract for the backend and its profile validation.
export class BackendError extends Error {}
export function insist(condition, reason) { if (!condition) throw new BackendError(reason); }
