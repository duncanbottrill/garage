# Garage

Garage is a Tessie-class companion app for one Tesla (iPhone and Mac), built directly on Tesla's Fleet API. It shows live vehicle state within seconds of the car reporting it, and sends lock, climate, charging and frunk commands from anywhere, without relying on a third-party service. It is personal-use software first, structured so a public product would be a change of hosting and accounts rather than a rewrite.

## Repository layout

```
garage/
  addon/                 HA add-on repository (repository.yaml, garage-bridge/)
  apps/web/              Next.js on Vercel (garage domain)
  apps/apple/            Xcode project + GarageKit package
  packages/tokens/       tokens.json → Swift + CSS generators
  supabase/              migrations, seed, policy tests
  docs/superpowers/      specs and plans
```

## Local setup

```
pnpm install
colima start
supabase start
export SUPABASE_URL=http://127.0.0.1:54321 \
  SUPABASE_ANON_KEY=$(supabase status -o json 2>/dev/null | node -e 'process.stdin.on("data",d=>console.log(JSON.parse(d).ANON_KEY))') \
  SUPABASE_SERVICE_ROLE_KEY=$(supabase status -o json 2>/dev/null | node -e 'process.stdin.on("data",d=>console.log(JSON.parse(d).SERVICE_ROLE_KEY))')
supabase db reset
pnpm test
```

## Deployment shape

The Vercel app (`apps/web`) holds the OAuth callback, token refresh cron, and the authenticated API routes the Apple app and the Home Assistant add-ons call. Supabase is the system of record (Postgres with RLS, Realtime for fan-out to the apps). A Home Assistant Green on the home network runs the Tesla HTTP Proxy and the Garage Bridge add-on, which signs commands with the paired virtual key and streams telemetry in over Tailscale.

## Further reading

- Spec: [`docs/superpowers/specs/2026-10-18-garage-slice-1-foundation-and-status-design.md`](docs/superpowers/specs/2026-10-18-garage-slice-1-foundation-and-status-design.md)
- Plans: [`docs/superpowers/plans/2026-10-18-garage-slice-1a-backend.md`](docs/superpowers/plans/2026-10-18-garage-slice-1a-backend.md), [`docs/superpowers/plans/2026-10-18-garage-slice-1a2-contracts.md`](docs/superpowers/plans/2026-10-18-garage-slice-1a2-contracts.md)
- Runbook: [`docs/runbooks/tesla-setup.md`](docs/runbooks/tesla-setup.md)
