# Rydah

A runnable Android motorcycle app with local ride recording, route drafts and GPX import, plus private live-location sharing through a browser link. Ride history and routes stay in SQLite on the phone. The Android sender uses device GPS; the optional browser simulator is explicitly labeled and sends generated points through the same API.

## Run the local backend

Requires Node 22.12+ (Node 24 recommended), npm, and Flutter 3.38+ for Android. This workspace also has Node 24 at `/Users/kurtulusn/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin` and Flutter at `/Users/kurtulusn/fvm/default/bin/flutter`.

```bash
# Optional on this machine, to select the bundled Node 24:
export PATH=/Users/kurtulusn/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin:$PATH
cd backend
npm ci
cp .dev.vars.example .dev.vars
./node_modules/.bin/wrangler d1 migrations apply rydah --local
npm run dev -- --ip 0.0.0.0
```

The local creator key in `.dev.vars.example` is **rydah-local-demo-only**. It is a development-only value; the Worker has no public fallback key. `.dev.vars` is ignored. The creator key bootstraps groups and the legacy simulator. Device credentials are persisted on the phone; invitation and viewer pages keep their tokens in memory and strip URL fragments immediately.

Backend and viewer: http://localhost:8787. Leave the backend terminal running. The local listener is accessible on your LAN when bound to `0.0.0.0`; use a private trusted network for this development setup.

### Bootstrap a private group

Apply both local migrations with the command above. Migration `0001_sessions.sql` remains unchanged; `0002_private_groups.sql` adds devices, profiles, private groups, invitations and sharing audiences.

```bash
curl -sS http://localhost:8787/api/admin/groups \
  -H 'Authorization: Bearer rydah-local-demo-only' \
  -H 'Content-Type: application/json' \
  --data '{"name":"Weekend riders"}'
```

The response contains `groupId` and an owner `invitation` with `id`, `token`, `expiresAt`, and `joinUrl`. Paste its full `joinUrl` into **Join group** in the Android app to enroll the owner. Opening `/join.html#token=…` in a browser only offers a copy button; it never enrolls a device or retrieves a group roster. Invitations expire after 24 hours and enroll one device. Owners create further invitations in the app, or through the device-authenticated endpoint:

```bash
# Set RYDAH_DEVICE_TOKEN to the enrolled owner's private device token locally.
curl -sS http://localhost:8787/api/group/invitations \
  -H "Authorization: Bearer $RYDAH_DEVICE_TOKEN" -X POST
curl -sS http://localhost:8787/api/group/invitations \
  -H "Authorization: Bearer $RYDAH_DEVICE_TOKEN"
# Replace INVITATION_ID with the returned invitation ID to revoke it.
curl -sS http://localhost:8787/api/group/invitations/INVITATION_ID \
  -H "Authorization: Bearer $RYDAH_DEVICE_TOKEN" -X DELETE
```

Native clients generate and persist `deviceId` and `deviceToken` before `POST /api/enroll`; the invitation token is the bearer credential and the JSON body is `{deviceId,deviceToken,name}`. Device/session IDs use 1–128 ASCII letters, digits, underscores or hyphens (UUIDs are suitable). Tokens are 32 cryptographically random bytes encoded as 64 lowercase hexadecimal characters. An exact enrollment retry is allowed for the same active device; consumed invitations cannot enroll another device or restore revoked membership.

Use the device token for `/api/me`, `/api/group`, and `POST /api/me/sessions`. Session creation accepts locally persisted `{id,readToken,writeToken,audience,durationMinutes}`; `audience` is `viewer` or `group`, and durations are 30, 60, 120 or 240 minutes (default 60). Only one session per device is active. Exact retries preserve its original expiry; a stopped, expired or conflicting session ID cannot start a new share. Viewer shares appear only through their private read link; group shares also appear in the member roster. A device can start a viewer share after leaving a group. Removal, leaving, or group deletion immediately ends all sessions that existed for the affected device.

Profiles have names of 1–60 characters. `PUT /api/me/avatar` takes raw `image/png` bytes with a PNG signature, a 128×128 IHDR, and a maximum size of 65,536 bytes. Photos are fetched with authorization from group-member or session-avatar endpoints; no public photo URL or base64 photo field exists. Members can set or clear the group's meeting point. The owner can revoke invitations, remove members, or delete the group; members can leave, while the owner must delete the group.

All API and photo responses use `no-store` and `no-referrer`; photos also use `nosniff`. Unconsumed expired invitations and expired session rows are removed by scheduled cleanup. Consumed invitations retain their hashed enrollment receipt for exact retries, and session ID claims remain to reject replay after location cleanup. Neither receipt contains a location.

## Run the actual Android app

```bash
cd mobile
/Users/kurtulusn/fvm/default/bin/flutter pub get
/Users/kurtulusn/fvm/default/bin/flutter run -d emulator-5554
```

The app has Ride, History, Routes and Settings tabs. On **Ride**, tap **Start ride** to record locally, and **Start sharing** to create a one-hour private viewer link. In **Routes**, create a draft by adding stops to the map or import a GPX file; draft routes draw straight lines and do not provide turn-by-turn navigation. History, routes and recorded GPS points remain usable without the backend.

