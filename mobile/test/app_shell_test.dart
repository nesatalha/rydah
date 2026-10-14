import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mobile/app_shell.dart';
import 'package:mobile/local_store.dart';
import 'package:mobile/sharing_api.dart';

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
