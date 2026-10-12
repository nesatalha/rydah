class Ride {
  Ride(this.id, this.name, this.startedAt, this.endedAt, this.status);
  final int id;
  final String name, status;
  final DateTime startedAt;
  final DateTime? endedAt;
  factory Ride.fromMap(Map<String, Object?> m) => Ride(
    m['id'] as int,
    m['name'] as String,
    DateTime.fromMillisecondsSinceEpoch(m['started_at'] as int, isUtc: true),
    m['ended_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            m['ended_at'] as int,
            isUtc: true,
          ),
    m['status'] as String,
  );
}

class RidePoint {
  RidePoint(
    this.seq,
    this.segment,
    this.lat,
    this.lon,
    this.accuracyM,
    this.observedAt,
  );
  final int seq, segment;
  final double lat, lon, accuracyM;
  final DateTime observedAt;
  factory RidePoint.fromMap(Map<String, Object?> m) => RidePoint(
    m['seq'] as int,
    m['segment'] as int,
    (m['lat'] as num).toDouble(),
    (m['lon'] as num).toDouble(),
    (m['accuracy'] as num).toDouble(),
    DateTime.fromMillisecondsSinceEpoch(m['observed_at'] as int, isUtc: true),
  );
}
