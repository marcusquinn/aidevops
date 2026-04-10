// CDPClient — WebSocket-based Chrome DevTools Protocol client.

import { TIMEOUT_MS } from './constants.mjs';

export class CDPClient {
  #ws;
  #id = 0;
  #pending = new Map();
  #eventHandlers = new Map();
  #closeHandlers = [];

  async connect(wsUrl) {
    return new Promise((resolvePromise, rejectPromise) => {
      this.#ws = new WebSocket(wsUrl);

      this.#ws.onopen = () => resolvePromise();
      this.#ws.onerror = (event) => rejectPromise(new Error(`WebSocket error: ${event.message || event.type}`));
      this.#ws.onclose = () => {
        for (const handler of this.#closeHandlers) handler();
      };
      this.#ws.onmessage = (event) => {
        const message = JSON.parse(event.data);

        if (message.id && this.#pending.has(message.id)) {
          const { resolve, reject } = this.#pending.get(message.id);
          this.#pending.delete(message.id);
          if (message.error) reject(new Error(message.error.message));
          else resolve(message.result);
          return;
        }

        if (message.method && this.#eventHandlers.has(message.method)) {
          for (const handler of [...this.#eventHandlers.get(message.method)]) {
            handler(message.params || {}, message);
          }
        }
      };
    });
  }

  async send(method, params = {}, sessionId) {
    const id = this.#id + 1;
    this.#id = id;

    return new Promise((resolvePromise, rejectPromise) => {
      this.#pending.set(id, { resolve: resolvePromise, reject: rejectPromise });
      const message = { id, method, params };
      if (sessionId) message.sessionId = sessionId;
      this.#ws.send(JSON.stringify(message));

      setTimeout(() => {
        if (!this.#pending.has(id)) return;
        this.#pending.delete(id);
        rejectPromise(new Error(`Timeout: ${method}`));
      }, TIMEOUT_MS);
    });
  }

  onEvent(method, handler) {
    if (!this.#eventHandlers.has(method)) this.#eventHandlers.set(method, new Set());
    const handlers = this.#eventHandlers.get(method);
    handlers.add(handler);

    return () => {
      handlers.delete(handler);
      if (handlers.size === 0) this.#eventHandlers.delete(method);
    };
  }

  waitForEvent(method, timeoutMs = TIMEOUT_MS) {
    let settled = false;
    let unsubscribe;
    let timer;

    const promise = new Promise((resolvePromise, rejectPromise) => {
      unsubscribe = this.onEvent(method, (params) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        unsubscribe();
        resolvePromise(params);
      });

      timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        unsubscribe();
        rejectPromise(new Error(`Timeout waiting for event: ${method}`));
      }, timeoutMs);
    });

    return {
      promise,
      cancel() {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        unsubscribe?.();
      },
    };
  }

  onClose(handler) {
    this.#closeHandlers.push(handler);
  }

  close() {
    this.#ws.close();
  }
}
