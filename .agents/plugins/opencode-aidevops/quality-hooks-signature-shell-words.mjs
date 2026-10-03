// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Literal shell-word scanning only: never evaluate a command or substitution.
// Retain source offsets for the signature gate's surgical command rewrites.
const SEPARATOR = /[\s;|&]/;
const QUOTE_TRANSITIONS = {
  "": { "'": "'", '"': '"' },
  "'": { "'": "" },
  '"': { '"': "" },
};

function flushWord(state, words) {
  if (state.start !== -1) words.push({ text: state.text, start: state.start, flag: state.flag });
  state.text = "";
  state.start = -1;
  state.flag = false;
}

function appendEscape(state, command, index) {
  const next = command[index + 1];
  if (next === undefined) {
    state.complete = false;
    return index;
  }
  if (next !== "\n") {
    // Double quotes preserve backslashes before ordinary characters.
    const preserve = state.quote === '"' && !/[$`"\\]/.test(next);
    state.text += preserve ? "\\" + next : next;
  }
  return index + 1;
}

function appendCharacter(state, command, index) {
  const character = command[index];
  const nextQuote = QUOTE_TRANSITIONS[state.quote]?.[character] ?? state.quote;
  if (nextQuote !== state.quote) {
    state.quote = nextQuote;
    return index;
  }
  if (character === "\\" && state.quote !== "'") {
    return appendEscape(state, command, index);
  }
  state.text += command[index];
  return index;
}

export function unquotedTokens(command) {
  const words = [];
  const state = { text: "", start: -1, quote: "", flag: false, complete: true };
  for (let index = 0; index < command.length; index++) {
    const character = command[index];
    if (!state.quote && SEPARATOR.test(character)) {
      flushWord(state, words);
      continue;
    }
    if (state.start === -1) {
      state.start = index;
      state.flag = character === "-";
    }
    index = appendCharacter(state, command, index);
  }
  if (!state.complete || state.quote) return [];
  flushWord(state, words);
  return words;
}
