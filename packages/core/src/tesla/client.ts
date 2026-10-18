export class FleetError extends Error {
  constructor(public status: number, public body: unknown, public code?: string) { super(`Fleet API ${status}${code ? " " + code : ""}`); }
}
export class FleetClient {
  private f: typeof fetch;
  constructor(private opts: { baseUrl: string; token: string; fetch?: typeof fetch }) { this.f = opts.fetch ?? fetch; }
  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const r = await this.f(this.opts.baseUrl + path, {
      method, headers: { authorization: `Bearer ${this.opts.token}`, "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await r.text(); let json: any = null; try { json = text ? JSON.parse(text) : null; } catch { json = text; }
    if (!r.ok) throw new FleetError(r.status, json, json?.error ?? json?.error_description);
    return (json?.response ?? json) as T;
  }
  get<T>(path: string) { return this.call<T>("GET", path); }
  post<T>(path: string, body?: unknown) { return this.call<T>("POST", path, body); }
}
