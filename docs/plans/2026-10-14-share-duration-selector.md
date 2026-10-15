# Configurable Share Duration Implementation Plan

> **Status:** Superseded. Merged in PR #2, then replaced in e35c5cc by the deployed device-owned sessions with 30/60/120/240-minute durations.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let the rider select a private location-sharing duration and enforce that duration on the server.

**Architecture:** A Material dialog selects a preset or validated custom number of minutes before any GPS or HTTP work begins. The Android client sends that integer as `durationMinutes` when creating a session; the Worker validates it and derives `expiresAt` from its own clock. Existing storage and expiry checks continue to operate from the stored timestamp, so no migration is required.

**Tech Stack:** Flutter/Dart, `flutter_test`, HTTP mock client, TypeScript Cloudflare Worker, D1, Node test runner, Miniflare.

---

### Task 1: Enforce a selected duration in the Worker

**Files:**
- Modify: `backend/src/index.ts:13-20`
- Test: `backend/test/api.test.ts:8-18`

**Step 1: Write the failing Worker tests**

Extend the `create` helper so it accepts `durationMinutes`, then add tests that:

```ts
test('creates a session for the requested duration', async () => {
  const before = Date.now();
  const session = await create(30);
  const after = Date.now();
  assert.ok(session.expiresAt >= before + 30 * 60_000);
  assert.ok(session.expiresAt <= after + 30 * 60_000);
});

test('rejects a missing or invalid share duration', async () => {
  for (const durationMinutes of [undefined, null, '30', 1.5, 0, -1, 721]) {
    const response = await call('/api/sessions', 'POST', 'test-key', {
      source: 'simulation',
      ...(durationMinutes === undefined ? {} : {durationMinutes}),
    });
    assert.equal(response.status, 400);
  }
});
```

Update all existing successful session creation calls to provide `durationMinutes: 60`.

**Step 2: Run the Worker test to verify it fails**

Run: `npm test -- --test-name-pattern "requested duration|invalid share duration"`

Expected: FAIL because the current API accepts missing values and returns an hour-long session.

**Step 3: Implement the minimum validation and expiry calculation**

In `backend/src/index.ts`, validate the input after `source` validation and before secrets are created:

```ts
const durationMinutes = body.durationMinutes;
if (!Number.isSafeInteger(durationMinutes) || durationMinutes < 1 || durationMinutes > 720) {
  return error('Invalid sharing duration', 400);
}
const expiresAt = now + durationMinutes * 60_000;
```

Use `expiresAt` in the existing insert and response. Do not add a database column or alter existing read/write/cleanup logic.

**Step 4: Run the focused Worker tests to verify they pass**

Run: `npm test -- --test-name-pattern "requested duration|invalid share duration"`

Expected: PASS.

**Step 5: Commit**

```bash
git add backend/src/index.ts backend/test/api.test.ts
git commit -m "feat: enforce selected share duration"
```

### Task 2: Send the duration through the mobile sharing API

**Files:**
- Modify: `mobile/lib/sharing_api.dart:54-67`
- Modify: `mobile/lib/location_sender.dart:31-55`
- Test: `mobile/test/sender_test.dart:8-39`
- Create: `mobile/test/sharing_api_test.dart`

**Step 1: Write failing client tests**

Add an HTTP mock test asserting that `SharingApi.create(durationMinutes: 30)` sends exactly:

```json
{"source":"device","durationMinutes":30}
```

Make `FakeApi.create` record the passed duration and add a sender test:

```dart
await sender.start(durationMinutes: 120);
expect(api.createdDurationMinutes, 120);
```

**Step 2: Run the focused Flutter tests to verify they fail**

Run: `flutter test test/sharing_api_test.dart test/sender_test.dart`

Expected: FAIL because `create` and `start` do not accept a duration yet.

**Step 3: Implement the explicit duration contract**

Change the relevant signatures and calls only:

```dart
Future<ShareSession> create({required int durationMinutes}) => _request(
  'POST', '/api/sessions', key,
  {'source': 'device', 'durationMinutes': durationMinutes},
);

Future<void> start({required int durationMinutes}) => _begin(durationMinutes);
```

Thread the argument into `_begin` and its `api.create` call. Update test fakes and existing tests to pass a selected duration. Keep local expiry, stop/retry, GPS stream, and timer behavior unchanged.

**Step 4: Run the focused Flutter tests to verify they pass**

Run: `flutter test test/sharing_api_test.dart test/sender_test.dart`

Expected: PASS.

**Step 5: Commit**

```bash
git add mobile/lib/sharing_api.dart mobile/lib/location_sender.dart mobile/test/sender_test.dart mobile/test/sharing_api_test.dart
git commit -m "feat: send selected sharing duration"
```

### Task 3: Add the duration picker and begin sharing only after confirmation

