export type BridgeTokenErrorCode = "unauthorized" | "not_connected" | "token_unavailable" | string;

export class BridgeTokenError extends Error {
  readonly code: BridgeTokenErrorCode;
  readonly retryAt?: string;

  constructor(code: BridgeTokenErrorCode, retryAt?: string) {
    super(`bridge token error: ${code}`);
    this.name = "BridgeTokenError";
    this.code = code;
    this.retryAt = retryAt;
  }
}

export interface BridgeTokenResult {
  access_token: string;
  expires_at: string;
}

export interface BridgeTokenOptions {
  apiBase: string;
  secret: string;
  fetch?: typeof fetch;
}

export interface BridgeTokenClient {
  get(now?: number): Promise<BridgeTokenResult>;
}

const REFRESH_MARGIN_MS = 60_000;

/**
 * Client for `GET <garage_api_base>/api/bridge/token`. Caches the token until
 * 60s before its `expires_at`, then re-fetches. Never logs the secret or the
 * token. Non-200 responses throw `BridgeTokenError` carrying the server's
 * `error` code (and `retry_at` for 503s).
 */
export function BridgeToken(opts: BridgeTokenOptions): BridgeTokenClient {
  const fetchImpl = opts.fetch ?? globalThis.fetch;
  let cached: { result: BridgeTokenResult; expiresAtMs: number } | null = null;

  async function get(now: number = Date.now()): Promise<BridgeTokenResult> {
    if (cached && cached.expiresAtMs - REFRESH_MARGIN_MS > now) {
      return cached.result;
    }

    const res = await fetchImpl(`${opts.apiBase}/api/bridge/token`, {
      headers: { "x-bridge-secret": opts.secret },
    });

    if (res.status !== 200) {
      const body = await safeJson(res);
      throw new BridgeTokenError((body?.error as string | undefined) ?? `http_${res.status}`, body?.retry_at as string | undefined);
    }

    const body = (await res.json()) as BridgeTokenResult;
    cached = { result: body, expiresAtMs: new Date(body.expires_at).getTime() };
    return body;
  }

  return { get };
}

async function safeJson(res: Response): Promise<Record<string, unknown>> {
  try {
    return (await res.json()) as Record<string, unknown>;
  } catch {
    return {};
  }
}
