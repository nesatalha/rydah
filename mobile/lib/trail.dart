import 'package:latlong2/latlong.dart';

class TrailPoint {
  const TrailPoint(this.seq, this.lat, this.lon, this.at);
  final int seq;
  final double lat, lon;
  final int at;
  LatLng get position => LatLng(lat, lon);
}

/// A member's cached trail; [expiresAt] identifies the session it belongs to.
class MemberTrail {
  MemberTrail(this.expiresAt, this.setting, this.points);
  final int expiresAt;
  final String setting;
  final List<TrailPoint> points;
  int get maxSeq => points.isEmpty ? 0 : points.last.seq;
}

/// Merges a server trail (`{setting, windowStartsAt, reset, points}`) into the
/// cache. A reset or a different session replaces it; otherwise only newer
/// points are appended. Returns null when the server sends no trail.
MemberTrail? mergeTrail(
  MemberTrail? current,
  Map<String, dynamic>? json,
  int expiresAt,
) {
  if (json == null) return null;
  final keep =
      current != null &&
      current.expiresAt == expiresAt &&
      json['reset'] != true;
  final points = keep ? [...current.points] : <TrailPoint>[];
  var maxSeq = points.isEmpty ? 0 : points.last.seq;
  for (final raw in json['points'] as List) {
    final p = raw as List;
    final seq = (p[0] as num).toInt();
    if (seq <= maxSeq) continue;
    points.add(
      TrailPoint(
        seq,
        (p[1] as num).toDouble(),
        (p[2] as num).toDouble(),
        (p[3] as num).toInt(),
      ),
    );
    maxSeq = seq;
  }
  final start = json['windowStartsAt'] as num?;
  if (start != null) points.removeWhere((p) => p.at < start);
  return MemberTrail(expiresAt, json['setting'] as String, points);
}

class TrailSegment {
  const TrailSegment(this.points, this.opacity);
  final List<LatLng> points;
  final double opacity;
}

const _fade = [0.85, 0.6, 0.4, 0.22];

/// Splits a trail at gaps over a minute and into age buckets, newest most
/// opaque. Neighbouring segments share their boundary point; the path ends at
/// [current] when it is newer than the last trail point.
List<TrailSegment> fadeSegments(
  List<TrailPoint> points, {
  required String setting,
  required int now,
  TrailPoint? current,
}) {
  final path = [...points];
  if (path.isNotEmpty && current != null && current.at > path.last.at) {
    path.add(current);
  }
  if (path.length < 2) return const [];
  final window = switch (setting) {
    '15m' => 900000,
    '30m' => 1800000,
    _ => now - path.first.at,
  };
  final span = window < 1 ? 1 : window;
  int bucket(int at) =>
      ((now - at) / span * _fade.length).floor().clamp(0, _fade.length - 1);
  final segments = <TrailSegment>[];
  var segment = [path.first];
  void flush() {
    if (segment.length > 1) {
      segments.add(
        TrailSegment(
          segment.map((p) => p.position).toList(),
          _fade[bucket(segment.last.at)],
        ),
      );
    }
  }

  for (var i = 1; i < path.length; i++) {
    final previous = path[i - 1], point = path[i];
    if (point.at - previous.at > 60000) {
      flush();
      segment = [point];
    } else if (bucket(point.at) != bucket(previous.at)) {
      segment.add(point);
      flush();
      segment = [point];
    } else {
      segment.add(point);
    }
  }
  flush();
  return segments;
}
