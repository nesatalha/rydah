# Meeting-Point ETA Implementation Plan

> **Status:** Approved 2026-10-15. Branch `feature/meeting-eta` from `develop`.

**Goal:** The phone uploads its GPS speed with each location point. The server keeps it only on the session's current point and clears it on every end path. Both the private viewer and the group roster return it; the viewer shows "Speed 48 km/h". The Group tab shows each sharing member's distance and ETA to the meeting point, plus a one-line summary above the map.

**Approved decisions:**
- Speed source: uploaded GPS speed; no position-based fallback (old apps show distance only).
- Distance: straight line (displayed as true km). ETA = distance × 1.3 road factor ÷ speed.
- Arrived within 200 m. Stopped below 5 km/h. No ETA when stale or offline, or when the ETA is over 3 h.
- The viewer link also shows speed.
- Shown on the Group tab: roster rows, marker tooltips and a summary line.
- Arrived wins over offline: a last known position within 200 m shows "Arrived" even when stale.
- You are counted in the summary and get your own ETA when sharing to the group.
- Speed accuracy: speed is always used, but the phone also uploads `speedAccuracyMps`. When it is worse than ±5 m/s, the viewer shows "Speed 48 km/h (low accuracy)" and the ETA shows "~10 min (rough) • 8.0 km".
- The viewer keeps showing speed while the point is stale or offline, next to its Age.

**Architecture:**
- **Storage:** a nullable `speed_mps REAL` column on `sessions` (migration `0004`). Trail points get no speed.
- **Writes:** the existing conditional upload UPDATE also sets `speed_mps`. An upload without speed stores NULL, so an old app's point never keeps a stale speed.
- **Clearing:** the explicit end UPDATEs set `speed_mps=NULL`. A new trigger, `AFTER UPDATE OF ended … WHEN NEW.ended=1`, nulls it on every path that sets `ended=1`, including the un-editable `revoke_member_sessions` trigger in 0002. Reads already hide the location when ended, and cron deletes expired rows.
- **Reads:** `sharing()` adds `speedMps` to the location object, which covers both the viewer GET and the roster.
- **App:** a pure `mobile/lib/meeting_eta.dart` holds haversine, GPS speed sanitizing, median-of-3 smoothing, classification, formatting and the summary. `GroupController` keeps a small in-memory speed buffer per member. `GroupScreen` only renders strings.

---

## Data and API contract

### Migration `backend/migrations/0004_session_speed.sql`

One statement per line:

```sql
ALTER TABLE sessions ADD COLUMN speed_mps REAL CHECK(speed_mps IS NULL OR (speed_mps>=0 AND speed_mps<=100));
ALTER TABLE sessions ADD COLUMN speed_accuracy_mps REAL CHECK(speed_accuracy_mps IS NULL OR (speed_accuracy_mps>=0 AND speed_accuracy_mps<=100));
CREATE TRIGGER end_session_speed AFTER UPDATE OF ended ON sessions WHEN NEW.ended=1 AND (NEW.speed_mps IS NOT NULL OR NEW.speed_accuracy_mps IS NOT NULL) BEGIN UPDATE sessions SET speed_mps=NULL,speed_accuracy_mps=NULL WHERE id=NEW.id; END;
```

- **No recursion:** the inner UPDATE doesn't touch `ended`, so the trigger doesn't fire itself again.
- **Nested chain:** group revoke → memberships → `revoke_member_sessions` → `end_session_speed`. A test proves it.

### `PUT /api/sessions/:id/location`

- **Request:** `{seq, lat, lon, accuracyM, observedAt, speedMps?, speedAccuracyMps?}`. Both speed fields follow the same rules, and both are stored as NULL when absent.
- **`speedMps`:** optional. Absent or `null` stores NULL. Otherwise it must be a finite number with `0 <= speedMps <= 100` (m/s, 360 km/h), else 400.
- **Response:** unchanged.
- **Ordering:** speed is protected by the same seq/observedAt guard as the coordinates.
- **Compatibility:** an old app (no field) is accepted and stores NULL. An old Worker ignores the extra field.

### Read shapes

`GET /api/sessions/:id` `location` and `GET /api/group` `members[].sharing.location`:

```json
{ "lat": 41.0, "lon": 29.0, "accuracyM": 8, "speedMps": 13.4, "speedAccuracyMps": 1.2, "observedAt": 1760000000000, "receivedAt": 1760000000500 }
```

`speedMps` is always present while `location` is non-null, and may be `null`.

---

## Task 1: Backend and browser viewer

**Files:** `backend/migrations/0004_session_speed.sql` (new), `backend/src/core.ts`, `backend/src/sessions.ts`, `backend/public/view.html`, `backend/public/view.js`, `backend/test/speed.test.ts` (new), plus the migration lists in `backend/test/api.test.ts`, `groups.test.ts` and `trails.test.ts`, and `backend/test/view.test.ts`.

1. **Add `0004`** to the explicit migration lists.
2. **Write the failing Worker tests** in `speed.test.ts`:
   - `upload accepts optional speedMps and returns it on viewer and group reads`.
   - `upload without speedMps stores null and overwrites a previous speed`.
   - `invalid speedMps returns 400`: `-1`, `100.1`, `"12"`, `{}` and `true` are rejected; `0`, `100` and `null` are accepted.
   - `rejected out-of-order upload keeps the newer speed`.
   - `stop, removal, leave, group deletion and expired sweep clear stored speed`.
   - `racing upload and stop never leave a stored speed`.
   - `migration 0004 preserves existing session rows with null speed`.
   - In `api.test.ts`: `legacy creator session upload works with and without speedMps`.
