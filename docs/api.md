# API, devices and private groups

Examples use the local backend at `http://localhost:8787` and the local creator key. See the [README](../README.md#run-the-local-backend) to start it.

## Migrations

Apply all local migrations with `npx wrangler d1 migrations apply rydah --local`. Migration `0001_sessions.sql` remains unchanged; `0002_private_groups.sql` adds devices, profiles, private groups, invitations and sharing audiences; `0003_session_trails.sql` adds the optional trail setting and trail points; `0004_session_speed.sql` adds GPS speed and its accuracy on the current point.

## Bootstrap a private group

```bash
curl -sS http://localhost:8787/api/admin/groups \
  -H 'Authorization: Bearer rydah-local-demo-only' \
  -H 'Content-Type: application/json' \
  --data '{"name":"Weekend riders"}'
```

The response contains `groupId` and an owner `invitation` with `id`, `token`, `expiresAt`, and `joinUrl`. Paste its full `joinUrl` into **Join group** in the Android app to enroll the owner. Opening `/join.html#token=…` in a browser only offers a copy button; it never enrolls a device or retrieves a group roster. Invitations expire after 24 hours and enroll one device.

## Invitations

Owners create further invitations in the app, or through the device-authenticated endpoint:

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

## Enrollment and devices

Native clients generate and persist `deviceId` and `deviceToken` before `POST /api/enroll`; the invitation token is the bearer credential and the JSON body is `{deviceId,deviceToken,name}`. Device/session IDs use 1–128 ASCII letters, digits, underscores or hyphens (UUIDs are suitable). Tokens are 32 cryptographically random bytes encoded as 64 lowercase hexadecimal characters. An exact enrollment retry is allowed for the same active device; consumed invitations cannot enroll another device or restore revoked membership.

A device that only shares private links registers itself without an invitation: `POST /api/devices` with `{deviceId,deviceToken,name}` and no bearer token returns its profile (201, or 200 for an exact retry; different credentials for the same ID get 409). It can then set its photo and create `viewer` sessions; `group` sessions still require membership, and the same device can join a group later with an invitation.

## Sharing sessions

Use the device token for `/api/me`, `/api/group`, and `POST /api/me/sessions`. Session creation accepts locally persisted `{id,readToken,writeToken,audience,durationMinutes}`; `audience` is `viewer` or `group`, and durations are 30, 60, 120 or 240 minutes (default 60). Only one session per device is active. Exact retries preserve its original expiry; a stopped, expired or conflicting session ID cannot start a new share. Viewer shares appear only through their private read link; group shares also appear in the member roster. A device can start a viewer share after leaving a group. Removal, leaving, or group deletion immediately ends all sessions that existed for the affected device.

The legacy creator-key route `POST /api/sessions` (used by the simulator) still creates one-hour sessions without a trail.

## Speed

`PUT /api/sessions/:id/location` accepts optional `speedMps` and `speedAccuracyMps` (GPS speed and its accuracy, m/s, each finite and 0–100; absent or `null` means unknown, anything else returns 400). They are stored with the current point only; an upload without them stores `null`. Both reads (`GET /api/sessions/:id` and `GET /api/group`) include them in `location`:

```json
{ "lat": 41.0, "lon": 29.0, "accuracyM": 8, "speedMps": 13.4, "speedAccuracyMps": 1.2, "observedAt": 1760000000000, "receivedAt": 1760000000500 }
```

## Trails

Session creation also accepts `trail`: `off` (default when absent), `15m`, `30m` or `session`. It is part of exact-retry matching (a different value returns 409) and is echoed in the response. With a trail, each accepted upload also stores at most one trail point per 10 seconds; points outside the chosen window are pruned, and every point is deleted when the session ends or is deleted.

Reads return a `trail` field, `null` when off or ended:

```json
{ "setting": "15m|30m|session", "windowStartsAt": 1760000000000, "reset": true,
  "points": [[seq, lat, lon, observedAt]] }
```

- `GET /api/sessions/:id?since=<seq>` returns only points after `seq`. Without `since`, `reset` is true and the client replaces its cache. `since` must be up to 15 digits.
- `GET /api/group?trailSince=<deviceId>:<expiresAt>:<seq>,...` (at most 32 cursors; send `trailSince=` empty on first load) returns each sharing member's trail in `sharing.trail`. A cursor whose `expiresAt` differs from the member's current session gets the whole window with `reset: true`. Viewer-only shares never appear. Without the `trailSince` parameter (older apps), `sharing.trail` is always `null`.
- `windowStartsAt` is null for `session`; clients drop cached points older than it.

## Profiles, photos and group management

Profiles have names of 1–60 characters. `PUT /api/me/avatar` takes raw `image/png` bytes with a PNG signature, a 128×128 IHDR, and a maximum size of 65,536 bytes. Photos are fetched with authorization from group-member or session-avatar endpoints; no public photo URL or base64 photo field exists. Members can set or clear the group's meeting point. The owner can revoke invitations, remove members, or delete the group; members can leave, while the owner must delete the group.

## Response headers and cleanup

All API and photo responses use `no-store` and `no-referrer`; photos also use `nosniff`. Unconsumed expired invitations and expired session rows are removed by scheduled cleanup. Consumed invitations retain their hashed enrollment receipt for exact retries, and session ID claims remain to reject replay after location cleanup. Neither receipt contains a location.

The full endpoint table and authorization contract are in [plans/2026-10-14-private-riding-group.md](plans/2026-10-14-private-riding-group.md#api-contract).
