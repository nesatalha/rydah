# Rydah

A runnable Android motorcycle app with local ride recording, route drafts and GPX import, plus private live-location sharing through a browser link and invitation-only riding groups. Ride history and routes stay in SQLite on the phone. The Android sender uses device GPS; the optional browser simulator is explicitly labeled and sends generated points through the same API.

- **`mobile/`** — Flutter Android app: Ride, History, Routes, Group and Settings tabs.
- **`backend/`** — Cloudflare Worker + D1: sharing sessions, devices, profiles, private groups, and the browser viewer, invitation and simulator pages in `backend/public/`.
- **`docs/`** — [API and groups](docs/api.md), [using the app](docs/mobile.md), [privacy and storage](docs/privacy.md), [deployment](docs/deployment.md), and implementation plans in [`docs/plans/`](docs/plans/).

The backend is deployed as a Cloudflare Worker; see [docs/deployment.md](docs/deployment.md). The steps below run everything locally.

## Requirements

- Node 22.12+ (Node 24 recommended) and npm
- Flutter 3.38+ with an Android emulator or a USB-connected phone

Commands use plain `flutter`. If you manage Flutter with [FVM](https://fvm.app/), use `fvm flutter` instead.

## Run the local backend

```bash
cd backend
npm ci
cp .dev.vars.example .dev.vars
npx wrangler d1 migrations apply rydah --local
npm run dev -- --ip 0.0.0.0
```

Backend and viewer: http://localhost:8787. Leave this terminal running. Binding to `0.0.0.0` makes the listener reachable on your LAN; use a private, trusted network.

The creator key in `.dev.vars.example` is **rydah-local-demo-only**, a development-only value; the Worker has no public fallback key and `.dev.vars` is git-ignored. The creator key bootstraps groups and the legacy simulator. To create your first group, see [Bootstrap a private group](docs/api.md#bootstrap-a-private-group).

## Run the Android app

```bash
cd mobile
flutter pub get
flutter run -d emulator-5554
```

On **Ride**, tap **Start ride** to record locally, and **Start sharing** to choose an audience (**Private link** or **Group + private link**) a duration (30 minutes, 1, 2 or 4 hours; default 1 hour) and an optional trail of your recent path (off by default). Sharing needs only a saved name in **Settings**. In **Routes**, add stops on the map or import a GPX file; draft routes draw straight lines and do not provide turn-by-turn navigation. History, routes and recorded GPS points work without the backend.

The emulator reaches the local backend at `http://10.0.2.2:8787` (the app's default). Use **Copy private link** on the Ride tab and open it in a desktop browser. For a physical phone, profiles, groups and recovery behavior, see [docs/mobile.md](docs/mobile.md).

Keep the sender app open while sharing: there is no background-location permission, and battery controls, backgrounding or connectivity can interrupt updates.

## Optional two-tab simulation

Open http://localhost:8787/simulate.html, enter the local creator key and start. Open its private viewer link in another tab. The viewer prominently says **SIMULATION — NOT PHONE GPS**. Watch the marker and coordinates change, then stop the simulator: the viewer changes to ended and removes coordinates. Closing the simulator without stopping leaves the last point to age from live → stale → offline; its session expires after one hour.

The viewer polls every five seconds and ages the displayed point between polls. The map centers on the first position, then updates its marker without changing your pan or zoom; **Recenter** returns to the latest position at the initial zoom. Live means captured within 20 seconds, stale 20–60 seconds, and offline over 60 seconds. Offline is inferred from silence and is not a confirmed phone connection state. Connection failures show a separate retry message. The map requires internet; coordinate readings remain usable if the external map cannot load.

## Verification

```bash
cd backend
npm test
npm run typecheck
cd ../mobile
flutter analyze
flutter test --reporter expanded
flutter build apk --debug
```

GitHub Actions runs the backend tests and typecheck plus `flutter analyze` and `flutter test` on pull requests to `develop` and `main`.

Backend tests use Miniflare D1 with all migrations. They cover speed validation and clearing, trail validation, thinning, pruning, incremental reads and deletion on stop, removal and cleanup, group and invitation authorization, one-use enrollment and exact retries, profile/photo access, meeting points, audience isolation, membership/session revocation races, requested durations, idempotent creation, location ordering and freshness. Browser tests cover speed display, incremental trail polling and age-faded rendering, private photo authorization, safe sender names, blob cleanup and retry, legacy fallback, pan/zoom preservation, and invitation fragment handling. Flutter tests cover meeting ETA math, smoothing and display, speed upload, the trail option, trail merging and group trail drawing, stop during creation, one upload in flight, failed-stop retry, permission errors, expiry without GPS or during an upload, and terminal HTTP 410 recovery. Network errors and nonterminal server errors retain the stop credential for retry.

## Contributing

Branching, agent roles and required checks are in [AGENTS.md](AGENTS.md): branch from `develop`, open pull requests to `develop`, and release through a validated `develop` → `main` pull request.
