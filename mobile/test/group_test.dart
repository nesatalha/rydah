import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/account_store.dart';
import 'package:mobile/group_api.dart';
import 'package:mobile/group_controller.dart';

void main() {
  test('invitation link chooses its own normalized origin', () {
    final invite = Invitation.parse(
      'https://FRIENDS.example/join.html#token=${'a' * 64}',
      'https://old.example',
    );
    expect(invite.origin, 'https://friends.example');
    expect(invite.token, 'a' * 64);
    expect(
      () => Invitation.parse(
        'https://evil.example/wrong#${'a' * 64}',
        'https://old.example',
      ),
      throwsFormatException,
    );
  });
  test(
    'enrollment and group session send persisted identity and request',
    () async {
      final a = DeviceAccount(
        'https://friends.example',
        'device',
        'device-token',
      );
      final requests = <http.Request>[];
      await http.runWithClient(
        () async {
          final api = GroupApi(a);
          await api.enroll('invite', 'Ada');
          await api.createSession({
            'id': 'session',
            'readToken': 'read',
            'writeToken': 'write',
            'audience': 'group',
            'durationMinutes': 60,
          });
        },
        () => MockClient((r) async {
          requests.add(r);
          return http.Response(
            r.url.path == '/api/enroll'
                ? '{}'
                : '{"id":"session","readToken":"read","writeToken":"write","expiresAt":2000000000000}',
            201,
          );
        }),
      );
      expect(requests.first.headers['Authorization'], 'Bearer invite');
      expect(jsonDecode(requests.first.body), {
        'deviceId': 'device',
        'deviceToken': 'device-token',
        'name': 'Ada',
      });
      expect(requests.last.headers['Authorization'], 'Bearer device-token');
      expect(jsonDecode(requests.last.body)['durationMinutes'], 60);
    },
  );
  test(
    'group refresh retains offline roster but drops expired fixes and clears auth loss',
    () async {
      var now = DateTime.fromMillisecondsSinceEpoch(1000000);
      var mode = 0;
      final a = DeviceAccount(
        'https://friends.example',
        'me',
        'secret',
        enrolled: true,
      );
      await http.runWithClient(
        () async {
          final c = GroupController(GroupApi(a), now: () => now);
          await c.refresh();
          expect(c.members, hasLength(1));
          expect(c.visibleLocation(c.members.first), isNotNull);
          now = now.add(const Duration(minutes: 3));
          mode = 1;
          await c.refresh();
          expect(c.members, hasLength(1));
          expect(c.error, contains('offline'));
          expect(c.visibleLocation(c.members.first), isNull);
          mode = 2;
          await c.refresh();
          expect(c.members, isEmpty);
          expect(c.photos, isEmpty);
          c.dispose();
        },
        () => MockClient((r) async {
          if (mode == 1) throw Exception('offline');
          if (mode == 2) return http.Response('{"error":"Unauthorized"}', 401);
          return http.Response(
            jsonEncode({
              'id': 'group',
              'name': 'Friends',
              'role': 'member',
              'members': [
                {
                  'deviceId': 'peer',
                  'name': 'Ada',
                  'avatarVersion': null,
                  'sharing': {
                    'state': 'live',
                    'expiresAt': 1100000,
                    'location': {
                      'lat': 41,
                      'lon': 29,
                      'receivedAt': 1000000,
                      'observedAt': 1000000,
                      'accuracyM': 5,
                    },
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
    },
  );
}
