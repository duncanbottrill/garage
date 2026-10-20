# Garage for iPhone and Mac

One multiplatform SwiftUI app target, `Garage` (iOS 26 and macOS 26, native on both, not Catalyst), around the
local Swift package `GarageKit`, which holds the logic, views, design tokens, fonts and icons.

## Setup

```sh
brew install xcodegen                         # once
cp Signing.xcconfig.example Signing.xcconfig  # git-ignored; holds DEVELOPMENT_TEAM
xcodegen generate                             # writes Garage.xcodeproj (git-ignored)
open Garage.xcodeproj
```

The first package resolution (supabase-swift, swift-snapshot-testing) takes a few minutes.

## Build and test

```sh
xcodebuild -project Garage.xcodeproj -scheme Garage -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project Garage.xcodeproj -scheme Garage -destination 'platform=macOS' build -allowProvisioningUpdates
xcodebuild test -project Garage.xcodeproj -scheme Garage -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The macOS build needs a Mac App Development provisioning profile (Sign in with Apple), which automatic signing
creates the first time with `-allowProvisioningUpdates` or by building once from Xcode. To check the code compiles
without signing, add `CODE_SIGNING_ALLOWED=NO`.

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
