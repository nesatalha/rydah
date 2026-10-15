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
  test(
    'group refresh sends trailSince cursors and merges incremental trails',
    () async {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000);
      final a = DeviceAccount(
        'https://friends.example',
        'me',
        'secret',
        enrolled: true,
      );
      final queries = <String?>[];
      var call = 0;
      Map<String, dynamic> member(
        Map<String, dynamic>? trail, {
        bool sharing = true,
      }) => {
        'deviceId': 'peer',
        'name': 'Ada',
        'avatarVersion': null,
        'sharing': sharing
            ? {
                'state': 'live',
                'expiresAt': 1100000,
                'location': {
                  'lat': 41.3,
                  'lon': 29,
                  'observedAt': 995000,
                  'receivedAt': 995000,
                  'accuracyM': 5,
                },
                'trail': trail,
              }
            : null,
      };
      final responses = [
        member({
          'setting': 'session',
          'windowStartsAt': null,
          'reset': true,
          'points': [
            [1, 41.1, 29, 980000],
            [2, 41.2, 29, 990000],
          ],
        }),
        member({
          'setting': 'session',
          'windowStartsAt': null,
          'reset': false,
          'points': [
            [3, 41.25, 29, 994000],
          ],
        }),
        member(null, sharing: false),
      ];
      await http.runWithClient(
        () async {
          final c = GroupController(GroupApi(a), now: () => now);
          await c.refresh();
          expect(queries.last, '');
          expect(c.trails['peer']!.points.map((p) => p.seq), [1, 2]);
          await c.refresh();
          expect(queries.last, 'peer:1100000:2');
          expect(c.trails['peer']!.points.map((p) => p.seq), [1, 2, 3]);
          expect(c.visibleTrail(c.members.first), hasLength(3));
          await c.refresh();
          expect(c.trails, isEmpty);
          c.dispose();
        },
        () => MockClient((r) async {
          queries.add(r.url.queryParameters['trailSince']);
          return http.Response(
            jsonEncode({
              'id': 'group',
              'name': 'Friends',
              'role': 'member',
              'members': [responses[call++]],
            }),
            200,
          );
        }),
      );
    },
  );
  test('member who loses membership drops trail', () async {
    final a = DeviceAccount(
      'https://friends.example',
      'me',
      'secret',
      enrolled: true,
    );
    var mode = 0;
    await http.runWithClient(
      () async {
        final c = GroupController(
          GroupApi(a),
          now: () => DateTime.fromMillisecondsSinceEpoch(1000000),
        );
        await c.refresh();
        expect(c.trails, isNotEmpty);
        mode = 1;
        await c.refresh();
        expect(c.trails, isEmpty);
        c.dispose();
      },
      () => MockClient((r) async {
        if (mode == 1) return http.Response('{"error":"Forbidden"}', 403);
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
                    'observedAt': 995000,
                    'receivedAt': 995000,
                    'accuracyM': 5,
                  },
                  'trail': {
                    'setting': '15m',
                    'windowStartsAt': 100000,
                    'reset': true,
                    'points': [
                      [1, 40.9, 29, 990000],
                    ],
                  },
                },
              },
            ],
          }),
          200,
        );
      }),
    );
  });
  test(
    'group refresh smooths member speed across polls, computes ETA to the meeting point and drops speed when member stops sharing',
    () async {
      var now = DateTime.fromMillisecondsSinceEpoch(1000000);
      final a = DeviceAccount(
        'https://friends.example',
        'me',
        'secret',
        enrolled: true,
      );
      final speeds = <double?>[13.89, 13.89, 0, null];
      var call = 0;
      await http.runWithClient(
        () async {
          final c = GroupController(GroupApi(a), now: () => now);
          for (var i = 0; i < 3; i++) {
            await c.refresh();
            now = now.add(const Duration(seconds: 5));
          }
          final eta = c.memberEta(c.members.first)!;
          expect(eta.kind.name, 'moving');
          expect(c.etaSummary, '0 of 1 arrived • next: Ada ~12 min');
          await c.refresh();
          expect(c.memberEta(c.members.first)!.kind.name, 'distanceOnly');
          c.dispose();
        },
        () => MockClient((r) async {
          final i = call++;
          final at = 1000000 + i * 5000;
          return http.Response(
            jsonEncode({
              'id': 'group',
              'name': 'Friends',
              'role': 'member',
              'meetingPoint': {
                'lat': 41.0,
                'lon': 29.0,
                'label': 'Cafe',
                'updatedAt': 1,
                'updatedBy': 'me',
              },
              'members': [
                {
                  'deviceId': 'peer',
                  'name': 'Ada',
                  'avatarVersion': null,
                  'sharing': {
                    'state': 'live',
                    'expiresAt': 2000000,
                    'location': {
                      'lat': 41.0 + 8000 / 111195,
                      'lon': 29.0,
                      'accuracyM': 5,
                      'speedMps': speeds[i],
                      'speedAccuracyMps': speeds[i] == null ? null : 1,
                      'observedAt': at,
                      'receivedAt': at,
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
