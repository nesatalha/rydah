import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/account_controller.dart';
import 'package:mobile/account_store.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String key) async {
    if (fail) throw StateError('locked');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (fail) throw StateError('locked');
    values[key] = value;
  }
}

void main() {
  test('origin identities survive restart and never cross origins', () async {
    final secrets = MemorySecrets();
    final first = await AccountStore(secrets).load('HTTPS://Example.com:443/');
    final restored = await AccountStore(secrets).load('https://example.com');
    final other = await AccountStore(secrets).load('https://other.example');
    expect(restored.deviceId, first.deviceId);
    expect(restored.token, first.token);
    expect(first.token, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(other.token, isNot(first.token));
    secrets.fail = true;
    await expectLater(
      AccountStore(secrets).load('https://example.com'),
      throwsStateError,
    );
  });
  test('pending enrollment is durable before retry', () async {
    final store = AccountStore(MemorySecrets());
    final account = await store.load('http://localhost:8787');
    account.enrollment = {'token': 'invite', 'name': 'Original'};
    await store.save(account);
    expect((await store.load(account.origin)).enrollment, {
      'token': 'invite',
      'name': 'Original',
    });
  });
  test('remote HTTP and credential or path origins are rejected', () {
    for (final value in [
      'http://example.com',
      'https://user:pass@example.com',
      'https://example.com/api',
    ]) {
      expect(() => normalizeOrigin(value), throwsFormatException);
    }
    expect(normalizeOrigin('http://10.0.2.2:8787/'), 'http://10.0.2.2:8787');
  });
  test('profile validates trimmed name and retains pending sync', () async {
    final repository = MemoryProfileRepository();
    await repository.save(
      LocalProfile(' Ada ', Uint8List.fromList([1, 2]), true),
    );
    final profile = await repository.load();
    expect(profile!.name, 'Ada');
    expect(profile.dirty, true);
    expect(() => LocalProfile('  ', null, true), throwsFormatException);
    expect(() => LocalProfile('a' * 61, null, true), throwsFormatException);
  });
  test(
    'ended membership retires identity and next join uses a fresh one',
    () async {
      final secrets = MemorySecrets();
      final controller = AccountController(
        MemoryProfileRepository(),
        AccountStore(secrets),
      );
      await controller.load();
      final old = controller.account!..enrolled = true;
      await controller.membershipEnded();
      final saved = await AccountStore(secrets).load(old.origin);
      expect(saved.enrolled, false);
      expect(saved.retired, true);

      old.pending = {'id': 'share'};
      await expectLater(controller.prepareIdentity(), throwsStateError);
      expect(controller.account, same(old));

      old.pending = null;
      await controller.prepareIdentity();
      final next = controller.account!;
      expect(next.deviceId, isNot(old.deviceId));
      expect(next.token, isNot(old.token));
      expect(next.retired, false);
      expect(
        (await AccountStore(secrets).load(old.origin)).deviceId,
        next.deviceId,
      );
    },
  );
  test(
    'private sharing registers once without a group and syncs the profile',
    () async {
      final secrets = MemorySecrets();
      final profiles = MemoryProfileRepository();
      final controller = AccountController(profiles, AccountStore(secrets));
      final requests = <http.Request>[];
      await http.runWithClient(
        () async {
          await controller.load();
          await expectLater(controller.ensureRegistered(), throwsStateError);
          expect(requests, isEmpty);
          await controller.saveProfile('Ada', null);
          expect(requests, isEmpty);
          await controller.ensureRegistered();
          await controller.ensureRegistered();
        },
        () => MockClient((r) async {
          requests.add(r);
          return http.Response(r.method == 'DELETE' ? '' : '{}', 200);
        }),
      );
      final a = controller.account!;
      expect(requests.map((r) => '${r.method} ${r.url.path}'), [
        'POST /api/devices',
        'PUT /api/me',
        'DELETE /api/me/avatar',
      ]);
      expect(jsonDecode(requests.first.body), {
        'deviceId': a.deviceId,
        'deviceToken': a.token,
        'name': 'Ada',
      });
      expect(a.registered, true);
      expect(a.enrolled, false);
      expect((await AccountStore(secrets).load(a.origin)).registered, true);
      expect((await profiles.load())!.dirty, false);
    },
  );
  test('accounts enrolled before registration existed count as registered', () {
    final restored = DeviceAccount.fromJson({
      'origin': 'https://example.com',
      'deviceId': 'd',
      'token': 't',
      'enrolled': true,
    });
    expect(restored.registered, true);
  });
}
