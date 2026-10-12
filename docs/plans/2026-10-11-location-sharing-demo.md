# Location Sharing Demo Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Demonstrate an Android phone sharing its latest position with a private browser viewer, with a clearly labeled simulator for immediate local testing.

**Architecture:** One Cloudflare Worker serves a static viewer/simulator and a JSON API backed by D1. Flutter is the foreground sender; the browser polls for the latest position. Run everything locally first; public deployment requires the user's Cloudflare account later.

**Tech Stack:** Flutter 3.38.10/Dart 3.10.9, `geolocator`, `http`, TypeScript Worker, Wrangler, D1/SQLite, plain HTML/CSS/JavaScript. Node 20.16 is installed; choose compatible Wrangler or an available newer bundled Node.

---

## Decisions and boundaries

- No account system, route history, routing, offline maps, navigation, background tracking, or deployment in this demo. Keep the sender open; explain that backgrounding may pause updates.
- Sender screen: backend URL, creator key, permission/status, Start sharing, copy private link, Stop sharing, coordinates/accuracy/last successful upload. Denied permission and disabled location services get actionable messages.
- Viewer: waiting/live/stale/offline/ended/expired states; map marker, accuracy and capture time; updates every five seconds. Never label an old point live. Live means captured within 20 seconds, stale 20–60 seconds, offline over 60 seconds; offline is an inference from silence, not confirmed phone connectivity.
- Use a minimal geographic map with OpenStreetMap attribution. Explain that map tiles disclose the viewed map area to the tile provider; private API credentials must never reach that provider. If dependencies/network prevent mapping, coordinates and a clearly labeled external map link remain functional.
- Simulator is an explicit `/simulate.html` page, labeled “SIMULATION — not phone GPS,” and uses the same API and a moving sample position. Persist `source: simulation | device` on sessions; viewer prominently displays it.

## API contract

All times are UTC epoch milliseconds. Responses use JSON; errors are `{error: string}`. API responses set `Cache-Control: no-store`; static pages set `Referrer-Policy: no-referrer`. Same-origin browser calls need no permissive CORS.

`POST /api/sessions`, `Authorization: Bearer <CREATOR_KEY>`, body `{source:"device"|"simulation"}`. Return **201** `{id,writeToken,readToken,expiresAt}`. Generate an unguessable ID and separate random 256-bit write/read secrets; store only SHA-256 secret hashes. `CREATOR_KEY` comes from Worker environment; the sender/simulator accepts it in memory. Local development uses a documented development-only value, never a public production default.

`PUT /api/sessions/:id/location`, writer bearer token, body `{seq,lat,lon,accuracyM,observedAt}`. `seq` is a positive safe integer increasing within one session. Validate finite latitude −90…90, longitude −180…180, nonnegative accuracy ≤100000, and observation age ≤120 seconds with future tolerance ≤30 seconds. Return **200** `{accepted:true|false}`. One atomic SQL update checks active/unexpired session, increasing sequence and nondecreasing observation time; delayed or repeated uploads cannot overwrite newer positions. Use **400** for invalid inputs and **410** for ended/expired sessions.

`GET /api/sessions/:id`, reader bearer token only. Return **200** `{state,source,expiresAt,location:null|{lat,lon,accuracyM,observedAt,receivedAt}}`, where `state` is waiting/live/stale/offline/ended. Compute freshness on the server from observation time; the viewer also ages displayed data between polls and shows connection failures. Ended has `location:null`. Expired returns **410** without coordinates. Invalid/missing credentials return **401** without session details. Neither secret grants the other's capability.

`DELETE /api/sessions/:id`, writer bearer token, stops sharing, immediately clears coordinates, and returns **204**; repeat authenticated stops are idempotent. Client shows stopping until confirmed; failure offers retry and must not claim remote sharing ended.

Viewer links are `/view.html#id=…&token=…`; parse credentials into memory and remove the fragment using `history.replaceState`. Never put tokens into query strings, analytics or logs. One-hour session/read expiry is fixed; new sharing creates a new session. All reads/writes enforce expiry. Hourly scheduled cleanup physically deletes expired rows (maximum retention under two hours); local README documents manual cleanup because local cron is not automatic.

## Implementation tasks

### 1. Backend and its contract tests

Create `backend/package.json`, `backend/wrangler.jsonc`, `backend/tsconfig.json`, `backend/.dev.vars.example`, `backend/migrations/0001_sessions.sql`, `backend/src/index.ts`, `backend/test/api.test.ts`, `.gitignore`.

Write meaningful failing tests for auth separation, start/upload/read/stop, expiry, old/duplicate uploads, concurrent stop/upload, validation, and freshness. Implement the minimal Worker/D1 schema and scheduled deletion. Keep one current location per session. Configure static assets and local D1.

Verify: `cd backend && npm install && npx wrangler d1 migrations apply rydah --local && npm test && npm run typecheck`. Expect all contract cases passing. Choose a Worker-compatible test harness that exercises the actual SQL.

### 2. Browser viewer and simulator

Create `backend/public/index.html`, `view.html`, `simulate.html`, `styles.css`, `view.js`, `simulate.js`. Share small helpers only when useful. Start simulator, open its link in another tab, see movement, stop it, and confirm coordinates disappear. Disconnect API and verify the last point becomes stale/offline instead of remaining live.

### 3. Flutter Android sender

Create `mobile/` using Flutter scaffolding. Implement `mobile/lib/main.dart`, `lib/sharing_api.dart`, `lib/location_sender.dart`; update `mobile/pubspec.yaml`, Android location/Internet permissions and debug-only cleartext networking. Enable geolocator foreground notification support with required Android permissions; do not promise uninterrupted background tracking. Use a five-second upload cadence, one upload in flight, and monotonic sequence numbers. Cancel polling/location subscription on stop/dispose; prevent overlapping starts. Do not persist bearer secrets in this demo.

Verify: `/Users/kurtulusn/fvm/default/bin/flutter analyze` and focused `flutter test` for sender stop/race/error state handling. Build debug APK and run on available `emulator-5554` (Android 16/API 36). Emulator backend URL is `http://10.0.2.2:8787`; USB phone can use `adb reverse tcp:8787 tcp:8787` and localhost. Physical-device testing is not required.

### 4. Local launch and handoff

Create root `README.md` with exact setup/run commands, local creator key handling, two-tab simulation walkthrough, phone instructions, retention/privacy limitations, and deferred Cloudflare deployment steps. Run Worker on port 8787, perform HTTP smoke tests against real local D1, and exercise viewer/simulator in available Chrome. Report verified browser/emulator behavior. Leave runnable local demo; no Git initialization/commit and no reviewer round before the user's demo.
