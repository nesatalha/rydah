import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile/trail.dart';

Map<String, dynamic> json(
  List<List<num>> points, {
  bool reset = true,
  String setting = 'session',
  int? windowStartsAt,
}) => {
  'setting': setting,
  'windowStartsAt': windowStartsAt,
  'reset': reset,
  'points': points,
};

void main() {
  test(
    'mergeTrail appends only newer seq, replaces on reset or expiresAt change, drops points before windowStartsAt',
    () {
      var t = mergeTrail(
        null,
        json([
          [1, 41, 29, 1000],
          [2, 41.1, 29, 2000],
        ]),
        9000,
      )!;
      expect(t.maxSeq, 2);
      t = mergeTrail(
        t,
        json(
          [
            [2, 0, 0, 2000],
            [3, 41.2, 29, 3000],
          ],
          reset: false,
          setting: '15m',
          windowStartsAt: 1500,
        ),
        9000,
      )!;
      expect(t.points.map((p) => p.seq), [2, 3]);
      expect(t.points.first.lat, 41.1);
      expect(t.setting, '15m');
      t = mergeTrail(
        t,
        json([
          [7, 40, 29, 4000],
        ], reset: false),
        9999,
      )!;
      expect(t.points.map((p) => p.seq), [7]);
      expect(t.expiresAt, 9999);
      t = mergeTrail(
        t,
        json([
          [1, 39, 29, 5000],
        ]),
        9999,
      )!;
      expect(t.points.map((p) => p.seq), [1]);
      expect(mergeTrail(t, null, 9999), isNull);
    },
  );
  test(
    'fadeSegments buckets by age, splits gaps over 60 s, last segment ends at the current fix',
    () {
      final now = 1000000;
      final points = [
        for (final (seq, at) in [
          (1, now - 400000),
          (2, now - 390000),
          (3, now - 40000),
          (4, now - 30000),
          (5, now - 20000),
        ])
          TrailPoint(seq, 41 + seq / 100, 29, at),
      ];
      final segments = fadeSegments(
        points,
        setting: 'session',
        now: now,
        current: TrailPoint(0, 42, 30, now - 5000),
      );
      expect(segments, isNotEmpty);
      expect(segments.last.points.last, const LatLng(42, 30));
      final joined = segments.any(
        (s) =>
            s.points.contains(const LatLng(41.02, 29)) &&
            s.points.contains(const LatLng(41.03, 29)),
      );
      expect(joined, isFalse);
      expect(segments.first.opacity, lessThan(segments.last.opacity));
      expect(fadeSegments(const [], setting: '15m', now: now), isEmpty);
    },
  );
}
