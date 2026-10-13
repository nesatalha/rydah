import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mobile/app_shell.dart';
import 'package:mobile/local_store.dart';
import 'package:mobile/ride_screen.dart';
import 'package:mobile/sharing_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  sqfliteFfiInit();
  late LocalStore store;
  setUp(() async {
    store = await LocalStore.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
  });
  tearDown(() => store.close());
  Future<void> settleSql(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump();
  }

  for (final cancel in [false, true]) {
    testWidgets(
      cancel
          ? 'cancel sharing does no GPS or HTTP work'
          : 'sharing starts once with the confirmed duration',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var preparations = 0;
        final requests = <http.Request>[];
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              MaterialApp(
                home: AppShell(
                  store: store,
                  prepare: () async {
                    preparations++;
                  },
                  points: () => const Stream.empty(),
                  showTiles: false,
                ),
              ),
            );
            await settleSql(tester);
            final idleSender = tester
                .widget<RideScreen>(find.byType(RideScreen))
                .sender;
            await tester.ensureVisible(find.text('Start sharing'));
            await tester.tap(find.text('Start sharing'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(find.text('Sharing duration'), findsOneWidget);
            expect(preparations, 0);
            expect(requests, isEmpty);
            expect(
              tester.widget<RideScreen>(find.byType(RideScreen)).sender,
              same(idleSender),
            );
            if (cancel) {
              await tester.tap(find.text('Cancel'));
            } else {
              await tester.tap(find.text('30 minutes'));
              await tester.pump();
              await tester.tap(
                find.widgetWithText(FilledButton, 'Start sharing'),
              );
            }
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(preparations, cancel ? 0 : 1);
            if (cancel) {
              expect(
                tester.widget<RideScreen>(find.byType(RideScreen)).sender,
                same(idleSender),
              );
            }
            final creates = requests
                .where((request) => request.method == 'POST')
                .toList();
            expect(creates, hasLength(cancel ? 0 : 1));
            if (!cancel) {
              expect(jsonDecode(creates.single.body), {
                'source': 'device',
                'durationMinutes': 30,
              });
              expect(find.text('Copy private link'), findsOneWidget);
            }
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
          },
          () => MockClient((request) async {
            requests.add(request);
            return http.Response(
              jsonEncode({
                'id': 'session',
                'writeToken': 'write',
                'readToken': 'read',
                'expiresAt': DateTime.now()
                    .add(const Duration(minutes: 30))
                    .millisecondsSinceEpoch,
              }),
              201,
            );
          }),
        );
      },
    );
  }

  testWidgets(
    'repeated starts show only one chooser and cancel releases guard',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            store: store,
            prepare: () async => fail('GPS must wait for confirmation'),
            points: () => const Stream.empty(),
            showTiles: false,
          ),
        ),
      );
      await settleSql(tester);
      final startSharing = tester
          .widget<RideScreen>(find.byType(RideScreen))
          .startSharing;
      unawaited(startSharing());
      unawaited(startSharing());
      await tester.pumpAndSettle();
      expect(find.text('Sharing duration'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Sharing duration'), findsNothing);
      unawaited(startSharing());
      await tester.pumpAndSettle();
      expect(find.text('Sharing duration'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'recording persists across tabs and finishes into history without backend',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      final points = StreamController<GeoPoint>.broadcast();
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            store: store,
            prepare: () async {},
            points: () => points.stream,
            showTiles: false,
          ),
        ),
      );
      await settleSql(tester);
      final startRide = find.text('Start ride');
      await tester.ensureVisible(startRide);
      await tester.tap(startRide);
      await settleSql(tester);
      points.add(GeoPoint(41, 29, 5, DateTime.now()));
      await settleSql(tester);
      await tester.tap(find.text('History'));
      await settleSql(tester);
      expect(find.text('Recording'), findsOneWidget);
      await tester.tap(find.text('Ride').last);
      await tester.pump();
      await tester.ensureVisible(find.text('Finish ride'));
      await tester.tap(find.text('Finish ride'));
      await settleSql(tester);
      final rides = await tester.runAsync(() => store.rides());
      expect(rides!.single.status, 'finished');
      final saved = await tester.runAsync(() => store.points(rides.single.id));
      expect(saved, hasLength(1));
      await tester.tap(find.text('History'));
      await settleSql(tester);
      expect(find.textContaining('finished •'), findsOneWidget);
      await settleSql(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(points.close);
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets('route draft keeps its name and stops when tabs change', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          store: store,
          prepare: () async {},
          points: () => const Stream.empty(),
          showTiles: false,
        ),
      ),
    );
    await settleSql(tester);
    await tester.tap(find.text('Routes'));
    await tester.pump();
    await tester.tap(find.text('Create route'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'My route');
    await tester.tap(find.text('Settings'));
    await tester.pump();
    await tester.tap(find.text('Routes'));
    await tester.pump();
    expect(find.text('My route'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
