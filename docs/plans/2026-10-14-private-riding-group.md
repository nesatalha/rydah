# Private Riding Group Implementation Plan

> **Status:** Implemented in PR #3. File names differ from this plan (for example `account_store.dart` and `account_controller.dart` instead of `profile_store.dart` and `identity_store.dart`), and `flutter_secure_storage` is `^11.2.0`.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let a small group of friends join by invitation, recognize one another by name/photo, optionally share their location for a chosen duration, and agree on a meeting point, while a spouse's private browser link reveals only its sender.

**Architecture:** Preserve Flutter's offline SQLite rides/routes and Cloudflare Worker/D1 sharing service. Add a locally stored profile, secure per-device identity, persistent invitation-only membership, and explicitly started expiring sharing sessions. Group membership never implies location sharing; session bearer tokens remain separate from device credentials.

**Tech Stack:** Existing Flutter/Dart, SQLite, flutter_map, file_picker, dart:ui, flutter_secure_storage 9.0.0; Cloudflare Workers/D1, TypeScript, Miniflare, native browser JavaScript/Leaflet.

---

## Approved scope and workflow

The user has approved planning and implementation; do not ask for approval again. Execute two sequential implementation tasks: backend/browser first, then Flutter integration. Use the requested Astra high planner, Sol high implementers, and Sol medium specification and code reviews. Review each task and resolve actionable findings before moving on. Work in `/Users/kurtulusn/.codex/worktrees/private-riding-group/rydah`.

No Firebase, account login, contact discovery, route navigation, background GPS guarantee, or public deployment. The group is intended for three friends; no arbitrary three-member restriction is necessary. One active group per device is enough. Existing local recording/history/route editing/GPX and the creator-key simulator must continue working. A profile is usable offline before joining a group; profile editing alone never requests GPS permission.

## Data and authorization contract

Use a migration `backend/migrations/0002_private_groups.sql`; never rewrite the deployed initial migration. Add profiles/devices, groups, memberships, invitations, private avatar bytes and session ownership/audience columns. Names are trimmed nonempty strings capped at 60 characters; group/meeting labels capped at 100. Validate JSON shapes, finite coordinates, bounded request bodies, allowed durations, identifiers and cryptographic token lengths. Use parameterized SQL and atomic D1 batches/conditional writes for consume/create/remove operations.

Generate device IDs and 32-byte random device bearer tokens on Flutter before enrollment, persist securely before issuing the request, and store only token hashes server-side. Device identity identifies possession of that installation, not a verified person. Ordinary clients never receive CREATOR_KEY. Store local display name/photo in local storage; store device credentials, invitation recovery data and session read/write tokens in secure storage, scoped to the normalized backend URL. Do not log tokens or put them in query strings. Raw credentials never appear in group/profile responses.

A single-use invitation is a 32-byte token stored hashed, bound to a group and role, expiring after 24 hours, revocable by its owner. The first invitation grants owner; later invitations grant member. Persist enrollment inputs before POST so a lost response can be retried. An exact retry of a consumed invitation with the same device ID/token returns the existing active enrollment; a different credential, revoked membership or changed group must never recreate access. Concurrent invitation consumption must produce at most one member. Membership is checked on every protected request, including avatar and location writes.

New device-owned sessions have audience `viewer` or `group`. `viewer` shares only through its private link; `group` also appears to current group members and may provide the same sender-only spouse link. Limit to one active device-owned session per device. Durations are 30, 60, 120 or 240 minutes, default 60. Client generates session ID/read/write tokens and persists a pending creation record before POST; retries of identical creation return the original expiry and credentials, never extend expiry or create an extra session. Conflicting IDs/credentials/options return 409. Stop or expiry permanently ends access; retries must not resurrect a session.

Group responses return roster identity/status and only currently authorized, unexpired group-audience locations. Retain existing 20-second live/60-second stale age thresholds. Viewer-only sessions must not appear as group activity or disclose their location. Return no session read/write token to group members. Ended/expired sessions expose no location or avatar. Removing/leaving/deleting membership ends affected device-owned sessions and clears their locations immediately, including pending requests racing with removal. Group-avatar endpoints require current common membership. The public viewer cannot enumerate members, meeting points, invitation details or group IDs.

