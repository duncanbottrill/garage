# Tesla setup runbook (one-time, Duncan)
1. `apps/web/scripts/keygen.sh` → commit the public key; store `~/.garage/private-key.pem` in 1Password.
2. Deploy `apps/web` (Task 12) and confirm `curl https://garage.duncanbottrill.com/.well-known/appspecific/com.tesla.3p.public-key.pem` returns the PEM.
3. `.env.local` with TESLA_CLIENT_SECRET etc., then `pnpm --filter @garage/web exec tsx scripts/register-partner.ts` → expect 200 and the public key echoed back.
4. Pair the key: at the car, on the phone with the Tesla app, open `https://tesla.com/_ak/garage.duncanbottrill.com` and approve.
5. Connect the account: from the app's onboarding (Plan 1C), or temporarily by calling `/auth/start` with a Supabase JWT.
