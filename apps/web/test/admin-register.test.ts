import { it, expect } from "vitest";
import { POST } from "@/app/api/admin/register-partner/route";
it("register-partner refuses without the admin secret", async () => {
  process.env.ADMIN_SECRET = "adm";
  const r = await POST(new Request("http://g/api/admin/register-partner", { method: "POST" }));
  expect(r.status).toBe(403);
});
it("register-partner refuses the cron secret — it is not the admin secret", async () => {
  process.env.ADMIN_SECRET = "adm"; process.env.CRON_SECRET = "c";
  const r = await POST(new Request("http://g/api/admin/register-partner", { method: "POST", headers: { authorization: "Bearer c" } }));
  expect(r.status).toBe(403);
});
