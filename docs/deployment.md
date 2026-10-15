# Deployment

The backend runs as a Cloudflare Worker named `rydah` with static assets from `backend/public/` and a D1 database named `rydah` (configured in `backend/wrangler.jsonc`). As of 2026-10-15, all four migrations (`0001_sessions.sql` through `0004_session_speed.sql`) are applied to the remote database and a `CREATOR_KEY` secret is set. The deployed Worker predates the trail and speed features; it runs unchanged on this schema until the next deploy. An hourly cron trigger (`0 * * * *`) runs the scheduled cleanup.

The public URL is intentionally not listed in this repository.

## Deploy an update

Run from `backend/` while logged in to the Cloudflare account that owns the Worker (`npx wrangler login`). Wrangler requires Node 22+.

```bash
cd backend
npm ci
npm test
npm run typecheck
npx wrangler d1 migrations list rydah --remote
npx wrangler d1 migrations apply rydah --remote
npx wrangler deploy
```

Apply new migrations before deploying code that depends on them. This is mandatory for `0003_session_trails.sql`: the trail-aware Worker writes to `session_points` on every upload and in the cron, so deploying it first breaks all location updates, not only trails. Applying the migration while the old Worker still runs is safe. The same applies to `0004_session_speed.sql`: the new upload statement writes `speed_mps`, so deploying the Worker first makes every location upload fail; the old Worker runs fine on the migrated schema. Never edit a migration that is already applied; add a new numbered file instead.

## First-time setup on a new account

1. `npx wrangler d1 create rydah` and put the returned ID in `backend/wrangler.jsonc` as `database_id`.
2. `npx wrangler d1 migrations apply rydah --remote`.
3. `npx wrangler secret put CREATOR_KEY` with a new random value. Never reuse the local demo key `rydah-local-demo-only`.
4. `npx wrangler deploy`.

## Point the app at the deployed backend

Either enter the Worker's HTTPS URL in **Settings → backend URL**, or build the app with it as the default:

```bash
cd mobile
flutter build apk --debug --dart-define=RYDAH_BACKEND_URL=https://YOUR-WORKER-URL
```

Without `RYDAH_BACKEND_URL`, the app defaults to `http://10.0.2.2:8787` (the local backend from an emulator). Device credentials are scoped to the backend URL, so switching backends uses a separate device identity.
