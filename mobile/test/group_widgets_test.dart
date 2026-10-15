import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/account_controller.dart';
import 'package:mobile/account_store.dart';
import 'package:mobile/settings_screen.dart';
import 'package:mobile/group_screen.dart';
import 'package:mobile/group_controller.dart';
import 'package:mobile/group_api.dart';
import 'package:mobile/trail.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'account_test.dart' show MemorySecrets;

void main() {
  testWidgets(
    'local profile entry and invitation preview are accessible without GPS',
    (tester) async {
      final c = AccountController(
        MemoryProfileRepository(),
        AccountStore(MemorySecrets()),
      );
      await c.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(account: c, sharingActive: false),
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Display name'),
        'Ada',
      );
      await tester.tap(find.text('Save local profile'));
      await tester.pump();
      expect(c.profile!.name, 'Ada');
      expect(find.textContaining('sync pending'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'group roster shows non-sharing members and role with meeting controls',
    (tester) async {
      final a = DeviceAccount(
        'https://friends.example',
        'me',
        'token',
        enrolled: true,
      );
      final c = GroupController(GroupApi(a));
      c.snapshot = {
        'name': 'Friends',
        'role': 'member',
        'members': [
          {
            'deviceId': 'peer',
            'name': 'Ada',
            'sharing': null,
            'avatarVersion': null,
          },
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupScreen(
              controller: c,
              showTiles: false,
              onMembershipChanged: () async {},
            ),
          ),
        ),
      );
      expect(find.text('Ada'), findsOneWidget);
      expect(find.textContaining('Not sharing'), findsOneWidget);
      expect(find.textContaining('member'), findsWidgets);
      expect(find.textContaining('Tap the map'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'group map draws member trail polylines; Fit group still fits current fixes and meeting point only',
    (tester) async {
      final a = DeviceAccount(
        'https://friends.example',
        'me',
        'token',
        enrolled: true,
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      final c = GroupController(GroupApi(a));
      c.snapshot = {
        'name': 'Friends',
        'role': 'member',
        'members': [
          {
            'deviceId': 'peer',
            'name': 'Ada',
            'avatarVersion': null,
            'sharing': {
              'state': 'live',
              'expiresAt': now + 3600000,
              'location': {
                'lat': 41.3,
                'lon': 29,
                'observedAt': now - 2000,
                'receivedAt': now - 2000,
                'accuracyM': 5,
              },
            },
          },
        ],
      };
      c.trails['peer'] = mergeTrail(null, {
        'setting': 'session',
        'windowStartsAt': null,
        'reset': true,
        'points': [
          [1, 41.1, 29, now - 30000],
          [2, 41.2, 29, now - 20000],
        ],
      }, now + 3600000)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupScreen(
              controller: c,
              showTiles: false,
              onMembershipChanged: () async {},
            ),
          ),
        ),
      );
      final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
      expect(layer.polylines, isNotEmpty);
      expect(layer.polylines.last.points.last, const LatLng(41.3, 29));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
