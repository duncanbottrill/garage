import { it, expect } from "vitest";
import { GET } from "@/app/api/health/route";
it("health responds", async () => { const r = GET(); expect(r.status).toBe(200); expect((await r.json()).ok).toBe(true); });
