import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'ride_models.dart';
import 'route_models.dart';

abstract interface class RideRepository {
  Future<int> createRide(DateTime at, String name);
  Future<void> appendPoint(int id, RidePoint point);
  Future<void> finishRide(int id, DateTime at);
}

class LocalStore implements RideRepository {
  LocalStore._(this.db);
  final Database db;
  static Future<LocalStore> open({
    DatabaseFactory? factory,
    String? path,
  }) async {
    final f = factory ?? databaseFactory;
    final location = path ?? p.join(await f.getDatabasesPath(), 'rydah.db');
    final db = await f.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE rides(id INTEGER PRIMARY KEY, name TEXT NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER, status TEXT NOT NULL, checkpoint INTEGER)',
          );
          await db.execute(
            'CREATE TABLE ride_points(ride_id INTEGER NOT NULL REFERENCES rides(id) ON DELETE CASCADE, seq INTEGER NOT NULL, segment INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, accuracy REAL NOT NULL, observed_at INTEGER NOT NULL, PRIMARY KEY(ride_id,seq))',
          );
          await db.execute(
            'CREATE TABLE routes(id INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE route_stops(route_id INTEGER NOT NULL REFERENCES routes(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, segment INTEGER NOT NULL, PRIMARY KEY(route_id,ordinal))',
          );
          await db.execute(
            'CREATE TABLE route_geometry(route_id INTEGER NOT NULL REFERENCES routes(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, segment INTEGER NOT NULL, PRIMARY KEY(route_id,ordinal))',
          );
        },
      ),
    );
    return LocalStore._(db);
  }

  @override
  Future<int> createRide(DateTime at, String name) => db.insert('rides', {
    'name': name,
    'started_at': at.millisecondsSinceEpoch,
    'status': 'recording',
  });
  @override
  Future<void> appendPoint(int id, RidePoint point) =>
      db.transaction((t) async {
        await t.insert('ride_points', {
          'ride_id': id,
          'seq': point.seq,
          'segment': point.segment,
          'lat': point.lat,
          'lon': point.lon,
          'accuracy': point.accuracyM,
          'observed_at': point.observedAt.millisecondsSinceEpoch,
        });
        await t.update(
          'rides',
          {'checkpoint': point.observedAt.millisecondsSinceEpoch},
          where: 'id=?',
          whereArgs: [id],
        );
      });
  Future<List<Ride>> rides() async => (await db.query(
    'rides',
    orderBy: 'started_at DESC, id DESC',
  )).map(Ride.fromMap).toList();
  Future<List<RidePoint>> points(int id) async => (await db.query(
    'ride_points',
    where: 'ride_id=?',
    whereArgs: [id],
    orderBy: 'seq',
  )).map(RidePoint.fromMap).toList();
  @override
  Future<void> finishRide(int id, DateTime at) async {
    await db.update(
      'rides',
      {'ended_at': at.millisecondsSinceEpoch, 'status': 'finished'},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> finishInterrupted(int id) async {
    await db.rawUpdate(
      "UPDATE rides SET ended_at=COALESCE(checkpoint,started_at),status='interrupted' WHERE id=? AND status='recording'",
      [id],
    );
  }

  Future<void> renameRide(int id, String name) async {
    await db.update('rides', {'name': name}, where: 'id=?', whereArgs: [id]);
  }

  Future<void> deleteRide(int id) async {
    await db.delete('rides', where: 'id=?', whereArgs: [id]);
  }

  Future<int> saveRoute(SavedRoute route) => db.transaction((t) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var id = route.id;
    if (id == null) {
      id = await t.insert('routes', {
        'name': route.name,
        'kind': route.kind,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      await t.update(
        'routes',
        {'name': route.name, 'kind': route.kind, 'updated_at': now},
        where: 'id=?',
        whereArgs: [id],
      );
      await t.delete('route_stops', where: 'route_id=?', whereArgs: [id]);
      await t.delete('route_geometry', where: 'route_id=?', whereArgs: [id]);
    }
    for (final table in ['route_stops', 'route_geometry']) {
      final points = table == 'route_stops' ? route.stops : route.geometry;
      for (var i = 0; i < points.length; i++) {
        await t.insert(table, {
          'route_id': id,
          'ordinal': i,
          'lat': points[i].lat,
          'lon': points[i].lon,
          'segment': points[i].segment,
        });
      }
    }
    return id;
  });
  Future<List<SavedRoute>> routes() async {
    final rows = await db.query('routes', orderBy: 'updated_at DESC, id DESC');
    return Future.wait(rows.map((r) => route(r['id'] as int)));
  }

  Future<SavedRoute> route(int id) async {
    final row = (await db.query(
      'routes',
      where: 'id=?',
      whereArgs: [id],
    )).single;
    Future<List<RoutePoint>> load(String table) async =>
        (await db.query(
              table,
              where: 'route_id=?',
              whereArgs: [id],
              orderBy: 'ordinal',
            ))
            .map(
              (m) => RoutePoint(
                (m['lat'] as num).toDouble(),
                (m['lon'] as num).toDouble(),
                segment: m['segment'] as int,
              ),
            )
            .toList();
    return SavedRoute(
      id,
      row['name'] as String,
      row['kind'] as String,
      await load('route_stops'),
      await load('route_geometry'),
    );
  }

  Future<void> deleteRoute(int id) async {
    await db.delete('routes', where: 'id=?', whereArgs: [id]);
  }

  Future<void> close() => db.close();
}
