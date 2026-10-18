import { requireCron } from "@/lib/supabase"; import { runBudget } from "@/lib/budget-cron";
export const dynamic = "force-dynamic";
export async function GET(req: Request) { if (!requireCron(req)) return new Response("forbidden", { status: 403 }); return Response.json(await runBudget()); }
