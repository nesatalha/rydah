# Using the Android app

Start the backend and app as described in the [README](../README.md). Commands use plain `flutter`; use `fvm flutter` if you manage Flutter with FVM.

## Emulator

The emulator's backend URL is `http://10.0.2.2:8787`. Allow Android location access, then use **Copy private link** on the Ride tab and open it in a desktop browser. Emulator viewer links use `localhost` so they open on the development computer. For a remote viewer, use a backend URL reachable from that viewer (for example the computer's LAN address, or the deployed HTTPS backend) before creating the session.

In emulator Extended Controls → Location, choose a position or route if GPS is not updating. Emulator locations are test positions; the same app obtains real device GPS on a physical phone.

To build and install the APK:

```bash
cd mobile
flutter build apk --debug
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 shell am start -n app.rydah.mobile/.MainActivity
```

## USB-connected phone

```bash
adb reverse tcp:8787 tcp:8787
```

Install the debug APK, open **Settings**, and set the backend URL to `http://localhost:8787`. That URL is forwarded from the phone to the development computer. A viewer on the same computer uses localhost; a different person's browser needs a shared reachable backend. Alternatively, use the computer's LAN IP from a phone on the same Wi-Fi network, or point the app at the deployed backend (see [deployment.md](deployment.md#point-the-app-at-the-deployed-backend)).

## Trail

The start-sharing dialog has a **Trail** option: **Off** (default), **Last 15 minutes**, **Last 30 minutes** or **Whole session**. With a trail, the private-link viewer and, for group shares, the Group tab draw your recent path as a line that fades with age. **Fit group / recenter** still fits only current positions and the meeting point.

## Meeting ETA

When the group has a meeting point, the Group tab shows each sharing member's distance and ETA, in the roster and the marker tooltip, plus a summary such as **1 of 3 arrived • next: Ada ~6 min**. The phone uploads its GPS speed with each point; the private-link viewer shows it as **Speed 48 km/h**.

- Distance is a straight line; ETA = distance × 1.3 (to approximate roads) ÷ speed, e.g. **~12 min • 8.0 km**.
- Within 200 m of the meeting point is **Arrived**, even if the member's updates have gone quiet.
- Below 5 km/h is **Stopped**; a stale or offline position shows **Offline • 8.0 km**; no speed (older app) or an ETA over 3 hours shows distance only.
- Speed is the median of the member's last three uploaded readings, so one stop at a light doesn't flip to Stopped. Speed accuracy worse than ±5 m/s is still used, marked **(rough)** in the app and **(low accuracy)** on the viewer.

## Foreground limits

Keep the sender app open. A foreground location notification is enabled where Android permits it, but background tracking is not guaranteed. Battery controls, permissions, backgrounding and connectivity can interrupt updates. There is no background-location permission. **Stop sharing** shows confirmation only after the server clears the stored point; on failure it retains the stop credential and offers retry.

## Profile

In **Settings**, choose a display name and optional photo and tap **Save local profile**. The photo is cropped to 128×128 PNG on the phone and stored with the name in local SQLite. The first time you start sharing, the app registers the device with the backend (no group or invitation needed) and uploads the name and photo, so your private-link viewer sees your photo as the map marker. Group members see it too once you join. Without a photo, markers show your initials. Profile editing never requests GPS.

## Groups

The owner opens **Developer: create a group**, enters a group name and the creator key (held in memory only, never prefilled), and taps **Create group and enroll**. In **Group**, the owner taps **Create and copy invitation** and sends the link to a friend, who pastes it into **Join group** in Settings. Joining never starts location sharing.

The Group tab shows every member, photo markers for members sharing with the group, the meeting point (tap the map, add a label, **Save meeting point**) and **Fit group / recenter**. It refreshes about every five seconds only while open and in the foreground; when refresh fails, last-known positions are labeled offline and disappear when their share expires.

## Identity and recovery

Device credentials and in-progress share records live in Android secure storage, scoped to the backend URL, and are excluded from Android backup. Reinstalling or clearing the app loses that identity: the owner removes the old device and sends a new invitation. After leaving a group, being removed, or deleting the group, the next **Join group** uses a fresh device identity.

If the app is killed while sharing, it does not resume uploads on restart; it stops the unfinished share and offers **Retry safe stop** if the server cannot be reached. The backend URL and new joins are locked until that stop completes.
