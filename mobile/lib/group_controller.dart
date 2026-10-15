import 'dart:async';
import 'package:flutter/foundation.dart';
import 'group_api.dart';
import 'sharing_api.dart';
import 'trail.dart';
import 'meeting_eta.dart' as eta_math show etaSummary;
import 'meeting_eta.dart' hide etaSummary;

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
  final trails = <String, MemberTrail>{};
  final _speeds = <String, SpeedBuffer>{};
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

  /// Adds each visible member's latest uploaded speed to its buffer.
  void recordSpeeds() {
    final seen = <String>{};
    for (final member in members) {
      final location = visibleLocation(member);
      if (location == null) continue;
      final id = member['deviceId'] as String;
      seen.add(id);
      _speeds[id] = pushSpeedSample(
        _speeds[id],
        SpeedSample(
          (location['observedAt'] as num).toInt(),
          (location['speedMps'] as num?)?.toDouble(),
          (location['speedAccuracyMps'] as num?)?.toDouble(),
        ),
        ((member['sharing'] as Map)['expiresAt'] as num).toInt(),
      );
    }
    _speeds.removeWhere((k, v) => !seen.contains(k));
  }

  /// Distance and ETA to the meeting point, or null without one or without a
  /// visible location.
  MemberEta? memberEta(Map<String, dynamic> member) {
    final meeting = snapshot?['meetingPoint'] as Map?;
    final location = visibleLocation(member);
    if (meeting == null || location == null) return null;
    final speed = smoothedSpeed(_speeds[member['deviceId']]);
    return classifyEta(
      distanceM: haversineM(
        (location['lat'] as num).toDouble(),
        (location['lon'] as num).toDouble(),
        (meeting['lat'] as num).toDouble(),
        (meeting['lon'] as num).toDouble(),
      ),
      speedMps: speed?.speed,
      rough: speed?.rough ?? false,
      live: (member['sharing'] as Map)['state'] == 'live' && error == null,
    );
  }

  String? get etaSummary => eta_math.etaSummary([
    for (final m in members)
      if (memberEta(m) case final eta?) (m['name'] as String, eta),
  ], hasMeeting: snapshot?['meetingPoint'] != null);

  /// Trail points for a member whose location is currently shown.
  List<TrailPoint> visibleTrail(Map<String, dynamic> member) {
    if (visibleLocation(member) == null) return const [];
    return trails[member['deviceId']]?.points ?? const [];
  }

  // At most 32 cursors, matching the server limit.
  String get _trailSince => trails.entries
      .take(32)
      .map((e) => '${e.key}:${e.value.expiresAt}:${e.value.maxSeq}')
      .join(',');

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
    trails.clear();
    _speeds.clear();
  }

  Future<void> refresh() async {
    if (_fetching || _disposed) return;
    _fetching = true;
    try {
      final next = await api.group(trailSince: _trailSince);
      if (_disposed) return;
      snapshot = next;
      error = null;
      lastRefresh = now();
      final ids = members.map((m) => m['deviceId'] as String).toSet();
      photos.removeWhere((k, v) => !ids.contains(k));
      trails.removeWhere((k, v) => !ids.contains(k));
      recordSpeeds();
      for (final member in members) {
        final id = member['deviceId'] as String;
        final sharing = (member['sharing'] as Map?)?.cast<String, dynamic>();
        final merged = sharing == null
            ? null
            : mergeTrail(
                trails[id],
                (sharing['trail'] as Map?)?.cast<String, dynamic>(),
                (sharing['expiresAt'] as num).toInt(),
              );
        if (merged == null) {
          trails.remove(id);
        } else {
          trails[id] = merged;
        }
      }
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
