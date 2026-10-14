import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/sharing_api.dart';

void main() {
  test('create sends the selected duration in the session request', () async {
    final requests = <http.Request>[];
    final expiresAt = DateTime.utc(2026, 10, 14, 12);

    await http.runWithClient(
      () async {
        final session = await SharingApi(
          'https://example.com',
          'key',
        ).create(durationMinutes: 30);

        expect(session.id, 'id');
        expect(session.writeToken, 'write');
        expect(session.readToken, 'read');
        expect(
          session.expiresAt.millisecondsSinceEpoch,
          expiresAt.millisecondsSinceEpoch,
        );
      },
      () => MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'id': 'id',
            'writeToken': 'write',
            'readToken': 'read',
            'expiresAt': expiresAt.millisecondsSinceEpoch,
          }),
          201,
        );
      }),
    );

    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.url.toString(), 'https://example.com/api/sessions');
    expect(requests.single.headers['Authorization'], 'Bearer key');
    expect(jsonDecode(requests.single.body), {
      'source': 'device',
      'durationMinutes': 30,
    });
  });
}
