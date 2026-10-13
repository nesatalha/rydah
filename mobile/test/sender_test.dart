import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/sharing_api.dart';
import 'package:mobile/location_sender.dart';

class FakeApi extends SharingApi {
  FakeApi() : super('http://localhost', 'key');
  final creation = Completer<ShareSession>();
  final uploadGate = Completer<void>();
  int uploads = 0;
  int stops = 0;
  int? durationMinutes;
  bool failStop = false;
  @override
  Future<ShareSession> create({required int durationMinutes}) {
    this.durationMinutes = durationMinutes;
    return creation.future;
  }

  @override
  Future<void> upload(ShareSession s, int seq, GeoPoint point) async {
    uploads++;
    await uploadGate.future;
  }

  @override
  Future<void> stop(ShareSession s) async {
    stops++;
    if (failStop) throw Exception('network');
  }
}

ShareSession get session => ShareSession(
  'id',
  'write',
  'read',
  DateTime.now().add(const Duration(hours: 1)),
);
void main() {
  test('start passes the selected duration to session creation', () async {
    final api = FakeApi();
    final sender = LocationSender(
      api: api,
      prepare: () async {},
      points: () => const Stream.empty(),
    );
    api.creation.complete(session);

    await sender.start(durationMinutes: 120);

    expect(api.durationMinutes, 120);
    sender.dispose();
  });

  test('stop during creation closes the newly created session', () async {
    final api = FakeApi();
    final points = StreamController<GeoPoint>.broadcast();
    final sender = LocationSender(
      api: api,
      prepare: () async {},
      points: () => points.stream,
    );
    final start = sender.start(durationMinutes: 60);
    await Future<void>.delayed(Duration.zero);
    final stop = sender.stop();
    api.creation.complete(session);
    await start;
    await stop;
    expect(api.stops, 1);
    expect(sender.state, 'Ended');
    sender.dispose();
    await points.close();
  });
  test(
    'only one upload runs and failed stop retains credentials for retry',
    () async {
      final api = FakeApi();
      final points = StreamController<GeoPoint>.broadcast();
      final sender = LocationSender(
        api: api,
        prepare: () async {},
        points: () => points.stream,
        cadence: const Duration(milliseconds: 10),
      );
      api.creation.complete(session);
      await sender.start(durationMinutes: 60);
      points.add(GeoPoint(41, 29, 10, DateTime.now()));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(api.uploads, 1);
      api.failStop = true;
      await sender.stop();
      expect(sender.state, 'Stop failed — retry');
      expect(sender.session, isNotNull);
      api.failStop = false;
      await sender.stop();
      expect(sender.session, isNull);
      expect(sender.state, 'Ended');
      api.uploadGate.complete();
      sender.dispose();
      await points.close();
    },
  );
  test('permission errors do not create a session', () async {
    final api = FakeApi();
    final sender = LocationSender(
      api: api,
      prepare: () async => throw Exception('Location permission denied'),
      points: () => const Stream.empty(),
    );
    await sender.start(durationMinutes: 60);
    expect(sender.state, contains('Location permission denied'));
    expect(sender.session, isNull);
    sender.dispose();
  });

  test('expiry without GPS releases the session', () async {
    final api = FakeApi();
    final sender = LocationSender(
      api: api,
      prepare: () async {},
      points: () => const Stream.empty(),
      cadence: const Duration(milliseconds: 5),
    );
    api.creation.complete(
      ShareSession(
        'expired',
        'write',
        'read',
        DateTime.now().subtract(const Duration(seconds: 1)),
      ),
    );
    await sender.start(durationMinutes: 60);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sender.session, isNull);
    expect(sender.sharing, isFalse);
    expect(sender.state, 'Expired — start a new share');
    expect(api.uploads, 0);
    sender.dispose();
  });
  test('expiry releases the session during an upload', () async {
    final api = FakeApi();
    final points = StreamController<GeoPoint>.broadcast();
    final sender = LocationSender(
      api: api,
      prepare: () async {},
      points: () => points.stream,
      cadence: const Duration(milliseconds: 5),
    );
    api.creation.complete(
      ShareSession(
        'soon',
        'write',
        'read',
        DateTime.now().add(const Duration(milliseconds: 50)),
      ),
    );
    await sender.start(durationMinutes: 60);
    points.add(GeoPoint(41, 29, 10, DateTime.now()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(api.uploads, 1);
    expect(sender.session, isNull);
    api.uploadGate.complete();
    sender.dispose();
    await points.close();
  });
  for (final operation in ['stop', 'upload']) {
    test('$operation HTTP 410 permits a new share', () async {
      var creations = 0;
      await http.runWithClient(
        () async {
          final sender = LocationSender(
            api: SharingApi('http://localhost', 'key'),
            prepare: () async {},
            points: () => operation == 'upload'
                ? Stream.value(GeoPoint(41, 29, 10, DateTime.now()))
                : const Stream.empty(),
            cadence: const Duration(hours: 1),
          );
          await sender.start(durationMinutes: 60);
          if (operation == 'stop') await sender.stop();
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(sender.session, isNull);
          expect(
            sender.state,
            operation == 'stop'
                ? 'Expired — start a new share'
                : 'Sharing ended or expired — start a new share',
          );
          await sender.start(durationMinutes: 60);
          expect(creations, 2);
          sender.dispose();
        },
        () => MockClient((request) async {
          if (request.method == 'POST') {
            creations++;
            return http.Response(
              '{"id":"id","writeToken":"write","readToken":"read",'
              '"expiresAt":${DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}}',
              201,
            );
          }
          return http.Response('{"error":"Sharing expired"}', 410);
        }),
      );
    });
  }

  for (final status in [401, 500]) {
    test('stop HTTP $status retains credentials for retry', () async {
      await http.runWithClient(
        () async {
          final sender = LocationSender(
            api: SharingApi('http://localhost', 'key'),
            prepare: () async {},
            points: () => const Stream.empty(),
          );
          await sender.start(durationMinutes: 60);
          await sender.stop();
          expect(sender.state, 'Stop failed — retry');
          expect(sender.session, isNotNull);
          sender.dispose();
        },
        () => MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response(
              '{"id":"id","writeToken":"write","readToken":"read",'
              '"expiresAt":${DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch}}',
              201,
            );
          }
          return http.Response('{"error":"Failure"}', status);
        }),
      );
    });
  }
  test(
    'stopping a locally expired session requires no network confirmation',
    () async {
      final api = FakeApi()..failStop = true;
      final sender = LocationSender(
        api: api,
        prepare: () async {},
        points: () => const Stream.empty(),
      );
      api.creation.complete(
        ShareSession(
          'expired',
          'write',
          'read',
          DateTime.now().subtract(const Duration(seconds: 1)),
        ),
      );
      await sender.start(durationMinutes: 60);
      await sender.stop();
      expect(sender.session, isNull);
      expect(sender.state, 'Expired — start a new share');
      expect(api.stops, 0);
      sender.dispose();
    },
  );
}
