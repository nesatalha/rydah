import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/account_store.dart';
import 'package:mobile/group_api.dart';
import 'package:mobile/location_sender.dart';
import 'package:mobile/sharing_api.dart';
import 'account_test.dart' show MemorySecrets;

class DurableApi extends GroupApi {
  DurableApi(super.account, this.store);
  final AccountStore store;
  int creates = 0, stops = 0, uploads = 0;
  final inputs = <Map<String, dynamic>>[];
  bool lose = true, failStop = false;
  @override
  Future<ShareSession> createSession(Map<String, dynamic> input) async {
    creates++;
    inputs.add(input);
    final saved = await store.load(account.origin);
    expect(saved.pending!['id'], input['id']);
    if (lose) throw Exception('lost response');
    return ShareSession(
      input['id'],
      input['writeToken'],
      input['readToken'],
      DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<void> stop(ShareSession s) async {
    stops++;
    expect((await store.load(account.origin)).pending!['stop'], true);
    if (failStop) throw Exception('offline');
  }

  @override
  Future<void> upload(ShareSession s, int seq, GeoPoint p) async {
    uploads++;
    expect((await store.load(account.origin)).pending!['expiresAt'], isNotNull);
  }
}

void main() {
  test(
    'lost create replay after restart stops original id without GPS or uploads',
    () async {
      final store = AccountStore(MemorySecrets());
      final a = await store.load('https://friends.example');
      final api = DurableApi(a, store);
      final sender = LocationSender(
        api: api,
        accountStore: store,
        prepare: () async {},
        points: () => const Stream.empty(),
      );
      await sender.start();
      final id = a.pending!['id'];
      expect(sender.state, contains('lost response'));
      expect(sender.hasPending, true);
      sender.dispose();
      await Future<void>.delayed(Duration.zero);
      api.lose = false;
      final restored = await store.load(a.origin);
      final nextApi = DurableApi(restored, store)..lose = false;
      var gps = 0;
      final next = LocationSender(
        api: nextApi,
        accountStore: store,
        prepare: () async {
          gps++;
        },
        points: () => throw StateError('no GPS'),
      );
      await next.recover();
      expect(nextApi.creates, 1);
      expect(nextApi.stops, 1);
      expect(nextApi.uploads, 0);
      expect(gps, 0);
      expect(restored.pending, isNull);
      expect(id, isNotNull);
      next.dispose();
    },
  );
  test('failed stop persists pending state and blocks starts', () async {
    final store = AccountStore(MemorySecrets());
    final a = await store.load('https://friends.example');
    final api = DurableApi(a, store)
      ..lose = false
      ..failStop = true;
    final sender = LocationSender(
      api: api,
      accountStore: store,
      prepare: () async {},
      points: () => const Stream.empty(),
    );
    await sender.start();
    await sender.stop();
    await sender.start();
    expect(api.creates, 1);
    expect(a.pending!['stop'], true);
    expect(sender.sharing, false);
    expect(sender.hasPending, true);
    api.failStop = false;
    await sender.stop();
    expect(a.pending, isNull);
    sender.dispose();
  });
  test('pending record persists trail and createSession sends it', () async {
    final store = AccountStore(MemorySecrets());
    final a = await store.load('https://friends.example');
    final api = DurableApi(a, store)..lose = false;
    final sender = LocationSender(
      api: api,
      accountStore: store,
      prepare: () async {},
      points: () => const Stream.empty(),
    )..trail = 'session';
    await sender.start();
    expect(api.inputs.single['trail'], 'session');
    expect((await store.load(a.origin)).pending!['trail'], 'session');
    await sender.stop();
    sender.dispose();
  });
  test('legacy pending without trail recovers without sending trail', () async {
    final store = AccountStore(MemorySecrets());
    final a = await store.load('https://friends.example');
    a.pending = {
      'id': 'legacy',
      'readToken': 'r' * 64,
      'writeToken': 'w' * 64,
      'audience': 'viewer',
      'durationMinutes': 60,
      'backend': a.origin,
      'stop': false,
    };
    await store.save(a);
    final api = DurableApi(a, store)..lose = false;
    final sender = LocationSender(
      api: api,
      accountStore: store,
      prepare: () async {},
      points: () => const Stream.empty(),
    );
    await sender.recover();
    expect(api.inputs.single.containsKey('trail'), isFalse);
    expect(api.stops, 1);
    sender.dispose();
  });
}
