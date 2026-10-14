import 'package:flutter/material.dart';

Future<int?> showShareDurationDialog(BuildContext context) => showDialog<int>(
  context: context,
  builder: (_) => const _ShareDurationDialog(),
);

class _ShareDurationDialog extends StatefulWidget {
  const _ShareDurationDialog();

  @override
  State<_ShareDurationDialog> createState() => _ShareDurationDialogState();
}

class _ShareDurationDialogState extends State<_ShareDurationDialog> {
  final customMinutes = TextEditingController();
  int? selectedMinutes = 60;
  String? error;

  void confirm() {
    var minutes = selectedMinutes;
    if (minutes == null) {
      final text = customMinutes.text.trim();
      minutes = RegExp(r'^[0-9]+$').hasMatch(text) ? int.tryParse(text) : null;
      if (minutes == null || minutes < 1 || minutes > 720) {
        setState(() => error = 'Enter whole minutes from 1 to 720.');
        return;
      }
    }
    Navigator.pop(context, minutes);
  }

  @override
  void dispose() {
    customMinutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Sharing duration'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('How long should your private link stay active?'),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in const {
              15: '15 minutes',
              30: '30 minutes',
              60: '1 hour',
              120: '2 hours',
            }.entries)
              ChoiceChip(
                label: Text(preset.value),
                selected: selectedMinutes == preset.key,
                onSelected: (_) => setState(() {
                  selectedMinutes = preset.key;
                  error = null;
                }),
              ),
            ChoiceChip(
              label: const Text('Custom'),
              selected: selectedMinutes == null,
              onSelected: (_) => setState(() => selectedMinutes = null),
            ),
          ],
        ),
        if (selectedMinutes == null) ...[
          const SizedBox(height: 16),
          TextField(
            controller: customMinutes,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Minutes',
              helperText: '1 to 720 minutes',
              errorText: error,
            ),
            onSubmitted: (_) => confirm(),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: confirm, child: const Text('Start sharing')),
    ],
  );
}