3. **Run** `npm test` and confirm the new tests fail.
4. **Implement:** the migration; `Session.speed_mps`; `speedMps` in `sharing()`; a `validSpeed` helper; validation and the UPDATE binding; and explicit NULLs in the stop and expired-sweep UPDATEs.
5. **Write the failing browser tests:**
   - `speed shows rounded km/h when present` (13.4 m/s shows "Speed 48 km/h").
   - `speed hidden when speedMps is null or missing`.
   - `ended, expired, 410 and 401 hide and clear speed`.
6. **Implement** a `#speed` detail in `view.html` and its rendering in `view.js`.
7. **Validate:** `npm test && npm run typecheck`, then `git diff --check`.

## Task 2: Flutter

**Files:** `mobile/lib/meeting_eta.dart` (new), `mobile/lib/sharing_api.dart`, `mobile/lib/gps_source.dart`, `mobile/lib/group_controller.dart`, `mobile/lib/group_screen.dart`. Tests: `mobile/test/meeting_eta_test.dart` (new), `sender_test.dart`, `group_test.dart`, `group_widgets_test.dart`.

**`GeoPoint` and upload:**
- `GeoPoint` gains an optional named `speedMps`. Existing positional calls are unchanged.
- `upload` sends `speedMps` only when it is known.

**GPS speed:**
- The locked `geolocator_platform_interface` 4.4.0 reports `speed` as 0.0 when unavailable and exposes `hasSpeed` and `hasSpeedAccuracy` (verified).
- `gpsSpeed(hasSpeed, speed, hasSpeedAccuracy, speedAccuracy)` returns null unless `hasSpeed` is true, the value is finite and `0 <= speed <= 100`. Speed accuracy is sent only when `hasSpeedAccuracy` is true. A reading is poor when its accuracy is worse than 5 m/s.

**Math (`meeting_eta.dart`):**
- **Constants:** `roadFactor = 1.3`, `arrivedRadiusM = 200`, `stoppedBelowMps = 5/3.6`, `maxEta = 3 h`, smoothing over 3 samples with a 30 s maximum gap.
- **`classifyEta`**, checked in this order:
  1. Arrived (within 200 m).
  2. Offline (not live).
  3. Distance only (no speed).
  4. Stopped (below 5 km/h).
  5. Moving: ETA = distance × 1.3 ÷ speed, rounded to whole minutes with a minimum of 1. Over 3 h falls back to distance only.
- **Labels:**

  | Status | Label |
  | --- | --- |
  | Moving | "~10 min • 8.0 km" |
  | Arrived | "Arrived" |
  | Stopped | "Stopped • 8.0 km" |
  | Distance only | "8.0 km" |
  | Offline | "Offline • 8.0 km" |

- **Smoothing:** the median of the last 3 uploaded speeds, so a single traffic-light 0 doesn't flip a moving rider to Stopped.
  - A sample is added only when its `observedAt` is new.
  - The buffer resets on a null speed, a gap over 30 s, or a new session (`expiresAt` changes).
  - It is kept in memory only.
- **Summary** (null without a meeting point):
  - "No one is sharing a location" when no one is.
  - "A of N arrived • next: Ada ~6 min" otherwise, where N counts members with a visible location.
  - "Everyone arrived" when all have arrived.

**Controller and screen:**
- **Controller:** `GroupController` keeps a per-member speed buffer and exposes `memberEta(member)` and `etaSummary`. `live` means the member's state is `live` and our last refresh succeeded.
- **Summary line:** shown above the map when non-null.
- **Roster row:** the subtitle shows the ETA label when a meeting point exists.
- **Marker tooltip:** "Name • label".
- **Fit and recenter:** unchanged.

**Steps:**
1. **Write the failing tests:**
   - `haversine matches known distances`.
   - `gpsSpeed nulls unavailable, negative, NaN, >100 and poor accuracy`.
   - `classify …` (covering every rule, including the 1.3 factor and minute rounding).
   - `formatting …`.
   - `smoothing …`.
   - `summary …`.
   - `upload sends speedMps when known and omits it when null`.
   - `group refresh smooths member speed across polls and drops it when member stops sharing`.
   - `group map shows ETA summary, roster ETA labels and marker tooltips with a meeting point`.
   - `without meeting point rows and tooltips are unchanged`.
2. **Run** `flutter test` and confirm the new tests fail.
3. **Implement.**
4. **Validate:** `flutter analyze && flutter test` (full suite), the backend checks again, then `git diff --check`.

## Docs

- **`api.md`:** `speedMps` on upload and in both read shapes.
- **`privacy.md`:** speed is stored with the current point only, visible to the private link and current group members, cleared on stop, removal, leaving and group deletion, and deleted with expired rows.
- **`mobile.md`:** a Meeting ETA section.
- **`deployment.md`:** **apply `0004` before deploying the Worker.** The new upload UPDATE names `speed_mps`, so deploying first fails every upload. The old Worker runs fine on the migrated schema, so rollback is safe.
- **README:** the test summary.

## Risks

- **Old app uploads:** NULL is stored and the app shows distance only.
- **Deploy order:** migration first, documented with the reason.
- **Clearing on every end path:** explicit NULLs plus the `ended=1` trigger; each path is tested, plus a race test.
- **Geolocator "0.0 means unknown":** handled with `hasSpeed`.
- **Units:** m/s on the wire and in storage; km/h only for display.
- **`GeoPoint` changes:** an optional named parameter, so existing calls don't change.
- **ETA flicker:** median smoothing, and Arrived is decided by distance alone.

## Out of scope

Routing-based ETA, a position-derived speed fallback, speed on trail points, and ETA on the Ride tab or the viewer.
