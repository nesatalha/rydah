import 'package:flutter/material.dart';

class ShareOptions {
  const ShareOptions(this.audience, this.minutes, this.trail);
  final String audience;
  final int minutes;
  final String trail;
}

/// Asks for audience, duration and trail. Returns null when cancelled.
Future<ShareOptions?> showShareOptions(
  BuildContext context, {
  required bool inGroup,
}) {
  var audience = 'viewer';
  var minutes = 60;
  var trail = 'off';
  return showDialog<ShareOptions>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('Start location sharing'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: audience,
                decoration: const InputDecoration(labelText: 'Audience'),
                items: [
                  const DropdownMenuItem(
                    value: 'viewer',
                    child: Text('Private link'),
                  ),
                  if (inGroup)
                    const DropdownMenuItem(
                      value: 'group',
                      child: Text('Group + private link'),
                    ),
                ],
                onChanged: (v) => update(() => audience = v!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: minutes,
                decoration: const InputDecoration(labelText: 'Duration'),
                items: const [
                  DropdownMenuItem(value: 30, child: Text('30 minutes')),
                  DropdownMenuItem(value: 60, child: Text('1 hour')),
                  DropdownMenuItem(value: 120, child: Text('2 hours')),
                  DropdownMenuItem(value: 240, child: Text('4 hours')),
                ],
                onChanged: (v) => update(() => minutes = v!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: trail,
                decoration: const InputDecoration(labelText: 'Trail'),
                items: const [
                  DropdownMenuItem(value: 'off', child: Text('Off')),
                  DropdownMenuItem(
                    value: '15m',
                    child: Text('Last 15 minutes'),
                  ),
                  DropdownMenuItem(
                    value: '30m',
                    child: Text('Last 30 minutes'),
                  ),
                  DropdownMenuItem(
                    value: 'session',
                    child: Text('Whole session'),
                  ),
                ],
                onChanged: (v) => update(() => trail = v!),
              ),
              const SizedBox(height: 12),
              const Text(
                'This explicitly starts GPS updates for the chosen audience. A trail shows them your recent path while sharing. Recording remains independent.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, ShareOptions(audience, minutes, trail)),
            child: const Text('Start sharing'),
          ),
        ],
      ),
    ),
  );
}
