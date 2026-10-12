import 'dart:async';
import 'package:flutter/foundation.dart';
import 'local_store.dart';
import 'ride_models.dart';
import 'ride_metrics.dart';
import 'sharing_api.dart';

class RideRecorder extends ChangeNotifier {
  RideRecorder({
    required this.store,
    required this.prepare,
    required this.points,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final RideRepository store;
  final Future<void> Function() prepare;
  final Stream<GeoPoint> Function() points;
  final DateTime Function() clock;
  final List<RidePoint> track = [];
  int? rideId;
  DateTime? startedAt, endedAt;
  String state = 'Ready to record';
  bool recording = false,
      busy = false,
      _disposed = false,
      _stopRequested = false,
      _failed = false;
  StreamSubscription<GeoPoint>? _subscription;
  Timer? _timer;
  Future<void> _tail = Future.value();
  Future<void>? _starting;
  double distanceM = 0;
  Duration get elapsed => startedAt == null
      ? Duration.zero
      : (endedAt ?? clock()).difference(startedAt!);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (recording || busy || rideId != null || _disposed) return;
    busy = true;
    _stopRequested = false;
    _failed = false;
    state = 'Checking GPS…';
    _notify();
    final run = _begin();
    _starting = run;
    await run;
    _starting = null;
    busy = false;
    _notify();
  }

  Future<void> _begin() async {
    try {
      await prepare();
      if (_stopRequested || _disposed) return;
      final start = clock();
      final id = await store.createRide(
        start,
        'Ride ${start.toLocal().toString().substring(0, 16)}',
      );
      rideId = id;
      startedAt = start;
      endedAt = null;
      track.clear();
      distanceM = 0;
      if (_stopRequested || _disposed) return;
      recording = true;
      state = 'Waiting for GPS';
      _subscription = points().listen(
        _queue,
        onError: (Object e) {
          state = 'GPS unavailable — waiting for a fix';
          _notify();
        },
      );
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (track.isNotEmpty &&
            clock().difference(track.last.observedAt) >
                const Duration(seconds: 30)) {
          state = 'GPS signal stale — waiting for a fix';
        }
        _notify();
      });
    } catch (e) {
      state = e.toString().replaceFirst('Exception: ', '');
      recording = false;
    }
  }

  void _queue(GeoPoint point) {
    if (!recording || _stopRequested || _disposed) return;
    _tail = _tail.then((_) async {
      if (_failed) return;
      if (!point.lat.isFinite ||
          !point.lon.isFinite ||
          point.lat.abs() > 90 ||
          point.lon.abs() > 180 ||
          !point.accuracyM.isFinite ||
          point.accuracyM < 0) {
        return;
      }
      final previous = track.isEmpty ? null : track.last;
      if (previous != null && !point.observedAt.isAfter(previous.observedAt)) {
        return;
      }
      final gap =
          previous != null &&
          point.observedAt.difference(previous.observedAt) >
              const Duration(seconds: 30);
      final next = RidePoint(
        track.length + 1,
        previous == null ? 0 : previous.segment + (gap ? 1 : 0),
        point.lat,
        point.lon,
        point.accuracyM,
        point.observedAt,
      );
      try {
        await store.appendPoint(rideId!, next);
        if (previous != null && !gap) {
          distanceM += distanceBetween(
            previous.lat,
            previous.lon,
            next.lat,
            next.lon,
          );
        }
        track.add(next);
        if (!_stopRequested) state = 'Recording';
        _notify();
      } catch (e) {
        _failed = true;
        recording = false;
        endedAt = clock();
        _timer?.cancel();
        unawaited(_subscription?.cancel());
        state = 'Storage error: $e — committed points preserved';
        _notify();
      }
    });
  }

  Future<void> stop() async {
    if (_stopRequested) return;
    _stopRequested = true;
    final stopAt = clock();
    recording = false;
    busy = true;
    _timer?.cancel();
    await _subscription?.cancel();
    await _starting;
    await _tail;
    try {
      final id = rideId;
      if (id != null) await store.finishRide(id, stopAt);
      endedAt = stopAt;
      rideId = null;
      state = _failed ? 'Ride saved with a storage error' : 'Ride saved';
    } catch (e) {
      _stopRequested = false;
      state = 'Save failed: $e — retry Finish ride';
    }
    busy = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
