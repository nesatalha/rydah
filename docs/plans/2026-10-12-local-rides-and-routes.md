# Local Rides and Routes Implementation Plan

> **Status:** Implemented in the initial commit (f8fafb1).

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver an integrated Android app that records and revisits motorcycle rides locally, creates reusable routes, and retains the existing private location-sharing flow.

**Architecture:** SQLite owns rides, recorded points, route stops and route geometry. A foreground recorder consumes GPS independently of the sharing sender; failure or expiry of sharing never ends recording. Four persistent tabs—Ride, History, Routes, Settings—share app-lifetime controllers rather than recreating services when switching tabs.

**Tech Stack:** Existing Flutter 3.38/Dart 3.10, geolocator and http; sqflite, flutter_map and latlong2; XML parsing and Android file pick/share packages as needed. Resolve compatible package versions with the installed SDK and retain the lockfile.

---

## Scope and decisions

User has authorized ordinary design decisions and autonomous local implementation. No deployment, paid service, account creation, physical-phone test or separate reviewer round. Finish active work before **07:50 Europe/Istanbul, 12 October 2026 (04:50 UTC)**; reserve final minutes for verification and an honest handoff. Never extend into the user's 08:00 credit cutoff.

Choose SQLite plus direct service/controller classes: JSON files simplify initial storage but make incremental recording/recovery fragile; cloud-first storage introduces unnecessary connectivity and identity requirements. Avoid a new state-management framework.

Recording, saved lists and route editing work without the backend. Online map tiles remain optional presentation: show coordinates, metrics and saved geometry when tiles fail. No downloaded maps, navigation, automatic rerouting, motorcycle-specific safety claims or guaranteed background recording. Keep the app open. Default history is empty, with helpful actions; sample tracks may appear only through an explicitly named import/demo action and are never GPS recordings.

## P0 — complete the recording journey first

### 1. Persist domain state

Create `mobile/lib/local_store.dart`, `ride_models.dart`, `route_models.dart`; update `mobile/pubspec.yaml`. Create `mobile/test/local_store_test.dart` using SQLite's test backend where feasible.

Tables: rides (`id`, name, started/ended UTC milliseconds, status), ride_points (`ride_id`, sequence, segment, latitude, longitude, accuracy, observed UTC milliseconds), routes (`id`, name, created/updated time, geometry kind), route_stops (`route_id`, ordinal, coordinates), route_geometry (`route_id`, ordinal, coordinates). Use foreign keys, cascade deletion, explicit ordering and a versioned schema. Parameterize SQL. Atomically append each point and checkpoint metadata; serialize writes. Do not report saved data before commit succeeds.

Test create/reopen/read, point ordering, rename, cascade delete and partial-write rollback. At startup offer to finish an interrupted ride, preserving points; never silently resume GPS or count app downtime as riding. Repository methods form the injection boundary for widget tests.

### 2. Record independently

Create `mobile/lib/ride_recorder.dart`, `gps_source.dart`, `ride_metrics.dart` and `mobile/test/ride_recorder_test.dart`. Inject GPS, clock and storage. Start only after permission/location checks; display “Waiting for GPS” until a valid fix. Stop drains queued writes before saving. Storage errors stop recording visibly and preserve already committed points.

Reject nonfinite/out-of-range coordinates, negative accuracy and nonincreasing observation times. Deduplicate identical samples; sum haversine distances between consecutive accepted points. Mark a new segment after a long location gap rather than joining it with an invented straight journey. Label distance as GPS estimate. Show elapsed session time separately from distance; omit inferred moving time and average speed in this increment. Test known distances, permission denial, GPS loss, write failure, rapid start/stop and stop during pending writes. Sharing requests and their exceptions must never sit on the recorder's critical path.

### 3. Integrate Ride and History

Modify `mobile/lib/main.dart`; create `app_shell.dart`, `ride_screen.dart`, `history_screen.dart`, `ride_detail_screen.dart`, `settings_screen.dart`, `track_map.dart`. Retain the sharing UI/controller and existing sender tests. Move connection inputs into Settings; retain in-memory secrets. Keep recording and sharing controls visibly independent; ending either must explain the other's remaining status. Avoid disposing either when changing tabs.

Ride: Start ride, live elapsed time/distance/fix status, map and Finish ride. History: newest-first cards with name/date/duration/distance. Detail: fitted track, metrics, rename, delete confirmation and GPX export. Zero-point rides say “No GPS points”; no marker at an invented location. Settings also exposes location permissions and the local-only/background limitations.

## P1 — local route and file journeys

### 4. Create, edit and import routes

Create `mobile/lib/routes_screen.dart`, `route_editor_screen.dart`, `gpx_service.dart`; add `mobile/test/gpx_service_test.dart`. Tap the map to add numbered stops, reorder/delete them in a list, name and save. Preserve edits on ordinary tab changes. Require two stops for a usable route. Saved route detail fits geometry and allows editing/deletion.

Connect stops with a clearly labeled **“Draft — straight lines, not road directions”** preview. Show straight-line distance accordingly. Import GPX track/route points through Android's picker into a route, labeled “Imported GPX”; preserve segment breaks. Reject malformed/oversized files and invalid coordinates with useful messages. Export recorded rides as GPX tracks with timestamps, segments and escaped names using Android's share/save flow. Export must yield a usable `.gpx` file, not merely print XML. Test XML escaping, namespaces, invalid inputs and round-trip coordinates/timestamps.

### 5. Optional road routing, only after core verification

Create `mobile/lib/route_api.dart` and tests if time permits. Settings accepts the user's personal OpenRouteService key and an HTTPS endpoint; no invented key or paid signup. Keep key in memory initially. Explain that requesting a route sends stops to that provider. Use its documented driving profile, labeled “Driving route”; never claim motorcycle restrictions are modeled. Store returned geometry locally. Missing key, network/quota error or cancellation leaves the saved draft intact. Editing/reordering stops invalidates prior road geometry. Verify current official API documentation before implementation. Without a key, this feature remains an honest configurable integration, not a verified live service.

## Verification and handoff

For each service, run a focused failing behavior test, implement minimally, then rerun it. From `mobile/`, use `/Users/kurtulusn/fvm/default/bin/flutter test --reporter expanded`, `flutter analyze`, and `flutter build apk --debug` (same absolute Flutter path). Expect passing tests, clean analysis and a built APK.

On the available Android emulator: record injected emulator positions, switch tabs, stop, reopen app, inspect/rename/export/delete; create/reorder/save/reopen a draft; import exported GPX. Run recording with the backend unavailable and confirm persistence. Confirm sharing still creates/copies/stops a link. Identify emulator positions as test GPS. No phone-specific test is required.

Update root `README.md` with actual implemented journeys and limitations. If time runs short, finish P0 and existing sharing verification, then report unfinished P1/optional routing explicitly. Leave no nonfunctional primary buttons or claims that deferred features work.
