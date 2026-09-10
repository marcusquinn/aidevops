// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { sha256, stableJson, writeJson } from "./model-replay-core.mjs";

export const BUDGET_SCHEMA = "aidevops-model-replay-budget/v1";

function positiveInteger(value, label) {
  if (!Number.isInteger(value) || value < 1) throw new Error(`${label} must be a positive integer`);
  return value;
}

export function validateBudgetContract(contract) {
  if (!contract || contract.schema_version !== BUDGET_SCHEMA) {
    throw new Error("Model replay budget schema is unsupported");
  }
  const required = [
    [contract.max_cell_launches, "Budget max_cell_launches"],
    [contract.per_cell_timeout_seconds, "Budget per_cell_timeout_seconds"],
    [contract.program_wall_seconds, "Budget program_wall_seconds"],
    [contract.concurrency, "Budget concurrency"],
  ];
  required.forEach(([value, label]) => positiveInteger(value, label));
  if (contract.concurrency !== 1) throw new Error("Model replay budget concurrency must be one");
  return structuredClone(contract);
}

export function loadBudgetContract(path) {
  if (!existsSync(path)) throw new Error("Model replay budget file is missing");
  return validateBudgetContract(JSON.parse(readFileSync(path, "utf8")));
}

function receiptPath(experimentDir) {
  return join(experimentDir, "budget-receipt.json");
}

function receiptDigest(receipt) {
  const payload = { ...receipt };
  delete payload.receipt_sha256;
  return sha256(stableJson(payload));
}

export function loadBudgetReceipt(experimentDir, plan) {
  if (!plan.budget) return null;
  const path = receiptPath(experimentDir);
  if (!existsSync(path)) {
    const receipt = {
      schema_version: BUDGET_SCHEMA,
      plan_sha256: plan.plan_sha256,
      budget: validateBudgetContract(plan.budget),
      started_at: new Date().toISOString(),
      launched_cell_ids: [],
      completed_cell_ids: [],
    };
    receipt.receipt_sha256 = receiptDigest(receipt);
    writeJson(path, receipt);
    return receipt;
  }
  const receipt = JSON.parse(readFileSync(path, "utf8"));
  if (receipt.receipt_sha256 !== receiptDigest(receipt)
    || receipt.plan_sha256 !== plan.plan_sha256
    || stableJson(receipt.budget) !== stableJson(validateBudgetContract(plan.budget))
    || !Array.isArray(receipt.launched_cell_ids)
    || !Array.isArray(receipt.completed_cell_ids)
    || receipt.completed_cell_ids.some((cellID) => !receipt.launched_cell_ids.includes(cellID))) {
    throw new Error("Model replay budget receipt integrity check failed");
  }
  return receipt;
}

function persistReceipt(experimentDir, receipt) {
  receipt.receipt_sha256 = receiptDigest(receipt);
  writeJson(receiptPath(experimentDir), receipt);
}

export function reserveCellLaunch(experimentDir, plan, receipt, cell) {
  if (!receipt || receipt.launched_cell_ids.includes(cell.cell_id)) return;
  if (receipt.launched_cell_ids.length >= receipt.budget.max_cell_launches) {
    throw new Error("Model replay aggregate launch budget is exhausted");
  }
  if (cell.timeout_seconds > receipt.budget.per_cell_timeout_seconds) {
    throw new Error("Model replay cell timeout exceeds the sealed budget");
  }
  if ((Date.now() - Date.parse(receipt.started_at)) / 1000 > receipt.budget.program_wall_seconds) {
    throw new Error("Model replay programme wall-time budget is exhausted");
  }
  receipt.launched_cell_ids.push(cell.cell_id);
  persistReceipt(experimentDir, receipt);
}

export function completeCellLaunch(experimentDir, receipt, cell) {
  if (!receipt || receipt.completed_cell_ids.includes(cell.cell_id)) return;
  receipt.completed_cell_ids.push(cell.cell_id);
  persistReceipt(experimentDir, receipt);
}

export function assertNoAmbiguousLaunches(receipt, results) {
  if (!receipt) return;
  const completed = new Set(results.map((result) => result.cell_id));
  const ambiguous = receipt.launched_cell_ids.find((cellID) => !completed.has(cellID));
  if (ambiguous) throw new Error(`Model replay launch is ambiguous and requires reconciliation: ${ambiguous}`);
}
