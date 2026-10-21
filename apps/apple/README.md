# Garage for iPhone and Mac

The product name is **Mews** (App Store listing "Mews: Tesla Companion"); `Mews` is the display name and the
word used in all user-facing copy. Everything internal keeps the working name: bundle id `com.duncanbottrill.garage`,
URL scheme `garage://`, target `Garage`, package `GarageKit`, and the Home Assistant add-on "Garage Bridge".

One multiplatform SwiftUI app target, `Garage` (iOS 26 and macOS 26, native on both, not Catalyst), around the
local Swift package `GarageKit`, which holds the logic, views, design tokens, fonts and icons.

## Setup

```sh
brew install xcodegen                         # once
cp Signing.xcconfig.example Signing.xcconfig  # git-ignored; holds DEVELOPMENT_TEAM (optional for unsigned builds)
xcodegen generate                             # writes Garage.xcodeproj (git-ignored)
open Garage.xcodeproj
```

The first package resolution (supabase-swift, swift-snapshot-testing) takes a few minutes. The target's base
configuration is the committed `Base.xcconfig`, which includes `Signing.xcconfig` only when it exists, so a fresh
clone without it still generates and builds with `CODE_SIGNING_ALLOWED=NO`.

## Build and test

```sh
xcodebuild -project Garage.xcodeproj -scheme Garage -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project Garage.xcodeproj -scheme Garage -destination 'platform=macOS' build -allowProvisioningUpdates
xcodebuild test -project Garage.xcodeproj -scheme Garage -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The macOS build needs a Mac App Development provisioning profile (Sign in with Apple), which automatic signing
creates the first time with `-allowProvisioningUpdates` or by building once from Xcode. To check the code compiles
without signing, add `CODE_SIGNING_ALLOWED=NO`.

Run the tests through `xcodebuild` (add `-only-testing:GarageKitTests` or `-only-testing:GarageKitSnapshotTests` for
one suite). Plain `swift test` in `GarageKit/` also runs the unit tests on the Mac, but SwiftPM does not compile the
icon asset catalog there, so `IconsTests.iconIsBundledAsTemplate` fails under it and nowhere else.

## Running on your devices

1. **Signing.** `cp Signing.xcconfig.example Signing.xcconfig` and set `DEVELOPMENT_TEAM` to your team ID (the example
   has the owner's). Keep `CODE_SIGN_STYLE = Automatic`. The file is git-ignored; never commit it.
2. **Project.** `xcodegen generate`, then `open Garage.xcodeproj`. Regenerate after pulling changes to `project.yml`
   or after adding files.
3. **Team.** In Xcode, select the Garage target → Signing & Capabilities and check the team is the one from
   `Signing.xcconfig`, with "Automatically manage signing" on.
4. **First build.** Pick the iPhone (connected by cable or on the same network, Developer Mode on) and Run. The first
   signed build registers the App ID `com.duncanbottrill.garage` with the Sign in with Apple capability and creates
   the development profiles. Then pick "My Mac" and Run for the macOS app. If Xcode asks to register the device or
   the App ID, accept.
5. **Tailscale.** Install Tailscale on both the iPhone and the Mac and sign them in to the same tailnet as the bridge,
   with MagicDNS on (the proxy URL is a `*.ts.net` name). Commands go to the bridge over the tailnet; Status and More
   work without it.
6. **Bridge add-on 0.3.0 and its proxy URL.** Before onboarding step 4 ("Reach your home bridge"), the Garage
   Bridge add-on must run version 0.3.0 or later (Home Assistant → Settings → Add-ons → Garage Bridge shows the
   version; update it there). 0.3.0 is the release whose proxy presents the Let's Encrypt certificate for the
   tailnet name, which iOS and macOS trust, and which publishes the proxy URL. Check that it has: in the Supabase
   dashboard, Table Editor → `vehicles`, the car's `proxy_base_url` column holds `https://<tailnet name>:4443`
   (or run `select vin, proxy_base_url from vehicles;` in the SQL editor). While it is `null` the step says the
   bridge hasn't published its address; once it is set, "Check again" re-reads it and moves on, no relaunch needed.
   It stays `null` when the add-on runs with `tailscale_enabled` off.
7. **Supabase.** The owner setup below must be done once: Apple provider with the bundle id in Client IDs, manual
   linking on, email/password kept for the bootstrap account. Sign in with **Use email** first, then run More →
   Link Apple ID.

## Pinned versions

| Source | Pin |
| --- | --- |
| supabase-swift | `.upToNextMinor(from: "2.55.4")` |
| swift-snapshot-testing | `.upToNextMinor(from: "1.19.6")` |
| google/fonts (fetch-fonts.sh) | commit `47d54ca1ebb14fd864695f1d39dc734f39017c33` |
| lucide-static (fetch-icons.sh) | `1.60.0` |

Package.resolved lives inside the generated (git-ignored) project, so the pins in `GarageKit/Package.swift` are what
keeps a fresh clone on the same dependency lines. Bump them deliberately and update this table.

