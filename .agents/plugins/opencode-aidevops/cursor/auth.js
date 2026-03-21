import { generatePKCE } from "./pkce.js";
const CURSOR_LOGIN_URL = "https://cursor.com/loginDeepControl";
const CURSOR_POLL_URL = "https://api2.cursor.sh/auth/poll";
const CURSOR_REFRESH_URL = process.env.CURSOR_REFRESH_URL ??
    "https://api2.cursor.sh/auth/exchange_user_api_key";
const POLL_MAX_ATTEMPTS = 150;
const POLL_BASE_DELAY = 1000;
const POLL_MAX_DELAY = 10_000;
const POLL_BACKOFF_MULTIPLIER = 1.2;
export async function generateCursorAuthParams() {
    const { verifier, challenge } = await generatePKCE();
    const uuid = crypto.randomUUID();
    const params = new URLSearchParams({
        challenge,
        uuid,
        mode: "login",
        redirectTarget: "cli",
    });
    const loginUrl = `${CURSOR_LOGIN_URL}?${params.toString()}`;
    return { verifier, challenge, uuid, loginUrl };
}
export async function pollCursorAuth(uuid, verifier) {
    let delay = POLL_BASE_DELAY;
    let consecutiveErrors = 0;
    for (let attempt = 0; attempt < POLL_MAX_ATTEMPTS; attempt++) {
        await Bun.sleep(delay);
        try {
            const response = await fetch(`${CURSOR_POLL_URL}?uuid=${uuid}&verifier=${verifier}`);
            if (response.status === 404) {
                consecutiveErrors = 0;
                delay = Math.min(delay * POLL_BACKOFF_MULTIPLIER, POLL_MAX_DELAY);
                continue;
            }
            if (response.ok) {
                const data = (await response.json());
                return {
                    accessToken: data.accessToken,
                    refreshToken: data.refreshToken,
                };
            }
            throw new Error(`Poll failed: ${response.status}`);
        }
        catch {
            consecutiveErrors++;
            if (consecutiveErrors >= 3) {
                throw new Error("Too many consecutive errors during Cursor auth polling");
            }
        }
    }
    throw new Error("Cursor authentication polling timeout");
}
export async function refreshCursorToken(refreshToken) {
    const response = await fetch(CURSOR_REFRESH_URL, {
        method: "POST",
        headers: {
            Authorization: `Bearer ${refreshToken}`,
            "Content-Type": "application/json",
        },
        body: "{}",
    });
    if (!response.ok) {
        const error = await response.text();
        throw new Error(`Cursor token refresh failed: ${error}`);
    }
    const data = (await response.json());
    return {
        access: data.accessToken,
        refresh: data.refreshToken || refreshToken,
        expires: getTokenExpiry(data.accessToken),
    };
}
/**
 * Extract JWT expiry with 5-minute safety margin.
 * Falls back to 1 hour from now if token can't be parsed.
 */
export function getTokenExpiry(token) {
    try {
        const parts = token.split(".");
        if (parts.length !== 3 || !parts[1]) {
            return Date.now() + 3600 * 1000;
        }
        const decoded = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
        if (decoded &&
            typeof decoded === "object" &&
            typeof decoded.exp === "number") {
            return decoded.exp * 1000 - 5 * 60 * 1000;
        }
    }
    catch {
    }
    return Date.now() + 3600 * 1000;
}
