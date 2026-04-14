// higgsfield-api-client.mjs — Low-level HTTP transport + auth for the Higgsfield Cloud API.
// Holds: credential loading, fetch + retry, file upload/download, status polling.
// High-level commands live in higgsfield-api.mjs.

import { readFileSync, existsSync, writeFileSync } from 'fs';
import { join, extname, basename } from 'path';
import { homedir } from 'os';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

export const API_BASE_URL = 'https://platform.higgsfield.ai';
export const API_POLL_INTERVAL_MS = 2000;
export const API_POLL_MAX_WAIT_MS = 10 * 60 * 1000; // 10 minutes max wait

// ---------------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------------

export function loadApiCredentials() {
  const credFile = join(homedir(), '.config', 'aidevops', 'credentials.sh');
  if (!existsSync(credFile)) return null;
  const content = readFileSync(credFile, 'utf-8');
  const apiKey = content.match(/HF_API_KEY="([^"]+)"/)?.[1];
  const apiSecret = content.match(/HF_API_SECRET="([^"]+)"/)?.[1];
  if (!apiKey || !apiSecret) return null;
  return { apiKey, apiSecret };
}

export function requireApiCredentials() {
  const creds = loadApiCredentials();
  if (!creds) throw new Error('API credentials not configured (HF_API_KEY/HF_API_SECRET in credentials.sh)');
  return creds;
}

// ---------------------------------------------------------------------------
// Core HTTP helpers
// ---------------------------------------------------------------------------

export async function apiExecuteFetch(url, fetchOpts, timeout) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  fetchOpts.signal = controller.signal;
  try {
    const response = await fetch(url, fetchOpts);
    clearTimeout(timer);
    return response;
  } catch (err) {
    clearTimeout(timer);
    if (err.name === 'AbortError') throw new Error(`API request timed out after ${timeout}ms`);
    throw err;
  }
}

export function parseApiErrorDetail(text) {
  try { return JSON.parse(text).detail || JSON.parse(text).message || text; } catch {}
  return text;
}

const RETRYABLE_HTTP_CODES = new Set([408, 429, 500, 502, 503, 504]);

function buildApiUrl(path) {
  if (path.startsWith('http')) return path;
  const sep = path.startsWith('/') ? '' : '/';
  return `${API_BASE_URL}${sep}${path}`;
}

function buildApiHeaders(apiKey, apiSecret) {
  return {
    'Authorization': `Key ${apiKey}:${apiSecret}`,
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent': 'higgsfield-automator/1.0',
  };
}

function backoffDelayMs(attempt) {
  return 200 * Math.pow(2, attempt);
}

async function sleep(ms) {
  await new Promise(r => setTimeout(r, ms));
}

// Returns { ok: true, value } on success, { ok: false, retry: true } if retryable, throws otherwise.
async function processApiResponse(response, method, path, attempt) {
  if (response.ok) {
    return { ok: true, value: await response.json() };
  }
  const text = await response.text().catch(() => '');
  if (RETRYABLE_HTTP_CODES.has(response.status) && attempt < 2) {
    const delay = backoffDelayMs(attempt);
    console.log(`[api] Retrying ${method} ${path} (${response.status}) in ${delay}ms...`);
    await sleep(delay);
    return { ok: false, retry: true };
  }
  throw new Error(`API ${response.status}: ${parseApiErrorDetail(text)}`);
}

function shouldRetryAfterError(err) {
  if (err.message.startsWith('API request timed out')) return false;
  if (err.message.startsWith('API ')) return false;
  return true;
}

export async function apiRequest(method, path, { body, apiKey, apiSecret, timeout = 90000 } = {}) {
  const url = buildApiUrl(path);
  const fetchOpts = { method, headers: buildApiHeaders(apiKey, apiSecret) };
  if (body) fetchOpts.body = JSON.stringify(body);

  let lastError;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const response = await apiExecuteFetch(url, fetchOpts, timeout);
      const result = await processApiResponse(response, method, path, attempt);
      if (result.ok) return result.value;
      // retryable: continue loop
    } catch (err) {
      lastError = err;
      if (!shouldRetryAfterError(err)) throw err;
      if (attempt >= 2) throw err;
      await sleep(backoffDelayMs(attempt));
    }
  }
  throw lastError;
}

// ---------------------------------------------------------------------------
// File upload / download
// ---------------------------------------------------------------------------

const UPLOAD_MIME_BY_EXT = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
  '.webp': 'image/webp', '.gif': 'image/gif', '.mp4': 'video/mp4', '.mov': 'video/quicktime',
};

function detectUploadContentType(filePath) {
  const ext = extname(filePath).toLowerCase();
  return UPLOAD_MIME_BY_EXT[ext] || 'application/octet-stream';
}

export async function apiUploadFile(filePath, creds) {
  const { apiKey, apiSecret } = creds;
  const contentType = detectUploadContentType(filePath);

  const { public_url, upload_url } = await apiRequest('POST', '/files/generate-upload-url', {
    body: { content_type: contentType },
    apiKey, apiSecret,
  });

  const fileData = readFileSync(filePath);
  const uploadResp = await fetch(upload_url, {
    method: 'PUT',
    body: fileData,
    headers: { 'Content-Type': contentType },
  });
  if (!uploadResp.ok) {
    throw new Error(`File upload failed: ${uploadResp.status} ${await uploadResp.text().catch(() => '')}`);
  }

  console.log(`[api] Uploaded ${basename(filePath)} (${(fileData.length / 1024).toFixed(0)}KB) -> ${public_url}`);
  return public_url;
}

export async function apiDownloadFile(url, outputPath) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Download failed: ${response.status}`);
  const buffer = Buffer.from(await response.arrayBuffer());
  writeFileSync(outputPath, buffer);
  return buffer.length;
}

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------

const POLL_TERMINAL_STATUSES = {
  completed: { kind: 'done' },
  failed: { kind: 'failed' },
  nsfw: { kind: 'failed', error: 'Content flagged as NSFW (credits refunded)' },
};

function classifyPollStatus(data) {
  const terminal = POLL_TERMINAL_STATUSES[data.status];
  if (!terminal) return { kind: 'pending', status: data.status };
  if (terminal.kind === 'failed') {
    const error = terminal.error || `Generation failed: ${data.error || 'unknown error'}`;
    return { kind: 'failed', error };
  }
  return { kind: 'done' };
}

export async function apiPollStatus(requestId, creds, { maxWait = API_POLL_MAX_WAIT_MS } = {}) {
  const { apiKey, apiSecret } = creds;
  const startTime = Date.now();
  let delay = API_POLL_INTERVAL_MS;

  while (Date.now() - startTime < maxWait) {
    const data = await apiRequest('GET', `/requests/${requestId}/status`, { apiKey, apiSecret });
    const verdict = classifyPollStatus(data);

    if (verdict.kind === 'done') return data;
    if (verdict.kind === 'failed') throw new Error(verdict.error);

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
    process.stdout.write(`\r[api] Status: ${verdict.status} (${elapsed}s elapsed)...`);

    await sleep(delay);
    delay = Math.min(delay + 1000, 5000);
  }
  throw new Error(`Generation timed out after ${maxWait / 1000}s`);
}
