import { requireCron } from "@/lib/supabase"; import { refreshAll } from "@/lib/tesla-refresh";
export const dynamic = "force-dynamic"; export const maxDuration = 60;
export async function GET(req: Request) { if (!requireCron(req)) return new Response("forbidden", { status: 403 }); return Response.json(await refreshAll()); }
