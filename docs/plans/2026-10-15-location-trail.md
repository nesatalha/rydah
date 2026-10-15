# Location Trail ("Recent Path") Implementation Plan

> **Status:** Implemented on `feature/location-trail` (approved 2026-10-15: 10 s thinning; Fit group unchanged). Branch `feature/location-trail` from `develop`.

**Goal:** When starting a share, a rider can pick a trail setting: **Off (default) / 15 min / 30 min / Whole session**. The private browser viewer and the in-app Group map then draw the rider's recent path as a polyline that fades with age. The server keeps only points inside the chosen window and deletes them at exactly the moments it already clears the current point.

**Architecture:**
- **Storage:** a `trail` column on `sessions` and a new `session_points` table, keyed by `(session_id, seq)` and created `WITHOUT ROWID`.
- **Writes:** each accepted upload updates the current point (as today), inserts one trail point and prunes points outside the window. All three run in one D1 batch, which is a single transaction.
- **Deletion:** SQLite triggers delete trail points when a session ends or is deleted. Stop, member removal, leaving, group deletion (through the existing `revoke_member_sessions` trigger chain), the expired-session sweep and cron are all covered without handler changes.
- **Reads:** incremental by `seq`. The viewer sends `?since=<maxSeq>`. The roster sends one cursor per member, `trailSince=<deviceId>:<expiresAt>:<seq>`; if `expiresAt` doesn't match the current session, the server sends the whole window again (`reset`).
- **Thinning:** at most one trail point per 10 s (`TRAIL_MIN_INTERVAL_MS`).

**Tech stack:** unchanged. TS Worker, D1, Miniflare, `node:test`, vanilla JS with Leaflet 1.9.4, Flutter with flutter_map 8 and latlong2.

---

## Data and API contract

### Migration `backend/migrations/0003_session_trails.sql`

```sql
ALTER TABLE sessions ADD COLUMN trail TEXT NOT NULL DEFAULT 'off' CHECK(trail IN ('off','15m','30m','session'));
CREATE TABLE session_points (session_id TEXT NOT NULL, seq INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, observed_at INTEGER NOT NULL, PRIMARY KEY(session_id, seq)) WITHOUT ROWID;
CREATE INDEX session_points_time ON session_points(session_id, observed_at);
CREATE TRIGGER end_session_points AFTER UPDATE OF ended ON sessions WHEN NEW.ended=1 BEGIN DELETE FROM session_points WHERE session_id=NEW.id; END;
CREATE TRIGGER delete_session_points AFTER DELETE ON sessions BEGIN DELETE FROM session_points WHERE session_id=OLD.id; END;
```

- **No foreign key:** D1 enforces foreign keys, and one here could make the cron `DELETE FROM sessions` fail. The triggers do the cascade instead.
- **No accuracy column:** stored data stays minimal.
- **Existing rows** get `trail='off'`.
- **Test fixtures:** add `0003` to the migration lists in `backend/test/api.test.ts` and `backend/test/groups.test.ts`.
- **Production:** apply `0003` to the remote D1 before deploying the Worker (see `docs/deployment.md`).

### `POST /api/me/sessions`

- **Request:** `{id, readToken, writeToken, audience, durationMinutes, trail}`, where `trail` is one of `"off" | "15m" | "30m" | "session"`. It defaults to `"off"` when absent; any other value returns 400.
- **Exact retry:** `trail` is part of exact-retry matching, so a mismatch returns 409. A retry without `trail` means `"off"`, which matches older app versions and their pending records.
- **Response:** adds `trail`: `{id, readToken, writeToken, expiresAt, audience, trail}`.
- **Legacy route:** creator-key `POST /api/sessions` (simulator) is unchanged and uses the column default `off`.

### `PUT /api/sessions/:id/location`

The request and response (`{accepted}`) are unchanged. The single UPDATE becomes `env.DB.batch([...])`:

1. **Update:** the existing conditional UPDATE, unchanged. `accepted` comes from `results[0].meta.changes`.
2. **Insert:**
   ```sql
   INSERT OR IGNORE INTO session_points(session_id,seq,lat,lon,observed_at)
   SELECT id,seq,lat,lon,observed_at FROM sessions
   WHERE id=? AND seq=? AND received_at=? AND ended=0 AND trail<>'off'
   AND NOT EXISTS(SELECT 1 FROM session_points WHERE session_id=? AND observed_at>?-10000)
   ```
   `seq=? AND received_at=?` matches only when statement 1 just applied, and statement 1 already enforces expiry and active membership.
3. **Prune:**
   ```sql
   DELETE FROM session_points WHERE session_id=? AND observed_at < ? -
   (SELECT CASE trail WHEN '15m' THEN 900000 WHEN '30m' THEN 1800000 END FROM sessions WHERE id=?)
   ```
   For `session` and `off` the subquery is NULL, so nothing is deleted.

