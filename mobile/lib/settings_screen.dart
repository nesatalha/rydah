import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'account_controller.dart';
import 'group_api.dart';
import 'profile_photo.dart';
import 'ui_helpers.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.account,
    required this.sharingActive,
  });
  final AccountController account;
  final bool sharingActive;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final name = TextEditingController(),
      url = TextEditingController(),
      invite = TextEditingController(),
      group = TextEditingController(),
      creator = TextEditingController();
  Uint8List? photo;
  bool selecting = false;
  Invitation? preview;
  @override
  void initState() {
    super.initState();
    name.text = widget.account.profile?.name ?? '';
    photo = widget.account.profile?.photo;
    url.text =
        widget.account.account?.origin ?? AccountController.defaultBackend;
    widget.account.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) await showError(context, e);
    }
    refresh();
  }

  Future<void> pick() async {
    setState(() => selecting = true);
    try {
      final file = await FilePicker.pickFile(type: FileType.image);
      if (file == null) return;
      const maxBytes = 10 * 1024 * 1024;
      final size = await file.length();
      if (size != null && size > maxBytes) {
        throw const FormatException('Choose a photo smaller than 10 MB');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > maxBytes) {
        throw const FormatException('Choose a photo smaller than 10 MB');
      }
      final normalized = await normalizePhoto(bytes);
      if (mounted) setState(() => photo = normalized);
    } catch (e) {
      if (mounted) await showError(context, e);
    } finally {
      if (mounted) setState(() => selecting = false);
    }
  }

  @override
  void dispose() {
    widget.account.removeListener(refresh);
    for (final c in [name, url, invite, group, creator]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.account;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Your local profile',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const Text(
          'Choose your name and optional photo. Profile editing never starts GPS.',
        ),
        const SizedBox(height: 16),
        Center(
          child: CircleAvatar(
            radius: 42,
            backgroundImage: photo == null ? null : MemoryImage(photo!),
            child: photo == null ? const Icon(Icons.person, size: 42) : null,
          ),
        ),
        Wrap(
          spacing: 12,
          children: [
            TextButton.icon(
              onPressed: selecting ? null : pick,
              icon: const Icon(Icons.photo),
              label: const Text('Choose photo'),
            ),
            if (photo != null)
              TextButton(
                onPressed: () => setState(() => photo = null),
                child: const Text('Remove photo'),
              ),
          ],
        ),
        TextField(
          controller: name,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        FilledButton(
          onPressed: () => run(() => c.saveProfile(name.text, photo)),
          child: const Text('Save local profile'),
        ),
        if (c.profile?.dirty == true)
          const Text('Profile saved locally — sync pending'),
        if (c.error != null) Text(c.error!),
        if (c.profile?.dirty == true && c.account?.registered == true)
          TextButton(
            onPressed: () => run(c.sync),
            child: const Text('Retry profile sync'),
          ),
        const Divider(height: 32),
        Text(
          'Invite-only riding group',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text(
          c.account?.enrolled == true
              ? 'Device enrolled on ${c.account!.origin}'
              : 'Save your profile, then join with a friend’s invitation.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: invite,
          decoration: const InputDecoration(
            labelText: 'Invitation link or token',
          ),
          onChanged: (v) {
            setState(() {
              try {
                preview = Invitation.parse(v, c.account?.origin ?? url.text);
              } catch (_) {
                preview = null;
              }
            });
          },
        ),
        if (preview != null) Text('Invitation backend: ${preview!.origin}'),
        FilledButton(
          onPressed: c.busy || widget.sharingActive || preview == null
              ? null
              : () => run(
                  () => c.enroll(preview!, blocked: widget.sharingActive),
                ),
          child: const Text('Join group'),
        ),
        if (c.account?.enrollment != null)
          TextButton(
            onPressed: c.busy ? null : () => run(c.retryEnrollment),
            child: const Text('Retry enrollment'),
          ),
        const Divider(height: 32),
        Text(
          'Backend connection',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: url,
          enabled: !widget.sharingActive,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'Backend URL'),
        ),
        OutlinedButton(
          onPressed: widget.sharingActive
              ? null
              : () => run(
                  () => c.backend(url.text, blocked: widget.sharingActive),
                ),
          child: const Text('Save backend'),
        ),
        const Text(
          'Use HTTPS for a remote backend. Local USB testing can use http://localhost:8787 with adb reverse. Changing backend uses a separate device identity.',
        ),
        ExpansionTile(
          title: const Text('Developer: create a group'),
          children: [
            TextField(
              controller: group,
              decoration: const InputDecoration(labelText: 'Group name'),
            ),
            TextField(
              controller: creator,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Creator key'),
            ),
            TextButton(
              onPressed: widget.sharingActive
                  ? null
                  : () => run(() async {
                      await c.bootstrap(
                        group.text,
                        creator.text,
                        blocked: widget.sharingActive,
                      );
                      creator.clear();
                    }),
              child: const Text('Create group and enroll'),
            ),
          ],
        ),
        const Divider(height: 32),
        const Text(
          'Rides and routes stay in SQLite on this device. Export GPX to keep a copy. Uninstalling clears local rides, profile and device identity; ask the group owner to remove your old device and send a new invite.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Keep the app open while recording or sharing. Battery controls, backgrounding and lost GPS may interrupt updates. Map tiles need internet; saved coordinates remain available offline. Draft routes are straight lines, not road navigation.',
        ),
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
}
