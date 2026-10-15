# Configurable location-sharing duration — design

> **Status:** Superseded. Merged in PR #2, then replaced in e35c5cc by the deployed device-owned sessions with 30/60/120/240-minute durations.

## Goal

Let a rider choose how long a private live-location link remains active when
they start sharing. The selected duration must be enforced by the backend,
not merely displayed by the Android app.

## User experience

Tapping **Start sharing** opens a duration picker before GPS preparation or
session creation. It offers 15 minutes, 30 minutes, 1 hour, 2 hours, and a
custom duration in whole minutes. Custom durations must be from 1 through 720
minutes. Cancelling the picker must leave sharing inactive.

After the user confirms, the existing sharing flow continues. The Ride screen
shows the returned expiry time, and **Stop sharing** retains its current
behavior of clearing the stored location immediately.

## Data flow and enforcement

The selected duration is passed from the Ride UI through `LocationSender` and
`SharingApi` as `durationMinutes` in the session-creation request. The Worker
validates that value is a safe integer within 1–720 and calculates
`expiresAt` from the server clock. It must reject invalid or missing durations
with a 400 response.

The existing expiry checks on reads, uploads, stops, and scheduled cleanup
continue to use the server-calculated `expires_at`, so keeping the Android app
open cannot extend a share beyond the selected period.

## Error handling

The picker validates custom input locally and explains invalid input without
creating a session. Backend validation remains authoritative. Existing network,
permission, GPS, expiry, and stop-retry behavior remains unchanged.

## Testing

Add Worker API tests for accepted selected durations and rejected invalid or
missing values. Add Flutter tests verifying the creation request carries the
selected duration and that the sender starts with the chosen duration. Cover
picker cancellation and custom-input validation with widget tests where the
current UI test structure supports them.
