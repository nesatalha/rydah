import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/share_duration_dialog.dart';

void main() {
  Future<void> openPicker(
    WidgetTester tester,
    ValueChanged<int?> onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onResult(await showShareDurationDialog(context));
              },
              child: const Text('Choose duration'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose duration'));
    await tester.pumpAndSettle();
  }

  for (final preset in {
    '15 minutes': 15,
    '30 minutes': 30,
    '1 hour': 60,
    '2 hours': 120,
  }.entries) {
    testWidgets('returns ${preset.value} minutes after confirmation', (
      tester,
    ) async {
      int? result;
      var completed = false;
      await openPicker(tester, (value) {
        completed = true;
        result = value;
      });
      for (final label in [
        '15 minutes',
        '30 minutes',
        '1 hour',
        '2 hours',
        'Custom',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.text(preset.key));
      await tester.pump();
      expect(completed, isFalse);
      await tester.tap(find.text('Start sharing'));
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(result, preset.value);
    });
  }

  for (final input in ['1', '720', ' 45 ', '0015']) {
    testWidgets('returns valid custom minutes "$input"', (tester) async {
      int? result;
      await openPicker(tester, (value) => result = value);
      await tester.tap(find.text('Custom'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), input);
      await tester.tap(find.text('Start sharing'));
      await tester.pumpAndSettle();
      expect(result, int.parse(input.trim()));
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  for (final input in [
    '',
    '   ',
    '+15',
    '-1',
    '1.5',
    '1e2',
    '0x10',
    '0',
    '721',
    '12 3',
    '99999999999999999999999999999',
  ]) {
    testWidgets('keeps invalid custom minutes "$input" open', (tester) async {
      var completed = false;
      await openPicker(tester, (_) => completed = true);
      await tester.tap(find.text('Custom'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), input);
      await tester.tap(find.text('Start sharing'));
      await tester.pumpAndSettle();
      expect(completed, isFalse);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Enter whole minutes from 1 to 720.'), findsOneWidget);
    });
  }

  for (final dismissal in ['Cancel', 'back', 'barrier']) {
    testWidgets('$dismissal returns null', (tester) async {
      int? result = 123;
      var completed = false;
      await openPicker(tester, (value) {
        completed = true;
        result = value;
      });
      if (dismissal == 'Cancel') {
        await tester.tap(find.text('Cancel'));
      } else if (dismissal == 'back') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tapAt(const Offset(5, 5));
      }
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(result, isNull);
    });
  }

  testWidgets('custom input stays usable on a small screen with keyboard', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await openPicker(tester, (_) {});
    await tester.ensureVisible(find.text('Custom'));
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '45');
    await tester.ensureVisible(find.text('Start sharing'));
    await tester.tap(find.text('Start sharing'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
