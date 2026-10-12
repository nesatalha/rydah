import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.url,
    required this.secret,
    required this.sharingActive,
  });
  final TextEditingController url, secret;
  final bool sharingActive;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        'Your device, your rides',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 12),
      const Text(
        'Rides and routes are stored locally in SQLite. Uninstalling the app clears them. Export GPX files to keep your rides elsewhere.',
      ),
      const SizedBox(height: 20),
      const Text(
        'Keep the app open while recording or sharing. Permissions, battery controls, backgrounding and loss of GPS can interrupt updates. GPS distance is an estimate; gaps form separate track segments.',
      ),
      const SizedBox(height: 20),
      const Text(
        'Map tiles require internet. Saved coordinates and geometry remain available offline. Draft routes connect stops with straight lines; they are not road directions or navigation.',
      ),
      const SizedBox(height: 24),
      Text(
        'Private sharing connection',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      TextField(
        controller: url,
        enabled: !sharingActive,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: 'Backend URL'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: secret,
        enabled: !sharingActive,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Creator key'),
      ),
      const SizedBox(height: 10),
      const Text(
        'The prefilled key is for local development only. This key stays in memory. Emulator links use localhost on your computer.',
      ),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        onPressed: Geolocator.openLocationSettings,
        icon: const Icon(Icons.location_on_outlined),
        label: const Text('Location settings'),
      ),
      OutlinedButton.icon(
        onPressed: Geolocator.openAppSettings,
        icon: const Icon(Icons.settings_outlined),
        label: const Text('App permissions'),
      ),
    ],
  );
}
