import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/local_store.dart';
import 'package:mobile/ride_models.dart';
import 'package:mobile/ride_recorder.dart';
import 'package:mobile/sharing_api.dart';

class MemoryRides implements RideRepository {
  final List<RidePoint> saved = [];
  bool failed = false, finished = false;
  Completer<void>? gate;
  @override
  Future<int> createRide(DateTime at, String name) async => 1;
  @override
  Future<void> appendPoint(int id, RidePoint p) async {
    await gate?.future;
    if (failed) throw Exception('disk full');
    saved.add(p);
  }

  @override
  Future<void> finishRide(int id, DateTime at) async {
    finished = true;
  }
}

void main() {
  test('permission denial creates no ride', () async {
    final repo = MemoryRides();
    final recorder = RideRecorder(
      store: repo,
      prepare: () async => throw Exception('denied'),
      points: () => const Stream.empty(),
    );
    await recorder.start();
    expect(recorder.rideId, isNull);
    expect(recorder.state, contains('denied'));
    recorder.dispose();
  });
  test(
    'valid fixes commit in order, ignore invalid, and break long gaps',
    () async {
      final repo = MemoryRides();
      final stream = StreamController<GeoPoint>();
      final recorder = RideRecorder(
        store: repo,
        prepare: () async {},
        points: () => stream.stream,
      );
      await recorder.start();
      final now = DateTime.now();
      stream.add(GeoPoint(0, 0, 5, now));
      stream.add(GeoPoint(0, 0.001, 5, now.add(const Duration(seconds: 1))));
      stream.add(
        GeoPoint(double.nan, 0, 5, now.add(const Duration(seconds: 2))),
      );
      stream.add(GeoPoint(0, 0.001, 5, now.add(const Duration(seconds: 1))));
      stream.add(GeoPoint(1, 1, 5, now.add(const Duration(minutes: 2))));
      await Future<void>.delayed(Duration.zero);
      await recorder.stop();
      expect(repo.saved, hasLength(3));
      expect(repo.saved.last.segment, 1);
      expect(recorder.distanceM, closeTo(111.2, 0.2));
      expect(repo.finished, isTrue);
      recorder.dispose();
      await stream.close();
    },
  );
  test(
    'stop drains pending commits and disk failure does not invent a point',
    () async {
      final repo = MemoryRides()..gate = Completer<void>();
      final stream = StreamController<GeoPoint>();
      final recorder = RideRecorder(
        store: repo,
        prepare: () async {},
        points: () => stream.stream,
      );
      await recorder.start();
      stream.add(GeoPoint(41, 29, 5, DateTime.now()));
      await Future<void>.delayed(Duration.zero);
      final stop = recorder.stop();
      expect(repo.finished, isFalse);
      repo.gate!.complete();
      await stop;
      expect(repo.saved, hasLength(1));
      recorder.dispose();
      await stream.close();
    },
  );
  test('storage failure stops GPS visibly and keeps committed data', () async {
    final repo = MemoryRides()..failed = true;
    final stream = StreamController<GeoPoint>();
    final recorder = RideRecorder(
      store: repo,
      prepare: () async {},
      points: () => stream.stream,
    );
    await recorder.start();
    stream.add(GeoPoint(41, 29, 5, DateTime.now()));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(recorder.recording, isFalse);
    expect(recorder.state, contains('Storage error'));
    expect(recorder.track, isEmpty);
    recorder.dispose();
    await stream.close();
  });
}