Avatar upload is raw PNG, exactly 128×128, at most 65,536 bytes. Flutter decodes an image, center-crops, resizes and re-encodes with dart:ui (removing source metadata). Backend checks PNG signature/IHDR dimensions and bounded length; store bytes privately in D1. Reject SVG and arbitrary upload MIME types. Return bytes only through an authenticated endpoint with `Content-Type: image/png`, `X-Content-Type-Options: nosniff`, `Cache-Control: no-store`, and `Referrer-Policy: no-referrer`. Avatar versions permit in-memory refresh; removal revokes subsequent fetches. No public object URLs or embedded raw image data in JSON. Profile/avatar fetch failures use an initials fallback.

## API contract

Unless noted, authentication is `Authorization: Bearer <deviceToken>` and successful reads/writes return JSON. Use 400 for malformed inputs, 401 for invalid credentials, 403 for insufficient role, 404 for unavailable scoped resources, 409 for conflicts, 410 for expired invitation/session and 204 for deletion. Apply no-store/no-referrer to all API responses, including errors. Unauthenticated requests must not reveal resource existence.

| Method/path | Authentication and behavior |
| --- | --- |
| `POST /api/admin/groups` | CREATOR_KEY; body `{name}`; create group plus owner invitation; return `{groupId, invitation: {id, token, expiresAt, joinUrl}}` (201). Bootstrap is explicitly invoked in Settings; the key is held only in memory. |
| `POST /api/enroll` | Invitation bearer; body `{deviceId, deviceToken, name}`; atomically consume invitation and create identity/membership; exact retry semantics above; return `{profile, group, role}`. |
| `GET /api/me` | Return `{deviceId, name, avatarVersion, groupId, role}`; never include credential hashes. |
| `PUT /api/me` | `{name}` updates server profile; local edits may sync on next connection. |
| `PUT /api/me/avatar` | Raw normalized PNG; return `{avatarVersion}`. |
| `DELETE /api/me/avatar` | Delete private avatar, return 204. |
| `GET /api/group` | Return `{id, name, role, meetingPoint, members}`. Member: `{deviceId, name, avatarVersion, sharing}`; sharing is null or `{state, expiresAt, location}` for group audience only. Meeting point: `{lat, lon, label, updatedAt, updatedBy}` or null. |
| `GET /api/group/members/:deviceId/avatar` | Current common-group membership required, returns PNG or 404. |
| `POST /api/group/invitations` | Owner only; create member invite; return `{id, token, expiresAt, joinUrl}` (201). |
| `GET /api/group/invitations` | Owner only; list invite IDs, expiry/consumed/revoked status without tokens. |
| `DELETE /api/group/invitations/:id` | Owner only; revoke scoped invitation; idempotent 204. |
| `DELETE /api/group/members/:deviceId` | Owner only, cannot remove self through this route; revoke member and all their active sessions, clear locations, return 204. |
| `DELETE /api/group/membership` | Member leaves and ends sessions; owner receives 409 directing them to delete the group. |
| `DELETE /api/group` | Owner only; delete/revoke group, invitations, memberships and their active sessions; keep each installation's local rides/profile. |
| `PUT /api/group/meeting-point` | Any current member; body `{lat, lon, label}`, validated coordinates; last completed write wins; return meeting point. |
| `DELETE /api/group/meeting-point` | Any current member; 204. |
| `POST /api/me/sessions` | Body `{id, readToken, writeToken, audience, durationMinutes}`; require active membership for group audience; viewer audience also works for an enrolled device without a current group. Return `{id, readToken, writeToken, expiresAt, audience}`. |
| `GET /api/sessions/:id` | Existing read bearer. For new sessions include sender `{name, avatarVersion}` in addition to existing source/state/expiry/location; never group data. Legacy sessions remain valid with absent sender. |
| `GET /api/sessions/:id/avatar` | Read bearer; only active, unexpired session's sender avatar; no access after stop/expiry/removal. |
| `PUT /api/sessions/:id/location` | Existing write bearer and sequence/freshness rules; new device-owned sessions also require valid current ownership/membership where applicable. |
| `DELETE /api/sessions/:id` | Existing write bearer; idempotent terminal stop clearing coordinates. |
| `POST /api/sessions` | Preserve existing creator-key legacy one-hour device/simulation creation. |

`joinUrl` uses `/join.html#token=...`. Join page reads and strips the fragment immediately, explains installation/opening the app and provides a user-invoked copy action for the complete invitation link. It must never enroll a browser or fetch group contents. Flutter supports pasting the full invitation link or token with a configured backend. A full link selects/displays its backend origin before enrollment; never send an existing device token to a different origin. Allow HTTP for explicit localhost/emulator development; deployment instructions require HTTPS. Universal/app links are optional, not required.

