import 'dart:async';
import 'package:flutter/foundation.dart';
import 'sharing_api.dart';
import 'account_store.dart';
import 'group_api.dart';

class LocationSender extends ChangeNotifier {
  LocationSender({
    required this.api,
    required this.prepare,
    required this.points,
    this.accountStore,
    this.audience = 'viewer',
    this.durationMinutes = 60,
    this.trail = 'off',
    this.cadence = const Duration(seconds: 5),
  });
  final SharingApi api;
  final AccountStore? accountStore;
  String audience;
  int durationMinutes;
  String trail;
  DeviceAccount? get account =>
      api is GroupApi ? (api as GroupApi).account : null;
  bool get hasPending => session != null || account?.pending != null;
  Future<void> _persist() async {
    if (accountStore != null && account != null) {
      await accountStore!.save(account!);
    }
  }

  Future<void> recover() async {
    if (account?.pending == null) return;
    state = 'Unfinished share — stopping safely';
    await stop();
  }

  Future<ShareSession> _create() async {
    final group = api;
    if (group is! GroupApi) return api.create();
    if (account!.pending == null) {
      account!.pending = {
        'id': randomId(),
        'readToken': randomToken(),
        'writeToken': randomToken(),
        'audience': audience,
        'durationMinutes': durationMinutes,
        'trail': trail,
        'backend': api.base,
        'stop': false,
      };
    }
    await _persist();
    final draft = account!.pending!;
    final result = await group.createSession({
      for (final k in [
        'id',
        'readToken',
        'writeToken',
        'audience',
        'durationMinutes',
        'trail',
      ])
        // Pending records from older versions have no trail; replay them unchanged.
        if (draft.containsKey(k)) k: draft[k],
    });
    draft['expiresAt'] = result.expiresAt.millisecondsSinceEpoch;
    await _persist();
    return result;
  }

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

  Future<void> start() async {
    if (_starting != null || hasPending || _stopping || _disposed) return;
    _stopRequested = false;
    state = 'Checking GPS…';
    _notify();
    final run = _begin();
    _starting = run;
    try {
      await run;
    } finally {
      _starting = null;
      _notify();
    }
  }

  Future<void> _begin() async {
    try {
      await prepare();
      if (_stopRequested || _disposed) return;
      state = 'Creating private session…';
      _notify();
      session = await _create();
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
    if (account != null) {
      account!.pending = null;
      await _persist();
    }
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
    if (account?.pending != null) {
      account!.pending!['stop'] = true;
      try {
        await _persist();
      } catch (e) {
        state = 'Unable to save stop — retry: $e';
        _stopping = false;
        _notify();
        return;
      }
    }
    final pending = _starting;
    if (pending != null) {
      await pending;
    }
    if (session == null && account?.pending != null) {
      try {
        final draft = account!.pending!;
        final expiry = draft['expiresAt'] as int?;
        if (expiry != null && DateTime.now().millisecondsSinceEpoch >= expiry) {
          await _finish('Expired — start a new share');
        } else if (expiry != null) {
          session = ShareSession(
            draft['id'],
            draft['writeToken'],
            draft['readToken'],
            DateTime.fromMillisecondsSinceEpoch(expiry),
          );
        } else {
          session = await _create();
        }
      } catch (e) {
        if (e is SharingApiException && e.statusCode == 410) {
          await _finish('Expired — start a new share');
        } else {
          state = 'Stop failed — retry';
        }
      }
    }
    if (session != null) {
      await _endRemote();
    } else if (account?.pending == null && !state.startsWith('Expired')) {
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
    unawaited(stop().catchError((_) {}));
    super.dispose();
  }
}
