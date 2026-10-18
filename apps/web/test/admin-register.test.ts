import { it, expect } from "vitest";
import { POST } from "@/app/api/admin/register-partner/route";
it("register-partner refuses without the cron secret", async () => {
  process.env.CRON_SECRET = "c";
  const r = await POST(new Request("http://g/api/admin/register-partner", { method: "POST" }));
  expect(r.status).toBe(403);
});
