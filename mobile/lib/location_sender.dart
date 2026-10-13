import 'dart:async';
import 'package:flutter/foundation.dart';
import 'sharing_api.dart';

class LocationSender extends ChangeNotifier {
  LocationSender({
    required this.api,
    required this.prepare,
    required this.points,
    this.cadence = const Duration(seconds: 5),
  });
  final SharingApi api;
  final Future<void> Function() prepare;
  final Stream<GeoPoint> Function() points;
  final Duration cadence;
  String state = 'Ready';
  ShareSession? session;
  GeoPoint? latest;
  DateTime? lastUpload;
  Timer? _timer;
  StreamSubscription<GeoPoint>? _subscription;
  Future<void>? _starting;
  bool _stopRequested = false,
      _uploading = false,
      _disposed = false,
      _stopping = false;
  int _seq = 0;
  bool get busy => _starting != null || _stopping;
  bool get sharing => session != null && !_stopRequested;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start({required int durationMinutes}) async {
    if (_starting != null || session != null || _stopping || _disposed) return;
    _stopRequested = false;
    state = 'Checking GPS…';
    _notify();
    final run = _begin(durationMinutes: durationMinutes);
    _starting = run;
    try {
      await run;
    } finally {
      _starting = null;
      _notify();
    }
  }

  Future<void> _begin({required int durationMinutes}) async {
    try {
      await prepare();
      if (_stopRequested || _disposed) return;
      state = 'Creating private session…';
      _notify();
      session = await api.create(durationMinutes: durationMinutes);
      _seq = 0;
      lastUpload = null;
      latest = null;
      if (_stopRequested || _disposed) {
        await _endRemote();
        return;
      }
      state = 'Waiting for GPS';
      _subscription = points().listen(
        (point) {
          latest = point;
          _notify();
          if (lastUpload == null) unawaited(_upload());
        },
        onError: (Object e) {
          state = 'GPS error: $e';
          _notify();
        },
      );
      _timer = Timer.periodic(cadence, (_) => unawaited(_upload()));
      _notify();
    } catch (e) {
      state = e.toString().replaceFirst('Exception: ', '');
      _notify();
    }
  }

  Future<void> _upload() async {
    final s = session;
    final point = latest;
    if (_stopRequested || _disposed || s == null) {
      return;
    }
    if (!DateTime.now().isBefore(s.expiresAt)) {
      await _finish('Expired — start a new share');
      return;
    }
    if (_uploading || point == null) return;
    _uploading = true;
    try {
      await api.upload(s, ++_seq, point);
      if (!_stopRequested && !_disposed && identical(session, s)) {
        lastUpload = DateTime.now();
        state = 'Sharing';
      }
    } catch (e) {
      if (!_stopRequested && !_disposed && identical(session, s)) {
        if (e is SharingApiException && e.statusCode == 410) {
          await _finish('Sharing ended or expired — start a new share');
        } else {
          state =
              'Upload failed: ${e.toString().replaceFirst('Exception: ', '')}';
        }
      }
    } finally {
      _uploading = false;
      _notify();
    }
  }

  Future<void> _cancel() async {
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _finish(String message) async {
    _stopRequested = true;
    await _cancel();
    session = null;
    latest = null;
    lastUpload = null;
    state = message;
    _notify();
  }

  Future<void> _endRemote() async {
    final s = session;
    if (s == null) return;
    if (!DateTime.now().isBefore(s.expiresAt)) {
      await _finish('Expired — start a new share');
      return;
    }
    try {
      await api.stop(s);
      await _finish('Ended');
    } catch (e) {
      if (e is SharingApiException && e.statusCode == 410) {
        await _finish('Expired — start a new share');
      } else {
        state = 'Stop failed — retry';
      }
    }
  }

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _stopRequested = true;
    state = 'Stopping…';
    _notify();
    await _cancel();
    final pending = _starting;
    if (pending != null) {
      await pending;
    }
    if (session != null) {
      await _endRemote();
    } else {
      state = 'Ended';
    }
    _stopping = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRequested = true;
    unawaited(_cancel());
    final s = session;
    if (s != null) unawaited(api.stop(s).catchError((_) {}));
    super.dispose();
  }
}
