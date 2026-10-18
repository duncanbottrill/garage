export const dynamic = "force-dynamic";
export function GET() { return Response.json({ ok: true, service: "garage-web", at: new Date().toISOString() }); }