The existing 410 fallback logic is unchanged.

### `GET /api/sessions/:id[?since=<int>]` (read token)

- **`since`:** optional. It must match `^\d{1,15}$`, otherwise 400. Absent means 0.
- **Snapshot:** the existing query and a points query run in one batch. The points query repeats the visibility conditions (`ended=0 AND expires_at>now AND (audience='viewer' OR active group)`) and adds `p.seq>? AND (trail='session' OR p.observed_at >= now - window)`, ordered by `seq`, `LIMIT 2000`.
- **Response:** adds:
  ```json
  "trail": null | { "setting": "15m"|"30m"|"session", "windowStartsAt": 1760000000000|null, "reset": true|false,
                    "points": [[seq, lat, lon, observedAt], ...] }
  ```
  - `trail` is null when the setting is off or the session has ended.
  - `reset` is true when `since` is 0 or absent; the client then replaces its cache, and otherwise appends.
  - `windowStartsAt = now - window` (null for `session`). The client drops cached points older than it.

### `GET /api/group[?trailSince=<deviceId>:<expiresAt>:<seq>,...]` (device token)

- **Validation:** at most 32 cursors, each matching `^[A-Za-z0-9_-]{1,128}:\d{1,15}:\d{1,15}$`, otherwise 400.
- **Binding:** cursors are bound once as a JSON object `{deviceId: [expiresAt, seq]}` through `json_each`, which avoids D1's bound-parameter limit.
- **Snapshot:** the roster query and the points query run in one batch. The points query joins the caller's and each member's active membership, `audience='group'`, `ended=0`, unexpired, `trail<>'off'`, the window filter and `p.seq > cursor seq` (only when the cursor's `expiresAt` matches).
- **Response:** `members[i].sharing.trail` uses the viewer's shape. `reset` is true when there is no cursor or the cursor's `expiresAt` differs. Viewer-only shares never appear.
- **Shared code** in `core.ts`: `TRAIL_WINDOW_MS`, `TRAIL_MIN_INTERVAL_MS`, a cursor parser, the SQL window fragment and `trailOutput(...)`.

### Scheduled cleanup

The first statement sweeps orphans:

```sql
DELETE FROM session_points WHERE session_id NOT IN (SELECT id FROM sessions WHERE ended=0 AND expires_at>?)
```

The existing deletes then also fire the delete trigger.

### Thinning

At a 5 s cadence, 4 h comes to about 2,880 points. The 10 s floor caps a session at about 1,441 points (a first load of about 65 KB of tuples) and halves the extra row writes. At riding speeds that leaves 140–250 m between points, which is enough for an overview. The current marker always connects to the newest trail point. Distance-based thinning would need extra reads or trigonometry in SQL, so it's skipped.

---

## Task 1: Backend and browser viewer

**Files:** `backend/migrations/0003_session_trails.sql` (new), `backend/src/core.ts`, `backend/src/sessions.ts`, `backend/src/groups.ts`, `backend/src/index.ts`, `backend/public/view.js`, `backend/public/view.html`, `backend/public/styles.css`, `backend/test/api.test.ts`, `backend/test/groups.test.ts`, `backend/test/view.test.ts`. Docs: `docs/api.md`, `docs/privacy.md`, `docs/deployment.md`, `README.md`.

1. **Write the failing Worker tests:**
   - `session trail option validates, defaults off and is part of exact retry`: invalid values return 400; an absent `trail` echoes `off`; a differing `trail` returns 409; an exact retry keeps `expiresAt`.
   - `trail off stores no history rows`.
   - `trail thins to one point per 10 s and prunes outside the window`. Reads must also hide out-of-window points before any prune runs.
   - `viewer since returns only newer points and reset semantics` (and `since=abc` returns 400).
   - `stop, removal, leave and group deletion delete trail points immediately`. This covers the nested trigger chain.
   - `racing upload and stop never leave trail points`.
   - `scheduled cleanup removes expired session points`.
   - `group roster returns incremental trails per member with expiresAt cursor`: covers reset on a stale `expiresAt`, viewer-only shares never appearing, and more than 32 or malformed cursors returning 400.
   - `legacy creator sessions have trail off and stay unchanged` (in `api.test.ts`).
   - `migration 0003 preserves existing session rows`.
2. **Run** `cd backend && npm test` and confirm the new tests fail.
3. **Implement** the migration, the `core.ts` helpers, the create/retry changes, the upload batch and GET batch (`sessions.ts`), the roster batch (`groups.ts`), the cleanup sweep (`index.ts`), and the `Session.trail` type.
4. **Write the failing browser tests** in `view.test.ts`. Extend the Leaflet mock with `L.polyline` and `L.layerGroup` first.
   - `first poll fetches full trail, later polls send since=<maxSeq>`.
   - `trail renders age-faded segments ending at the current marker`.
   - `gap over 60 s splits the polyline`.
   - `reset replaces cache; windowStartsAt drops old points`.
   - `trail updates never call setView or change zoom after user pan`. Recenter must be unchanged.
   - `ended, expired, 410 and 401 clear the trail cache and layers`.
   - `trail null hides the trail label`.
5. **Implement `view.js`:**
   - **State:** a trail cache plus `maxSeq`.
   - **Polling:** `?since=` on later polls; replace the cache on `reset`, otherwise append, then filter by `windowStartsAt`.
   - **Rendering:** one `trailLayer` layer group with at most about 5 bucketed polylines, rebuilt only when the data changes or on the 5 s tick. Never call `fitBounds`. Tear the layer down wherever `map.remove()` runs.
   - **Page:** a `#trail` label in `view.html`.
6. **Validate:** `cd backend && npm test && npm run typecheck`, then `git diff --check`.

**Docs:**
- **`privacy.md`:** the trail is opt-in per share and off by default. With it on, the server keeps points thinned to one per 10 s, only within the chosen window. They're visible only to the private link and, for group shares, current members. Stop, removal, leaving and group deletion delete them immediately; after expiry they're unreadable and removed by the hourly cleanup.
- **`api.md`:** the new fields, retry semantics, `since`, `trailSince` and response shapes.
- **`deployment.md`:** list migration `0003`.

## Task 2: Flutter

**Files:**
- `mobile/lib/trail.dart` (new): pure `TrailPoint`, `MemberTrail`, `mergeTrail()` and `fadeSegments()`.
- `mobile/lib/app_shell.dart`: a Trail selector in the share dialog.
- `mobile/lib/location_sender.dart`: `trail` in the pending record and the create request; send it only if present, so older pending records recover unchanged.
- `mobile/lib/group_api.dart`: the `trailSince` query.
- `mobile/lib/group_controller.dart`: a trails map, cursors, merge, prune and clear.
- `mobile/lib/group_screen.dart`: a `PolylineLayer` before the markers.
- Tests: `mobile/test/trail_test.dart` (new), `group_test.dart`, `group_widgets_test.dart`, `durable_sender_test.dart`, `app_shell_test.dart`.
- Docs: `docs/mobile.md`.

1. **Write the failing tests:**
   - `mergeTrail appends only newer seq, replaces on reset or expiresAt change, drops points before windowStartsAt`.
   - `fadeSegments buckets by age, splits gaps over 60 s, last segment ends at the current fix`.
   - `pending record persists trail and createSession sends it`.
   - `legacy pending without trail recovers without sending trail`.
   - `share dialog offers Trail Off/15 min/30 min/Whole session, default Off`. Choosing Whole session must post `trail: 'session'`.
   - `group refresh sends trailSince cursors and merges incremental trails`.
   - `member who stops sharing or loses membership drops trail`.
   - `group map draws member trail polylines; Fit group still fits current fixes and meeting point only`.
2. **Run** `cd mobile && flutter test` and confirm the new tests fail.
3. **Implement:**
   - **Dialog:** a "Trail" dropdown with Off / Last 15 minutes / Last 30 minutes / Whole session (default Off). The dialog text says the trail is visible to the chosen audience while sharing.
   - **Map:** a per-member polyline with stepped alpha.
   - **Fit and recenter:** unchanged.
   - **Offline:** last trails stay visible while offline, like the last-known markers.
4. **Validate:** `cd mobile && flutter analyze && flutter test` (full suite), backend checks again, then `git diff --check`.

## Risks

- **Stop/removal racing an upload:** D1 runs writes one at a time, so the batches are ordered. If the upload commits first, the end trigger deletes its points. If the stop commits first, the UPDATE fails on `ended=0` and the INSERT doesn't match. A test covers this.
- **Prune vs insert:** both are in the same batch, so there is no lost update.
- **Duplicate or out-of-order uploads:** the INSERT follows only an accepted UPDATE, which already enforces seq and observedAt ordering, and `INSERT OR IGNORE` absorbs exact repeats. The `since` cursor by seq is therefore safe.
- **Nested triggers:** SQLite allows triggers to fire other triggers (only same-trigger recursion is off). The chain is 3 deep, and the group-deletion test proves it on Miniflare.
- **Expiry:** points become unreadable immediately because every read checks `expires_at`. They're deleted on the next create for that device or by the hourly cleanup, the same as today's current point.
- **Payload size:**
  - Viewer: a first load of at most about 65 KB, then 0–1 points per poll.
  - Roster: N × that on first load, then tiny.
  - Request bodies don't grow.
- **A new session in the roster:** an `expiresAt` mismatch forces `reset`.
- **Clock skew:** pruning uses server time against observedAt (already limited to −120 s / +30 s). The client prunes only by the server's `windowStartsAt`.
- **Map views:** the trail code never calls setView or fit.

## Out of scope

Changing the trail setting mid-share, showing the rider's own trail on the Ride tab, and distance-based thinning.
