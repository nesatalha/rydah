import 'package:flutter/material.dart';

Future<void> showError(BuildContext context, Object error) async {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))),
    );
  }
}

Future<bool> confirmDelete(BuildContext context, String name) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text('This removes the saved data from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;
Future<String?> askName(BuildContext context, String current) async {
  final input = TextEditingController(text: current);
  final result = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Rename ride'),
      content: TextField(controller: input, autofocus: true, maxLength: 100),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (input.text.trim().isNotEmpty) {
              Navigator.pop(c, input.text.trim());
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  input.dispose();
  return result;
}
