import 'dart:math';

/// Straight-line distance is multiplied by this to approximate real roads.
const roadFactor = 1.3;
const arrivedRadiusM = 200.0;
const stoppedBelowMps = 5 / 3.6;
const maxEta = Duration(hours: 3);

/// GPS speed accuracy worse than this (m/s) is still used but flagged rough.
const poorSpeedAccuracyMps = 5.0;
const _speedWindow = 3;
const _speedMaxGapMs = 30000;

double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a =
      pow(sin(dLat / 2), 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLon / 2), 2);
  return 2 * r * asin(min(1, sqrt(a)));
}

/// Geolocator reports 0.0 when speed is unavailable, so [hasSpeed] decides.
double? gpsSpeed({required bool hasSpeed, required double speed}) =>
    hasSpeed && speed.isFinite && speed >= 0 && speed <= 100 ? speed : null;

double? gpsSpeedAccuracy({
  required bool hasSpeedAccuracy,
  required double accuracy,
}) => hasSpeedAccuracy && accuracy.isFinite && accuracy >= 0 && accuracy <= 100
    ? accuracy
    : null;

enum EtaKind { moving, arrived, stopped, distanceOnly, offline }

class MemberEta {
  const MemberEta(this.kind, this.distanceM, {this.eta, this.rough = false});
  final EtaKind kind;
  final double distanceM;
  final Duration? eta;
  final bool rough;
}

MemberEta classifyEta({
  required double distanceM,
  required double? speedMps,
  required bool live,
  bool rough = false,
}) {
  // Arrived wins over offline: a rider parked at the meeting point often goes quiet.
  if (distanceM <= arrivedRadiusM) return MemberEta(EtaKind.arrived, distanceM);
  if (!live) return MemberEta(EtaKind.offline, distanceM);
  if (speedMps == null) return MemberEta(EtaKind.distanceOnly, distanceM);
  if (speedMps < stoppedBelowMps) return MemberEta(EtaKind.stopped, distanceM);
  final seconds = distanceM * roadFactor / speedMps;
  if (seconds > maxEta.inSeconds) {
    return MemberEta(EtaKind.distanceOnly, distanceM);
  }
  final minutes = max(1, (seconds / 60).round());
  return MemberEta(
    EtaKind.moving,
    distanceM,
    eta: Duration(minutes: minutes),
    rough: rough,
  );
}

String formatDistance(double m) => m < 100000
    ? '${(m / 1000).toStringAsFixed(1)} km'
    : '${(m / 1000).round()} km';

String formatEta(Duration d) => d.inMinutes < 60
    ? '~${d.inMinutes} min'
    : '~${d.inHours} h ${d.inMinutes % 60} min';

String etaLabel(MemberEta e) => switch (e.kind) {
  EtaKind.moving =>
    '${formatEta(e.eta!)}${e.rough ? ' (rough)' : ''} • ${formatDistance(e.distanceM)}',
  EtaKind.arrived => 'Arrived',
  EtaKind.stopped => 'Stopped • ${formatDistance(e.distanceM)}',
  EtaKind.distanceOnly => formatDistance(e.distanceM),
  EtaKind.offline => 'Offline • ${formatDistance(e.distanceM)}',
};

class SpeedSample {
  const SpeedSample(this.at, this.speed, this.accuracy);
  final int at;
  final double? speed, accuracy;
}

class SpeedBuffer {
  SpeedBuffer(this.expiresAt, this.samples);
  final int expiresAt;
  final List<SpeedSample> samples;
}

/// Keeps the last few uploaded speeds of one session. Repeated polls of the
/// same point are ignored; unknown speed, a long gap or a new session resets.
SpeedBuffer pushSpeedSample(
  SpeedBuffer? buffer,
  SpeedSample next,
  int expiresAt,
) {
  final previous = buffer?.expiresAt == expiresAt
      ? buffer!.samples
      : const <SpeedSample>[];
  if (previous.isNotEmpty && next.at <= previous.last.at) return buffer!;
  // An unknown reading is kept alone, so known speeds never mix with it.
  if (next.speed == null ||
      (previous.isNotEmpty &&
          (previous.last.speed == null ||
              next.at - previous.last.at > _speedMaxGapMs))) {
    return SpeedBuffer(expiresAt, [next]);
  }
  final samples = [...previous, next];
  return SpeedBuffer(
    expiresAt,
    samples.sublist(max(0, samples.length - _speedWindow)),
  );
}

/// Median of the buffered speeds (mean of two), so one traffic-light zero
/// doesn't flip a moving rider to stopped. Rough when the latest reading's
/// accuracy is poor.
({double speed, bool rough})? smoothedSpeed(SpeedBuffer? buffer) {
  final samples = buffer?.samples ?? const <SpeedSample>[];
  if (samples.isEmpty || samples.last.speed == null) return null;
  final speeds = [for (final s in samples) s.speed!]..sort();
  final n = speeds.length;
  final median = n.isOdd
      ? speeds[n ~/ 2]
      : (speeds[n ~/ 2 - 1] + speeds[n ~/ 2]) / 2;
  final accuracy = samples.last.accuracy;
  return (
    speed: median,
    rough: accuracy != null && accuracy > poorSpeedAccuracyMps,
  );
}

/// One line for the Group tab; null when there is no meeting point.
String? etaSummary(List<(String, MemberEta)> rows, {required bool hasMeeting}) {
  if (!hasMeeting) return null;
  if (rows.isEmpty) return 'No one is sharing a location';
  final arrived = rows.where((r) => r.$2.kind == EtaKind.arrived).length;
  if (arrived == rows.length) return 'Everyone arrived';
  final moving = rows.where((r) => r.$2.kind == EtaKind.moving).toList()
    ..sort((a, b) => a.$2.eta!.compareTo(b.$2.eta!));
  final next = moving.isEmpty
      ? ''
      : ' • next: ${moving.first.$1} ${formatEta(moving.first.$2.eta!)}';
  return '$arrived of ${rows.length} arrived$next';
}