## Generated and fetched files

- `GarageKit/Sources/GarageKit/Design/Tokens.swift` is generated from `packages/tokens/tokens.json`. Do not edit it;
  run `pnpm --filter @garage/tokens build` from the repo root and commit the result.
- `scripts/fetch-fonts.sh` refreshes Big Shoulders Display and Instrument Sans (SIL OFL 1.1) from google/fonts.
- `scripts/fetch-icons.sh` refreshes the Lucide icons (ISC) into `Resources/Icons.xcassets` as template vector images.
  Use them as `Image("lock", bundle: .module)` inside GarageKit.
- Licences ship in `GarageKit/Sources/GarageKit/Resources/LICENSES/`.

Call `GarageKit.registerFonts()` once at launch (the app does it in `GarageApp.init`); it is idempotent.

## Config

`Garage/Config.plist` holds public values only (Supabase URL and publishable key, API base URL). Never put secrets
in it.

## Owner setup

One-time steps in the Apple developer portal and the Supabase dashboard. The app compiles and its tests run
without them; only real sign-in needs them.

1. **Sign in with Apple in Supabase** (Authentication → Sign In / Providers → Apple): enable the provider and put
   `com.duncanbottrill.garage` (the app's bundle id) in "Client IDs", so native ID tokens from the iPhone and Mac
   app are accepted. For the web flow, also create the Services ID `com.duncanbottrill.garage.signin` and add the
   Team ID, Key ID and `.p8` key from the developer portal (Certificates, Identifiers & Profiles → Keys, with Sign
   in with Apple enabled). The App ID `com.duncanbottrill.garage` needs the Sign in with Apple capability.
2. **Manual linking** (Authentication → Sign In / Providers → "Allow manual linking"): turn it on. "Link Apple ID"
   in More calls `linkIdentityWithIdToken`, which Supabase refuses while manual linking is off.
3. **Keep email/password enabled** for the bootstrap account until "Link Apple ID" has been run once on the owner's
   device. After that, Sign in with Apple reaches the same account (and the same car).

> **Order matters.** The owner signs in with **Use email** first (the bootstrap account that owns the car), then
> runs **More → Link Apple ID**. Tapping Sign in with Apple before linking creates a *second*, empty Supabase user
> for that Apple ID; linking then fails because the Apple identity already belongs to it. Delete that extra user in
> the Supabase dashboard (Authentication → Users) before running Link Apple ID.

### How sign-in works

- Sign in with Apple runs natively (`SignInWithAppleButton`, or `ASAuthorizationController` for linking) with a
  random nonce: Apple gets its SHA-256, Supabase gets the raw value with the ID token (`signInWithIdToken`).
- "Use email" on the sign-in step is the owner's bootstrap account (`signIn(email:password:)`).
- Connect Tesla opens `POST /auth/start`'s URL in `ASWebAuthenticationSession`; the backend redirects to
  `garage://connected?ok=1` (or `?error=…`), which re-runs the onboarding checks.
- Sign out is local to the device. It clears the snapshot cache (it holds the car's location), the chosen vehicle
  (`selectedVehicleID`) and the onboarding-completed flag.

## Device verification checklist

Run on the owner's iPhone and Mac, both on the tailnet, with the bridge running. Write the result (pass/fail, date,
notes) in the last column; the same lines go in the plan's execution record.

| # | Check | How | Result |
| --- | --- | --- | --- |
| 1 | Cold start from cache in under 3 s | Force-quit, turn on Airplane Mode, launch. Status shows the last numbers within 3 s. | |
| 2 | Updates within 15 s while awake | With the car awake, change something on it (lock it from the Tesla app, open a window). Status shows it within 15 s. | |
| 3 | Lock / unlock | On home Wi-Fi, then on cellular: Lock, then Unlock. The icon flips at once and the car follows. | |
| 4 | Climate on/off and temperature | On Wi-Fi and cellular: Climate sheet → on, change the target, off. | |
| 5 | Charge limit | On Wi-Fi and cellular: Charge sheet → move the limit. The car reports the new limit. | |
| 6 | Charge port | On Wi-Fi and cellular: open, then close the port. | |
| 7 | Frunk | On Wi-Fi and cellular: Frunk → confirm. The lid pops. | |
| 8 | No wake without the prompt | With the car asleep, tap a command. The wake prompt appears; Cancel sends nothing (the car stays asleep, no wake in the usage ledger). | |
| 8a | Wake, then the command goes | With the car asleep, tap a command and confirm Wake. The pill stays pending while the car comes online (up to 30 s) and the command then goes once, without a second tap or a "still waking" toast. | |
| 8b | Wake from More | With the car asleep, More → Car shows "Wake the car". Wake asks first; Cancel sends nothing. Confirm: the detail reads "Waking…", then the row disappears as the car comes online and Status goes live. | |
| 8c | Reconnect clears the refusal | After a "Tesla refused Garage's token · reconnect Tesla" Connection row, Reconnect Tesla and finish the sign-in. The row turns green at once, before any command. | |
| 8d | Shared wake grace | With the car asleep, open Charge, change the limit and confirm the wake. Close the sheet and tap Lock within two minutes: it goes without a second prompt (and the same after Wake the car in More). | |
| 8e | Usage survives a kill | Send a command, then swipe the app away within a second. Relaunch: `api_usage.commands` for the month has gone up by one (the batch on disk was sent with its old id), and `Application Support/garage/usage.json` is gone again. | |
| 9 | Mac split layout and commands | On the Mac: the sidebar and the Status panel beside the map; lock/unlock and climate from the Mac. | |
| 9a | Map pan and panel stops (iPhone) | Drag the map: it pans and stays put. Drag the panel down: it snaps to the compact stop (charge, range, pills; tiles gone, more map). Drag it up: the tiles return. Force-quit and relaunch: the panel opens at the stop you left it. | |
| 10 | Bridge offline | Stop the bridge add-on for 2 min. Status shows "Telemetry paused since HH:mm" and the car becomes a solid dot (no halo). Start it again; both clear. | |
| 11 | Tailscale off | Turn Tailscale off on the iPhone. Within 20 s (one probe) the "Connect Tailscale to control the car" banner shows and the quick actions are dimmed and do nothing. Turn it back on; they come back. | |
| 12 | Rejected command | Make the car refuse one (for example start charging with no cable plugged in). The value reverts and the toast gives Tesla's reason. | |
| 13 | Token failure | Make `/api/token` fail (for example revoke the Tesla refresh token so the backend reports renewing, or point the app at a backend that answers 503 `token_unavailable`). A command shows the renewing toast, More → Connection turns red, and the app stays signed in on Status. | |
| 14 | Realtime fast restart | Background and foreground the app several times in a few seconds, then change something on the car. Status still updates within 15 s. | |
| 15 | Capsule edges | Look at the Sign in with Apple button and the glass capsules at full zoom for a 1 px sliver along an edge. | |

## Known limitations

Minor items that earlier reviews deferred and Slice 1C leaves open, plus what remains of the ones it fixed.

- **Time picker across DST.** On the spring-forward night the Charge schedule picker can show a time that does not
  exist that day.
- **°F targets.** The stepper moves one whole °F and stores the nearest 0.5 °C, so the number on screen never repeats
  or skips. The car still receives 0.5 °C steps, so its own °F display can differ from Garage's by up to 0.45 °F.
- **Wake prompt under a sheet.** A Status command that needs a wake while a Climate or Charge sheet covers Status is
  declined (nothing is sent) rather than asking; send it again from the sheet or after closing it.
- **Sheet edge cases.** An unrelated command queued behind one whose wake was cancelled is declined with it (asleep
  car only); a sent "on" schedule overlay sticks if the time is changed from elsewhere, until the sheet's model is
  dropped; the frunk → wake single-alert hand-over needs a device check; the `laterChangeRestartsQuietTime` test is
  timing-sensitive.
- **Mac layout.** The sidebar look and the tab-bar glass and tint are not covered by snapshots; Mac snapshots are
  iPad-trait renders, and the live MapKit path is not snapshotted. Below 1000 pt wide Status falls back to the single
  column, and the floating panel's height in short windows is unverified.
- **Accessibility sizes.** Tile heights are uneven at AX1, and the AX2 + scrolling-sheet path has no snapshot. The
  pill row now picks its style from "Unlock", so Lock and Unlock never change layout, but that case has no
  dedicated snapshot.
- **Capsule edges.** A 1 px sliver may show along the edge of the Sign in with Apple button and the glass capsules
  on some displays; it does not show in snapshots, so it is a device check (row 15 above).
- **Realtime restart.** The client library skips the server unsubscribe for a channel that is still joining, so a
  very fast restart can leave a second channel briefly; check 14 above covers it on device. If the app was offline
  at launch and the network comes back while it stays in the foreground, the store starts at the next foreground
  (or the next onboarding check).
- **Sign-in edge cases.** A 401 from an intermediary (not the backend) signs out
  locally; the backend's `token_exchange_failed` code is unused (it sends raw text, shown as generic copy); the email
  field trims spaces but not newlines.
- **Vehicle check.** A car already in memory satisfies the onboarding vehicle check, so a car unlinked on another
  device is noticed only after a relaunch.
- **Usage ledger.** Counts live on disk until `/api/usage` acknowledges them and are re-sent under the same
  `report_id` (counted once for 30 days; offline retries back off to 10 min). Sign-out waits at most 3 s for
  them; a batch that reaches 25 days unsent, or one refused with a 4xx or three 5xx answers, is dropped.
- **Decoding and storage.** Nested `jsonb` columns are decoded strictly (a malformed `doors` object fails the row
  rather than that field), and outside the sandbox (tests, `swift test`) the snapshot lives in the generic
  `Application Support/garage` folder.
