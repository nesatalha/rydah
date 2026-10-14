import 'dart:async';
import 'package:flutter/foundation.dart';
import 'group_api.dart';
import 'sharing_api.dart';

class GroupController extends ChangeNotifier {
  GroupController(
    this.api, {
    this.onMembershipLost,
    DateTime Function()? now,
    this.interval = const Duration(seconds: 5),
  }) : now = now ?? DateTime.now;
  final GroupApi api;
  final Future<void> Function()? onMembershipLost;
  final DateTime Function() now;
  final Duration interval;
  Map<String, dynamic>? snapshot;
  final photos = <String, Uint8List>{};
  final _versions = <String, dynamic>{};
  List<Map<String, dynamic>> get members =>
      ((snapshot?['members'] as List?) ?? [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
  String? error;
  DateTime? lastRefresh;
  bool _fetching = false, _disposed = false, _visible = false;
  Timer? _timer;
  Map<String, dynamic>? visibleLocation(Map<String, dynamic> member) {
    final sharing = member['sharing'] as Map?;
    final fix = sharing?['location'] as Map?;
    if (sharing == null ||
        fix == null ||
        !['live', 'stale', 'offline'].contains(sharing['state'])) {
      return null;
    }
    final t = now().millisecondsSinceEpoch;
    if ((sharing['expiresAt'] as num) <= t) return null;
    return fix.cast<String, dynamic>();
  }

  void visible(bool value) {
    _visible = value;
    _timer?.cancel();
    _timer = null;
    if (value) {
      unawaited(refresh());
      _timer = Timer.periodic(interval, (_) {
        if (_visible) unawaited(refresh());
      });
    }
  }

  void clear() {
    snapshot = null;
    photos.clear();
    _versions.clear();
  }

  Future<void> refresh() async {
    if (_fetching || _disposed) return;
    _fetching = true;
    try {
      final next = await api.group();
      if (_disposed) return;
      snapshot = next;
      error = null;
      lastRefresh = now();
      final ids = members.map((m) => m['deviceId'] as String).toSet();
      photos.removeWhere((k, v) => !ids.contains(k));
      _versions.removeWhere((k, v) => !ids.contains(k));
      for (final member in members) {
        final id = member['deviceId'] as String;
        final version = member['avatarVersion'];
        if (version == null) {
          photos.remove(id);
          _versions.remove(id);
          continue;
        }
        if (_versions[id] != version) {
          photos.remove(id);
          try {
            final bytes = await api.memberAvatar(id);
            if (_disposed) return;
            photos[id] = bytes;
            _versions[id] = version;
          } catch (e) {
            if (e is SharingApiException &&
                (e.statusCode == 401 || e.statusCode == 403)) {
              rethrow;
            }
          }
        }
      }
    } catch (e) {
      if (_disposed) return;
      error = e.toString();
      if (e is SharingApiException && [401, 403, 404].contains(e.statusCode)) {
        clear();
        if (e.statusCode != 404) unawaited(onMembershipLost?.call());
      }
    } finally {
      _fetching = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    clear();
    super.dispose();
  }
}
