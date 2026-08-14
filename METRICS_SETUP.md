# Foldiq owner metrics

Private dashboard: `https://foldiq.app/owner`

## Privacy contract

- macOS and Windows telemetry is optional and disabled by default.
- Allowed events: completed scan, organization, and undo.
- Allowed fields: platform, app version, success, duration bucket, item-count bucket, random event ID, and random install ID.
- The API hashes the install ID with a private salt before storage.
- Photos, videos, filenames, paths, capture dates, locations, EXIF, and other metadata are forbidden by schema and tests.
- Events are retained for at most 90 days.

## Production environment variables

Configure these only in Vercel Production; never place their values in the repository or desktop apps.

- `OWNER_DASHBOARD_TOKEN`: long random access code for `/owner`.
- `OWNER_EMAILS`: comma-separated owner emails excluded from external-customer totals.
- `TELEMETRY_HASH_SALT`: long random value used only for one-way install hashing.
- `SUPABASE_URL`: dedicated Foldiq metrics project URL.
- `SUPABASE_SECRET_KEY`: backend-only Supabase secret key.
- Existing `STRIPE_SECRET_KEY` and `GITHUB_RELEASE_TOKEN` feed live Windows sales and download data.

Apple metrics currently show the audited 90-day snapshot. To automate App Store Connect, create a read-only Sales and Reports API key and store its issuer ID, key ID, and private key only in Vercel.

Windows download fulfillment is counted on each verified Stripe transaction beginning August 14, 2026. This distinguishes unique purchases that requested the installer from repeat requests. GitHub asset counts remain useful only as a total request counter and cannot identify historical unique buyers.

## Before the next app release

1. Apply the Supabase migration in `supabase/migrations/` and schedule daily deletion of rows older than 90 days.
2. Configure the production environment variables above.
3. Update App Store Connect's privacy answers to disclose optional, non-linked Product Interaction and Device ID data used for analytics.
4. Re-run web, Windows, and macOS builds.
