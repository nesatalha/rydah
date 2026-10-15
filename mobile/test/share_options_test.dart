import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/share_options_dialog.dart';

void main() {
  testWidgets(
    'share dialog offers Trail Off/15 min/30 min/Whole session, default Off',
    (tester) async {
      ShareOptions? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showShareOptions(context, inGroup: true),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Trail'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      for (final label in [
        'Last 15 minutes',
        'Last 30 minutes',
        'Whole session',
      ]) {
        expect(find.text(label), findsWidgets);
      }
      await tester.tap(find.text('Whole session').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start sharing'));
      await tester.pumpAndSettle();
      expect(result?.trail, 'session');
      expect(result?.audience, 'viewer');
      expect(result?.minutes, 60);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start sharing'));
      await tester.pumpAndSettle();
      expect(result?.trail, 'off');

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );
}
