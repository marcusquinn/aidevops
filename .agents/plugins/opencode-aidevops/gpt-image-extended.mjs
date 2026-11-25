// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { API_IMAGE_EXTENDED_MODELS, IMAGE_BACKGROUNDS, IMAGE_COMPLEXITIES } from "./gpt-image-request.mjs";

const EXTENDED_MODEL_SET = new Set(API_IMAGE_EXTENDED_MODELS);

export function validateExtendedArgs(args) {
  if (args.complexity !== undefined && !IMAGE_COMPLEXITIES.includes(args.complexity)) {
    throw new Error("Unsupported image complexity.");
  }
  if (args.background !== undefined && !IMAGE_BACKGROUNDS.includes(args.background)) {
    throw new Error("Unsupported image background.");
  }
  if (args.complexity === undefined && args.background === undefined) return;
  if (args.auth !== "api" || !EXTENDED_MODEL_SET.has(args.model)) {
    throw new Error(`Image complexity and background require explicit auth=api with model ${API_IMAGE_EXTENDED_MODELS.join(" or ")}.`);
  }
  if (args.background === "transparent" && args.format === "jpeg") {
    throw new Error("background=transparent requires format png or webp; jpeg has no alpha channel.");
  }
}