## Task 1: Backend, private invitation landing page and spouse viewer

**Files**
- Create `backend/migrations/0002_private_groups.sql`, `backend/public/join.html`, `backend/public/join.js`, `backend/test/groups.test.ts`, `backend/test/join.test.ts`.
- Modify `backend/src/index.ts`, `backend/public/view.html`, `backend/public/view.js`, `backend/test/api.test.ts`, `backend/test/view.test.ts`, `README.md`.
- Extract cohesive backend modules under `backend/src/` if needed; avoid a single unreviewable route handler. Update every Miniflare fixture to apply both migrations.

1. Write failing API tests for group bootstrap, one-time enrollment/exact retry, invite revocation/expiry/concurrent redemption, owner/member authorization and foreign group isolation. Run `npm test` in `backend`; confirm failures indicate missing feature behavior.
2. Implement migration, credential hashing, scoped membership checks and enrollment transaction. Add bounded validators and sanitized response DTOs. Run the focused tests.
3. Write failing tests for profile/avatar update/delete, foreign member and unauthenticated avatar denial, meeting point update/delete, member removal/leave/group deletion and owner-only mutations. Implement those routes, including immediate session revocation on membership loss. Re-run focused tests.
4. Write failing tests for duration validation, exact session-creation retry after lost response, conflicting/replayed ended session ID, viewer/group isolation, sender-only viewer DTO, expired/stopped avatar denial, stale locations and upload/removal races. Implement authenticated session creation and reuse the existing location endpoint validation/sequence semantics. Preserve all legacy API tests. Scheduled cleanup removes expired sessions and old invitations without allowing expired data to be returned before cleanup runs.
5. Add the invitation landing page and safe fragment stripping/copy behavior. Browser code uses textContent for untrusted names. Update viewer to show sender name and photo marker using an authenticated fetch and temporary blob URL; revoke blob URL on replace/end/expiry/unavailable state. Existing recenter behavior must continue working and panning must not be overridden on polling. Empty/legacy profiles use an initials/dot marker. Never add a group fetch to the spouse viewer.
6. Add browser tests for private avatar authorization headers, name rendering without HTML injection, blob URL cleanup, stopped/expired marker clearing and legacy simulation compatibility. Extend existing test harness if necessary.
7. Run `npm test` and `npm run typecheck` in `backend`. Both must pass. Document local migration/bootstrap/member invite/spouse viewer operations in `README.md`. Commit task after specification and code review; fix review findings before Flutter implementation.

## Task 2: Flutter profile, membership, group map and durable sharing controls

**Files**
- Create `mobile/lib/profile_store.dart`, `mobile/lib/identity_store.dart`, `mobile/lib/group_models.dart`, `mobile/lib/group_api.dart`, `mobile/lib/group_controller.dart`, `mobile/lib/group_screen.dart`, `mobile/lib/avatar_marker.dart`.
- Modify `mobile/lib/app_shell.dart`, `mobile/lib/settings_screen.dart`, `mobile/lib/sharing_api.dart`, `mobile/lib/location_sender.dart`, `mobile/lib/ride_screen.dart`, `mobile/pubspec.yaml`, `mobile/pubspec.lock`.
- Create `mobile/test/identity_store_test.dart`, `mobile/test/group_api_test.dart`, `mobile/test/group_controller_test.dart`, `mobile/test/group_screen_test.dart`; extend `mobile/test/sender_test.dart` and `mobile/test/app_shell_test.dart`.
- Preserve local SQLite ride/route schema unless adding a small separate profile table is cleaner than a separate local profile file. Keep profile storage injectable in tests and avoid mixing credentials into SQLite.

