# Tesla setup runbook (one-time, Duncan)
1. `apps/web/scripts/keygen.sh` → commit the public key; store `~/.garage/private-key.pem` in 1Password.
2. Deploy `apps/web` (Task 12) and confirm `curl https://garage.duncanbottrill.com/.well-known/appspecific/com.tesla.3p.public-key.pem` returns the PEM.
3. `.env.local` with TESLA_CLIENT_SECRET etc., then `pnpm --filter @garage/web exec tsx scripts/register-partner.ts` → expect 200 and the public key echoed back.
4. Pair the key: at the car, on the phone with the Tesla app, open `https://tesla.com/_ak/garage.duncanbottrill.com` and approve.
5. Connect the account: from the app's onboarding (Plan 1C), or temporarily by calling `/auth/start` with a Supabase JWT.
6. Mint the bridge secret, once per owner:
   ```
   curl -X POST -H "authorization: Bearer $ADMIN_SECRET" -H "content-type: application/json" \
     -d '{"owner_id":"<owner uuid>"}' https://garage.duncanbottrill.com/api/admin/bridge-secret
   ```
   Store the returned secret in the add-on options (`x-bridge-secret` header for `GET /api/bridge/token`); it is shown once.
7. Set `ALLOWED_OWNER_IDS` on Vercel to the owner uuid(s).
8. Once the owner account exists, disable email sign-ups in the Supabase dashboard: Authentication → Providers → Email → turn off "Allow new users to sign up". Only do this after deciding how the Apple identity will be linked to the owner account (Plan 1C) — disabling sign-ups first would block that linking path.
