// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// OpenCode 1 probe plugin for context-budget-helper.sh. Loaded only through the
// helper's isolated config home; inert without AIDEVOPS_CONTEXT_BUDGET_OUT.
import { installFetchCapture } from "./capture-common.mjs";

export const AidevopsContextBudgetCapture = async () => {
  installFetchCapture();
  return {};
};