**Files:**
- Create: `mobile/lib/share_duration_dialog.dart`
- Modify: `mobile/lib/app_shell.dart:97-105`
- Test: `mobile/test/share_duration_dialog_test.dart`
- Test: `mobile/test/app_shell_test.dart`

**Step 1: Write failing dialog and integration tests**

Add widget coverage for the five choices, a valid custom input, invalid custom values, and cancellation. The dialog function should return `Future<int?>`; tests should verify 15, 30, 60, 120, and a valid custom value, while Cancel returns `null`.

Add an AppShell test that taps **Start sharing**, chooses 30 minutes, and asserts its injected HTTP client receives one session-create request containing `durationMinutes: 30`. Add a cancel test confirming no GPS preparation or create request occurs.

**Step 2: Run the widget tests to verify they fail**

Run: `flutter test test/share_duration_dialog_test.dart test/app_shell_test.dart`

Expected: FAIL because the dialog does not exist and the start button begins sharing immediately.

**Step 3: Implement the minimum dialog and guarded start flow**

Create a dialog with preset controls for 15, 30, 60, and 120 minutes, plus Custom. In Custom mode, accept only trimmed decimal digits representing an integer from 1 through 720; present an inline validation message and do not dismiss the dialog for invalid input. Make the content scrollable for small screens and keyboards. Back, barrier dismissal, and Cancel return `null`.

In `AppShell.startSharing`, add a `_choosingShareDuration` guard. Await the picker before disposing/recreating `sender`, preparing GPS, or starting networking. After it resolves, ensure `mounted`, a non-null result, and an idle sender, then recreate the sender and call `sender.start(durationMinutes: durationMinutes)`.

**Step 4: Run the widget tests to verify they pass**

Run: `flutter test test/share_duration_dialog_test.dart test/app_shell_test.dart`

Expected: PASS. Use bounded `pump` calls rather than `pumpAndSettle` after starting sharing because the sender creates a periodic timer.

**Step 5: Commit**

```bash
git add mobile/lib/share_duration_dialog.dart mobile/lib/app_shell.dart mobile/test/share_duration_dialog_test.dart mobile/test/app_shell_test.dart
git commit -m "feat: choose sharing duration before start"
```

### Task 4: Keep the simulator and user-facing documentation compatible

**Files:**
- Modify: `backend/public/simulate.js:4`
- Modify: `backend/public/index.html:1`
- Modify: `backend/public/view.html`
- Modify: `README.md:31,54,58,80`

**Step 1: Write or update the relevant static-content checks**

If the existing browser test suite is the appropriate home, add assertions that the public copy says sharing lasts for the selected duration, rather than always one hour. Otherwise keep this task as an exact manual acceptance check: simulator start works, the landing page does not promise one hour, and the viewer shows the returned expiry.

**Step 2: Run the relevant check before implementation**

Run: `npm test`

Expected: existing tests pass; if a new copy assertion is added, it fails against the old one-hour wording.

**Step 3: Implement the compatible caller and copy changes**

Make the simulator create request explicit so it preserves its current one-hour behavior:

```js
api('/api/sessions', 'POST', el('key').value, {
  source: 'simulation',
  durationMinutes: 60,
});
```

Update non-historical product and README copy to describe the selected duration. Update retention documentation to reflect a maximum 12-hour active session plus scheduled cleanup that may retain an expired row for roughly one additional hour. Do not rewrite historical plan documents.

**Step 4: Run backend tests to verify compatibility**

Run: `npm test`

Expected: PASS.

**Step 5: Commit**

```bash
git add backend/public/simulate.js backend/public/index.html backend/public/view.html README.md
git commit -m "docs: describe configurable sharing duration"
```

### Task 5: Validate the cross-cutting change

**Files:**
- Verify: all changed files

**Step 1: Run Worker verification**

Run: `npm test && npm run typecheck`

Expected: exit 0 with all tests passing and no TypeScript errors.

**Step 2: Run Flutter verification**

Run: `flutter analyze && flutter test`

Expected: exit 0 with no analyzer findings and all Flutter tests passing.

**Step 3: Check patch integrity**

Run: `git diff --check`

Expected: no output and exit 0.

**Step 4: Review before delivery**

Have the required reviewer inspect the final diff, validation evidence, duration bounds, cancellation behavior, explicit simulator request, deployment compatibility, and documentation. Address any actionable feedback, then rerun the affected checks.

**Step 5: Commit any review fixes and deliver through a PR**

```bash
git add <reviewed-files>
git commit -m "fix: address share duration review"
git push -u origin feature/share-duration-selector
```

Open a pull request targeting `develop`, documenting the deliberate API contract change: older clients that omit `durationMinutes` receive 400, and selected durations take effect only after the Worker deployment is updated.
