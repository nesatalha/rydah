import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/meeting_eta.dart';

void main() {
  test('haversine matches known distances', () {
    expect(
      haversineM(41.0082, 28.9784, 39.9334, 32.8597),
      closeTo(351000, 2000),
    );
    expect(haversineM(41, 29, 41, 29), 0);
  });
  test(
    'gpsSpeed nulls unavailable, negative, NaN and >100; accuracy likewise',
    () {
      expect(gpsSpeed(hasSpeed: false, speed: 0), isNull);
      expect(gpsSpeed(hasSpeed: true, speed: -1), isNull);
      expect(gpsSpeed(hasSpeed: true, speed: double.nan), isNull);
      expect(gpsSpeed(hasSpeed: true, speed: 100.5), isNull);
      expect(gpsSpeed(hasSpeed: true, speed: 0), 0);
      expect(gpsSpeed(hasSpeed: true, speed: 13.4), 13.4);
      expect(gpsSpeedAccuracy(hasSpeedAccuracy: false, accuracy: 0), isNull);
      expect(gpsSpeedAccuracy(hasSpeedAccuracy: true, accuracy: 6), 6);
      expect(gpsSpeedAccuracy(hasSpeedAccuracy: true, accuracy: 250), isNull);
    },
  );
  test(
    'classify: arrived within 200 m even offline, offline when not live, distance only without speed, stopped under 5 km/h, ETA with 1.3 road factor, distance only over 3 h',
    () {
      expect(
        classifyEta(distanceM: 150, speedMps: 10, live: false).kind,
        EtaKind.arrived,
      );
      expect(
        classifyEta(distanceM: 8000, speedMps: 10, live: false).kind,
        EtaKind.offline,
      );
      expect(
        classifyEta(distanceM: 8000, speedMps: null, live: true).kind,
        EtaKind.distanceOnly,
      );
      expect(
        classifyEta(distanceM: 8000, speedMps: 1.2, live: true).kind,
        EtaKind.stopped,
      );
      final moving = classifyEta(distanceM: 8000, speedMps: 13.89, live: true);
      expect(moving.kind, EtaKind.moving);
      expect(moving.eta, const Duration(minutes: 12));
      expect(etaLabel(moving), '~12 min • 8.0 km');
      expect(
        classifyEta(distanceM: 300, speedMps: 30, live: true).eta,
        const Duration(minutes: 1),
      );
      expect(
        classifyEta(distanceM: 400000, speedMps: 10, live: true).kind,
        EtaKind.distanceOnly,
      );
      expect(
        etaLabel(classifyEta(distanceM: 150, speedMps: 0, live: true)),
        'Arrived',
      );
      expect(
        etaLabel(classifyEta(distanceM: 8000, speedMps: 0, live: true)),
        'Stopped • 8.0 km',
      );
      expect(
        etaLabel(classifyEta(distanceM: 8000, speedMps: null, live: true)),
        '8.0 km',
      );
      expect(
        etaLabel(classifyEta(distanceM: 8000, speedMps: 9, live: false)),
        'Offline • 8.0 km',
      );
      expect(
        etaLabel(
          classifyEta(
            distanceM: 8000,
            speedMps: 13.89,
            live: true,
            rough: true,
          ),
        ),
        '~12 min (rough) • 8.0 km',
      );
    },
  );
  test('formatting: km decimals, whole km over 100, ~N min, ~1 h 25 min', () {
    expect(formatDistance(8040), '8.0 km');
    expect(formatDistance(123456), '123 km');
    expect(formatEta(const Duration(minutes: 7)), '~7 min');
    expect(formatEta(const Duration(minutes: 85)), '~1 h 25 min');
  });
  test(
    'smoothing: median of 3 ignores single traffic-light zero, dedupes same observedAt, resets on null speed, 30 s gap and new session, flags rough accuracy',
    () {
      SpeedBuffer? b;
      b = pushSpeedSample(b, const SpeedSample(0, 13, 1), 900);
      b = pushSpeedSample(b, const SpeedSample(5000, 13, 1), 900);
      b = pushSpeedSample(b, const SpeedSample(10000, 0, 1), 900);
      expect(smoothedSpeed(b)!.speed, 13);
      b = pushSpeedSample(b, const SpeedSample(10000, 0, 1), 900);
      expect(b.samples, hasLength(3));
      b = pushSpeedSample(b, const SpeedSample(15000, 0, 1), 900);
      expect(smoothedSpeed(b)!.speed, 0);
      expect(
        smoothedSpeed(
          pushSpeedSample(b, const SpeedSample(20000, null, null), 900),
        ),
        isNull,
      );
      final gap = pushSpeedSample(b, const SpeedSample(60000, 20, 1), 900);
      expect(gap.samples, hasLength(1));
      final session = pushSpeedSample(b, const SpeedSample(20000, 20, 1), 901);
      expect(session.samples, hasLength(1));
      final two = pushSpeedSample(
        session,
        const SpeedSample(25000, 10, 7),
        901,
      );
      expect(smoothedSpeed(two)!.speed, 15);
      expect(smoothedSpeed(two)!.rough, isTrue);
    },
  );
  test(
    'summary: no meeting null, none sharing, A of N with next soonest, everyone arrived, offline counted but not arrived',
    () {
      final arrived = classifyEta(distanceM: 50, speedMps: 0, live: true);
      final soon = classifyEta(distanceM: 3000, speedMps: 13.89, live: true);
      final later = classifyEta(distanceM: 9000, speedMps: 13.89, live: true);
      final offline = classifyEta(distanceM: 9000, speedMps: 10, live: false);
      expect(etaSummary([('Me', arrived)], hasMeeting: false), isNull);
      expect(etaSummary([], hasMeeting: true), 'No one is sharing a location');
      expect(
        etaSummary([
          ('Me', arrived),
          ('Ada', soon),
          ('Bo', later),
          ('Cy', offline),
        ], hasMeeting: true),
        '1 of 4 arrived • next: Ada ~5 min',
      );
      expect(
        etaSummary([('Me', arrived), ('Cy', offline)], hasMeeting: true),
        '1 of 2 arrived',
      );
      expect(
        etaSummary([('Me', arrived), ('Ada', arrived)], hasMeeting: true),
        'Everyone arrived',
      );
    },
  );
  test(
    'unknown speed followed by a real reading starts a fresh buffer without crashing',
    () {
      var b = pushSpeedSample(null, const SpeedSample(1000, null, null), 9);
      expect(smoothedSpeed(b), isNull);
      b = pushSpeedSample(b, const SpeedSample(5000, 3, 1), 9);
      expect(b.samples, hasLength(1));
      expect(smoothedSpeed(b)!.speed, 3);
    },
  );
}
