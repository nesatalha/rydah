import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'group_controller.dart';
import 'person_avatar.dart';
import 'trail.dart';
import 'meeting_eta.dart' show etaLabel;
import 'ui_helpers.dart';

class GroupScreen extends StatefulWidget {
  const GroupScreen({
    super.key,
    required this.controller,
    required this.onMembershipChanged,
    this.showTiles = true,
  });
  final GroupController controller;
  final Future<void> Function() onMembershipChanged;
  final bool showTiles;
  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  final map = MapController();
  final label = TextEditingController();
  LatLng? selected;
  GroupController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.addListener(refresh);
  }

  @override
  void didUpdateWidget(covariant GroupScreen old) {
    super.didUpdateWidget(old);
    if (old.controller != c) {
      old.controller.removeListener(refresh);
      c.addListener(refresh);
      selected = null;
    }
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
      await c.refresh();
    } catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  Future<bool> confirm(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: const Text('This takes effect immediately for the group.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> invites() async {
    await run(() async {
      final list = await c.api.invitations();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Group invitations'),
          content: SizedBox(
            width: 400,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final i in list)
                  ListTile(
                    title: Text(i['id']),
                    subtitle: Text(
                      i['revokedAt'] != null
                          ? 'Revoked'
                          : i['consumedAt'] != null
                          ? 'Used'
                          : 'Expires ${DateTime.fromMillisecondsSinceEpoch(i['expiresAt']).toLocal()}',
                    ),
                    trailing: i['revokedAt'] == null && i['consumedAt'] == null
                        ? IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              if (await confirm('Revoke this invitation?')) {
                                await run(() => c.api.revoke(i['id']));
                                if (ctx.mounted) Navigator.pop(ctx);
                              }
                            },
                          )
                        : null,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    });
  }

  /// ETA label for a member, or null without a meeting point or location.
  String? _eta(Map<String, dynamic> m) {
    final eta = c.memberEta(m);
    return eta == null ? null : etaLabel(eta);
  }

  List<TrailSegment> _trail(Map<String, dynamic> m) {
    final points = c.visibleTrail(m);
    if (points.isEmpty) return const [];
    final l = c.visibleLocation(m)!;
    return fadeSegments(
      points,
      setting: c.trails[m['deviceId']]!.setting,
      now: c.now().millisecondsSinceEpoch,
      current: TrailPoint(
        0,
        (l['lat'] as num).toDouble(),
        (l['lon'] as num).toDouble(),
        (l['observedAt'] as num).toInt(),
      ),
    );
  }

  void fit() {
    final points = <LatLng>[];
    for (final m in c.members) {
      final l = c.visibleLocation(m);
      if (l != null) {
        points.add(
          LatLng((l['lat'] as num).toDouble(), (l['lon'] as num).toDouble()),
        );
      }
    }
    final meeting = c.snapshot?['meetingPoint'] as Map?;
    if (meeting != null) {
      points.add(
        LatLng(
          (meeting['lat'] as num).toDouble(),
          (meeting['lon'] as num).toDouble(),
        ),
      );
    }
    if (points.isEmpty) return;
    if (points.length == 1) {
      map.move(points.first, 15);
    } else {
      map.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.all(40),
        ),
      );
    }
  }

  @override
  void dispose() {
    c.removeListener(refresh);
    map.dispose();
    label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = c.snapshot;
    final owner = snapshot?['role'] == 'owner';
    final meeting = snapshot?['meetingPoint'] as Map?;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          snapshot?['name'] ?? 'Your riding group',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        Text('Role: ${snapshot?['role'] ?? 'not enrolled'}'),
        if (c.error != null) Text('Offline / refresh failed: ${c.error}'),
        Text(
          c.lastRefresh == null
              ? 'No group refresh yet'
              : 'Last refresh: ${c.lastRefresh!.toLocal()}',
        ),
        TextButton.icon(
          onPressed: () => run(c.refresh),
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh group'),
        ),
        if (snapshot == null)
          const Text(
            'Join an invitation in Settings. Joining never enables location sharing.',
          ),
        if (c.etaSummary case final summary?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              summary,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        SizedBox(
          height: 300,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: FlutterMap(
              mapController: map,
              options: MapOptions(
                initialCenter: const LatLng(41.0082, 28.9784),
                initialZoom: 10,
                onTap: snapshot == null
                    ? null
                    : (_, point) => setState(() => selected = point),
              ),
              children: [
                if (widget.showTiles)
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'app.rydah.mobile',
                  ),
                PolylineLayer(
                  polylines: [
                    for (final m in c.members)
                      for (final s in _trail(m))
                        Polyline(
                          points: s.points,
                          strokeWidth: 4,
                          color:
                              (c.error == null
                                      ? const Color(0xff0f766e)
                                      : Colors.orange)
                                  .withValues(alpha: s.opacity),
                        ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    for (final m in c.members)
                      if (c.visibleLocation(m) != null)
                        Marker(
                          point: LatLng(
                            (c.visibleLocation(m)!['lat'] as num).toDouble(),
                            (c.visibleLocation(m)!['lon'] as num).toDouble(),
                          ),
                          width: 54,
                          height: 54,
                          child: Tooltip(
                            message: _eta(m) != null
                                ? '${m['name']} • ${_eta(m)}'
                                : '${m['name']}${c.error == null ? '' : ' — last known, offline'}',
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: c.error == null
                                      ? const Color(0xff63e3c4)
                                      : Colors.orange,
                                  width: 3,
                                ),
                              ),
                              child: PersonAvatar(
                                name: m['name'],
                                photo: c.photos[m['deviceId']],
                              ),
                            ),
                          ),
                        ),
                    if (meeting != null)
                      Marker(
                        point: LatLng(
                          (meeting['lat'] as num).toDouble(),
                          (meeting['lon'] as num).toDouble(),
                        ),
                        child: Tooltip(
                          message: meeting['label'],
                          child: const Icon(
                            Icons.flag,
                            color: Colors.amber,
                            size: 38,
                          ),
                        ),
                      ),
                    if (selected != null)
                      Marker(
                        point: selected!,
                        child: const Icon(
                          Icons.add_location_alt,
                          color: Colors.orange,
                          size: 38,
                        ),
                      ),
                  ],
                ),
                const Positioned(
                  bottom: 4,
                  right: 4,
                  child: Text(
                    '© OpenStreetMap contributors',
                    style: TextStyle(fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
        ),
        TextButton.icon(
          onPressed: fit,
          icon: const Icon(Icons.center_focus_strong),
          label: const Text('Fit group / recenter'),
        ),
        if (snapshot != null) ...[
          const Text('Tap the map to choose a shared meeting point.'),
          if (meeting != null) Text('Meeting point: ${meeting['label']}'),
          if (selected != null) ...[
            TextField(
              controller: label,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: 'Meeting point label',
              ),
            ),
            FilledButton(
              onPressed: () => run(() async {
                await c.api.meeting({
                  'lat': selected!.latitude,
                  'lon': selected!.longitude,
                  'label': label.text,
                });
                setState(() => selected = null);
              }),
              child: const Text('Save meeting point'),
            ),
          ],
          if (meeting != null)
            TextButton(
              onPressed: () => run(() => c.api.meeting(null)),
              child: const Text('Remove meeting point'),
            ),
        ],
        for (final m in c.members)
          ListTile(
            leading: PersonAvatar(
              name: m['name'],
              photo: c.photos[m['deviceId']],
            ),
            title: Text(m['name']),
            subtitle: Text(
              '${m['deviceId'] == c.api.account.deviceId ? (snapshot?['role']) : 'friend'} • ${c.visibleLocation(m) == null ? 'Not sharing / location unavailable' : _eta(m) ?? (c.error == null ? 'Sharing' : 'Last known — offline')}',
            ),
            trailing: owner && m['deviceId'] != c.api.account.deviceId
                ? IconButton(
                    icon: const Icon(Icons.person_remove),
                    tooltip: 'Remove member',
                    onPressed: () => run(() async {
                      if (await confirm('Remove ${m['name']}?')) {
                        await c.api.remove(m['deviceId']);
                      }
                    }),
                  )
                : null,
          ),
        if (owner) ...[
          FilledButton.icon(
            onPressed: () => run(() async {
              final messenger = ScaffoldMessenger.of(context);
              final invite = await c.api.invite();
              await Clipboard.setData(ClipboardData(text: invite['joinUrl']));
              if (mounted) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('New invitation copied — valid for 24 hours'),
                  ),
                );
              }
            }),
            icon: const Icon(Icons.person_add),
            label: const Text('Create and copy invitation'),
          ),
          TextButton(
            onPressed: invites,
            child: const Text('Manage invitations'),
          ),
        ],
        if (snapshot != null)
          TextButton(
            onPressed: () => run(() async {
              if (!await confirm(
                owner ? 'Delete the group?' : 'Leave the group?',
              )) {
                return;
              }
              await c.api.leave(owner: owner);
              c.clear();
              await widget.onMembershipChanged();
            }),
            child: Text(owner ? 'Delete group' : 'Leave group'),
          ),
      ],
    );
  }
}