The emulator's backend URL is `http://10.0.2.2:8787`. The development creator key is prefilled in **Settings**. Allow Android location access, then use **Copy private link** on the Ride tab and open it in a desktop browser. Emulator viewer links use `localhost` so they open on the development computer. For a remote viewer, use a backend URL reachable from that viewer (for example the computer's LAN address) before creating the session.

In emulator Extended Controls → Location, choose a position or route if GPS is not updating. Emulator locations are test positions; the same app obtains real device GPS on a physical phone.

To build/install the APK:

```bash
cd mobile
/Users/kurtulusn/fvm/default/bin/flutter build apk --debug
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 shell am start -n app.rydah.mobile/.MainActivity
```

For a USB-connected phone:

```bash
adb reverse tcp:8787 tcp:8787
```

Install the debug APK, open **Settings**, and set the backend URL to `http://localhost:8787`. That URL is forwarded from the phone to the development computer. A viewer on the same computer uses localhost; a different person's browser needs a shared reachable backend, which this local-only setup does not provide. Alternatively, use the computer's LAN IP from a phone on the same Wi-Fi network. Production deployment is deferred.

Keep the sender app open. A foreground location notification is enabled where Android permits it, but background tracking is not guaranteed. Battery controls, permissions, backgrounding and connectivity can interrupt updates. There is no background-location permission in this demo. **Stop sharing** shows confirmation only after the server clears the stored point; on failure it retains the stop credential and offers retry.

## Optional two-tab simulation

Open http://localhost:8787/simulate.html, enter the local creator key and start. Open its private viewer link in another tab. The viewer prominently says **SIMULATION — NOT PHONE GPS**. Watch the marker/coordinates change, then stop the simulator: the viewer changes to ended and removes coordinates. Closing the simulator without stopping leaves the last point to age from live → stale → offline; its session expires after one hour.

The viewer polls every five seconds and ages the displayed point between polls. The map centers on the first position, then updates its marker without changing your pan or zoom. Use the small **Recenter** button to return to the latest position at the initial zoom level. Live means captured within 20 seconds, stale 20–60 seconds, and offline over 60 seconds. Offline is inferred from silence and is not a confirmed phone connection state. Connection failures show a separate retry message. The map requires internet; coordinate readings remain usable if the external map cannot load.

## Verification

```bash
cd backend
npm test
npm run typecheck
cd ../mobile
/Users/kurtulusn/fvm/default/bin/flutter analyze
/Users/kurtulusn/fvm/default/bin/flutter test --reporter expanded
/Users/kurtulusn/fvm/default/bin/flutter build apk --debug
```

Backend tests use Miniflare D1 with both migrations. They cover group and invitation authorization, one-use enrollment and exact retries, profile/photo access, meeting points, audience isolation, membership/session revocation races, requested durations, idempotent creation, location ordering and freshness. Browser tests cover private photo authorization, safe sender names, blob cleanup and retry, legacy fallback, pan/zoom preservation, and invitation fragment handling. Flutter tests cover stop during creation, one upload in flight, failed-stop retry, permission errors, expiry without GPS or during an upload, and terminal HTTP 410 recovery. Network errors and nonterminal server errors retain the stop credential for retry.

## Privacy, storage and deployment

Each session has independent random 256-bit read/write secrets. D1 stores only their SHA-256 hashes. Viewer links put the read secret in a URL fragment, parse it into memory, and immediately remove the fragment from browser history. API responses are not cached. Do not share the full private link beyond your intended viewers.

One current point per session is retained; there is no route history. Stopping clears its coordinates. Device sessions expire after their chosen 30, 60, 120 or 240 minutes; the legacy creator/simulator route still uses one hour. Reads and writes after expiry return 410 without coordinates. The hourly scheduled cleanup deletes expired session rows, retaining a last point for at most roughly one hour beyond its expiry when the deployed schedule runs. Used session IDs remain as location-free replay protection. Local development does not automatically run cron. To manually delete expired local rows:

```bash
cd backend
./node_modules/.bin/wrangler d1 execute rydah --local --command "DELETE FROM sessions WHERE expires_at <= CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)"
```

OpenStreetMap receives the viewed map area; private API credentials are not sent to it. External Google Fonts loads the interface font. Both pages use `Referrer-Policy: no-referrer`; map tile requests override this to send only the site origin for OpenStreetMap attribution of requests. Leaflet 1.9.4 is served locally from `backend/public/vendor/leaflet`. Local HTTP is only for development; debug Android permits cleartext networking. A shared public backend requires HTTPS and a new private creator secret.

Nothing is deployed. Later, with the user's Cloudflare account: create a D1 database, replace the placeholder database ID in `backend/wrangler.jsonc`, apply the migration remotely, set `CREATOR_KEY` with `wrangler secret put`, deploy the Worker/static assets, and point the Android app at its HTTPS URL. Do not reuse the local demo key publicly.