1. Add `flutter_secure_storage: 9.0.0` (cached version), injectable secure storage and HTTP transport boundaries. Write tests for origin-scoped identity/session persistence, interrupted enrollment and exact retry. Implement device credential generation with Random.secure, profile load/save, secure pending enrollment and session records. Handle unreadable secure storage visibly; never silently generate replacement credentials that orphan an active session.
2. Build local name/photo editing in Settings. Use existing file_picker plus dart:ui decode/crop/resize/re-encode; handle cancellation, unsupported/large source images and processing failures. Allow photo removal and initials fallback. Save profile locally before network sync, retain pending sync state across restart, and avoid claiming server update while offline. Add API/DTO tests and profile persistence tests.
3. Add invite enrollment in Settings (paste link/token), group/role status, and an explicitly labeled development owner bootstrap section accepting group name and a manually entered creator key. Bootstrap creates owner invitation then enrolls the already persisted identity. Never ship or prefill a production secret. Persist backend URL and block changing it while session creation, active share or stop recovery is pending. Show owner create/copy/revoke invite, remove member and delete-group controls; show leave for ordinary members. Confirm destructive group actions through ordinary UI dialogs.
4. Add a Group destination while preserving Ride/History/Routes/Settings. Group screen displays roster including non-sharing members, own profile, sharing status, photo/initial markers, meeting point and last refresh/error. Poll about every five seconds while visible/foreground; no concurrent overlapping fetches. Clear cached group locations and avatars immediately on authorization/membership loss; expire individual locations locally even while disconnected. On network failure retain only unexpired last-known data with explicit stale/offline age, never call it live. Avoid saving peers' locations/photos to durable disk storage. Pause polling in background and resume fetch on foreground without restarting sharing.
5. Add meeting-point map tap selection plus a label, save/remove actions, and a distinct meeting-point marker. Use a dedicated group map or extend TrackMap without changing ride/route map semantics. Update markers without reconstructing the map on every poll; preserve user pan/zoom and provide recenter/fit action. Support showTiles=false in widget tests.
6. Extend sharing UI with audience (`Private link` or `Group + private link`) and duration choices (30m/1h/2h/4h; default 1h), visibly show countdown/status, and support copying the spouse link. Only explicit Start requests GPS and publishes location. Group membership alone must never call sender.start. Enrolled users use new device API; existing local creator/simulator path remains available for development, not the normal member flow. Starting/stopping recording remains independent of sharing.
7. Before session POST, durably store ID/tokens/options/backend as pending create. On successful response store actual expiry before accepting GPS uploads. Stop sets pending-stop in secure storage and cancels local GPS/timer first, then retries remote DELETE. Persist recovery through failures, app disposal and process restart. On restart never resume uploading: resolve a pending create with the identical request if required to recover its expiry, then stop; retry pending remote stops while foreground and connected, or expose Retry. Do not clear the recovery record until remote terminal state or verified expiry. Disable new starts/backend changes until recovery is resolved. Guard in-flight uploads/start/stop/dispose races and verify secure writes happen before network effects. Inform user if stop cannot yet reach server and show the expiry bound.
8. Add sender tests for persisted-before-request ordering, lost create response/exact retry, stop during creation, failed stop/restart recovery, expiry clearing, no automatic resume, removal/401/410 behavior and isolation from ride recording. Add widget tests for enrollment, group roster/meeting controls, permission roles, countdown and network state. Existing local-store/recorder/GPX tests must stay green.
9. Run `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze`, `flutter test`, and `flutter build apk --debug` in `mobile`. Format/fix and rerun affected checks if needed. Run backend suite/typecheck again after integration changes only. Update README with device setup, invitation/identity loss behavior, local profile vs server visibility, foreground limitations and recovery semantics. Commit after specification/code review and fixes.

## Acceptance and evidence

Baseline reported at handoff: 13 backend tests and 22 Flutter tests passing. Record actual new test totals and command outcomes; do not claim physical-device behavior from unit tests or APK compilation.

Exercise a local API integration scenario with three independent device credentials: owner bootstrap, two invitations/enrollments, three names and photos, two active group sessions and one viewer-only session; confirm group response includes only two locations, each private viewer sees only its own sender, and meeting point is shared only with group members. Verify avatar removal, invitation revocation, member removal, stop, expiry and cross-group denial. Verify old simulator flow remains functional. Use deterministic clocks/short fixtures for expiry tests rather than waiting an hour.

Use available browser/local simulator tooling for a real rendered viewer smoke check where possible; report if only automated DOM tests were possible. Flutter widget tests must exercise actual state changes, not only text existence.

Required manual follow-up before real-world reliance: three Android installations against an HTTPS deployment; join/name/photo/meeting and spouse browser flow; foreground GPS, app background/lockscreen, process kill, network loss/reconnect, secure-storage restore and stop retry. Physical-device lockscreen/network validation and public deployment are not available yet and must be explicitly listed as unverified, without blocking the authorized local implementation/build.

## Requested device delivery

After reviews, tests and APK build pass, install the debug APK on the connected Samsung SM-S901E (ADB serial `R5CW724F1TE`) using `adb -s R5CW724F1TE install -r`. Preserve existing app data; do not uninstall or clear data to work around signing conflicts. Launch and check for startup errors. Installation is explicitly authorized by the user. Public HTTPS deployment remains separate.
