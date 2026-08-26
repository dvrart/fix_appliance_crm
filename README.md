# Fix Cloud

Marketplace clone of the appliance-repair CRM. Each subscriber creates their own company. The original shop app (`fix_appliance_crm`) stays private.

Do not point this project at Firebase `fix-appliance-crm`.

## First run (after a new Firebase project exists)

1. Enable Email/Password in Firebase Auth.
2. `flutterfire configure` (Android package `com.fixappliance.cloud`).
3. Put product keys in `lib/core/api_keys.dart` and `android/app/src/main/res/values/strings.xml` (`google_maps_key`).
4. Deploy `firestore.rules`.
5. Do not deploy functions until tenant routing is ready.

Trial: 14 days, then the paywall. Google Play Billing is not wired yet (debug unlock exists in debug builds).
