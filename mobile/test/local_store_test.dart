import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mobile/local_store.dart';
import 'package:mobile/ride_models.dart';
import 'package:mobile/route_models.dart';

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
  test(
    'committed points are ordered; rename and cascade delete persist',
    () async {
      final id = await store.createRide(DateTime.utc(2026), 'Morning');
      await store.appendPoint(
        id,
        RidePoint(1, 0, 41, 29, 5, DateTime.utc(2026)),
      );
      await store.appendPoint(
        id,
        RidePoint(2, 1, 42, 30, 6, DateTime.utc(2026, 1, 1, 0, 1)),
      );
      await store.renameRide(id, 'Evening');
      expect((await store.rides()).single.name, 'Evening');
      expect((await store.points(id)).map((p) => p.seq), [1, 2]);
      await store.finishRide(id, DateTime.utc(2026, 1, 1, 0, 2));
      expect((await store.rides()).single.status, 'finished');
      await store.deleteRide(id);
      expect(await store.points(id), isEmpty);
    },
  );
  test('failed append leaves previous checkpoint intact', () async {
    final id = await store.createRide(DateTime.utc(2026), 'Ride');
    final point = RidePoint(1, 0, 41, 29, 5, DateTime.utc(2026));
    await store.appendPoint(id, point);
    await expectLater(store.appendPoint(id, point), throwsA(anything));
    expect(await store.points(id), hasLength(1));
  });
  test('route stops, geometry and segment breaks round trip', () async {
    final route = SavedRoute(
      null,
      'Draft',
      'draft',
      [RoutePoint(41, 29), RoutePoint(42, 30)],
      [RoutePoint(41, 29), RoutePoint(42, 30, segment: 1)],
    );
    final id = await store.saveRoute(route);
    final saved = await store.route(id);
    expect(saved.name, 'Draft');
    expect(saved.geometry.last.segment, 1);
    expect((await store.routes()).single.name, 'Draft');
    await store.deleteRoute(id);
    expect(await store.routes(), isEmpty);
  });
  test(
    'reopening SQLite preserves committed rides and interrupted checkpoints',
    () async {
      final directory = await Directory.systemTemp.createTemp('rydah-test-');
      final path = '${directory.path}/rides.db';
      final disk = await LocalStore.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      final start = DateTime.utc(2026);
      final id = await disk.createRide(start, 'Persisted');
      await disk.appendPoint(
        id,
        RidePoint(1, 0, 41, 29, 5, start.add(const Duration(seconds: 20))),
      );
      await disk.close();
      final reopened = await LocalStore.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      expect((await reopened.rides()).single.status, 'recording');
      await reopened.finishInterrupted(id);
      final ride = (await reopened.rides()).single;
      expect(
        ride.endedAt!.difference(ride.startedAt),
        const Duration(seconds: 20),
      );
      expect(await reopened.points(id), hasLength(1));
      await reopened.close();
      await directory.delete(recursive: true);
    },
  );
}
