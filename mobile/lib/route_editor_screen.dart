import 'package:flutter/material.dart';
import 'route_models.dart';
import 'track_map.dart';
import 'ride_metrics.dart';
import 'ui_helpers.dart';

class RouteEditorScreen extends StatefulWidget {
  const RouteEditorScreen({
    super.key,
    required this.route,
    required this.save,
    required this.close,
    this.showTiles = true,
  });
  final SavedRoute route;
  final Future<void> Function(SavedRoute) save;
  final VoidCallback close;
  final bool showTiles;
  @override
  State<RouteEditorScreen> createState() => _RouteEditorScreenState();
}

class _RouteEditorScreenState extends State<RouteEditorScreen> {
  late final TextEditingController name = TextEditingController(
    text: widget.route.name,
  );
  late List<RoutePoint> stops = List.of(widget.route.stops),
      geometry = List.of(widget.route.geometry);
  late String kind = widget.route.kind;
  bool busy = false, changed = false;
  void editStops(VoidCallback edit) {
    setState(() {
      edit();
      geometry = List.of(stops.map((p) => RoutePoint(p.lat, p.lon)));
      kind = 'draft';
      changed = true;
    });
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var distance = 0.0;
    for (var i = 1; i < geometry.length; i++) {
      if (geometry[i].segment == geometry[i - 1].segment) {
        distance += distanceBetween(
          geometry[i - 1].lat,
          geometry[i - 1].lon,
          geometry[i].lat,
          geometry[i].lon,
        );
      }
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (changed || name.text != widget.route.name) {
                        final discard = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Discard route edits?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('Keep editing'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('Discard'),
                              ),
                            ],
                          ),
                        );
                        if (discard != true) return;
                      }
                      widget.close();
                    },
              icon: const Icon(Icons.arrow_back),
            ),
            Expanded(
              child: Text(
                widget.route.id == null ? 'Create route' : 'Edit route',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ],
        ),
        TextField(
          controller: name,
          maxLength: 100,
          decoration: const InputDecoration(labelText: 'Route name'),
        ),
        const SizedBox(height: 12),
        TrackMap(
          points: geometry,
          stops: stops,
          showTiles: widget.showTiles,
          onTap: busy
              ? null
              : (p) => editStops(
                  () => stops.add(RoutePoint(p.latitude, p.longitude)),
                ),
        ),
        const SizedBox(height: 12),
        Text(
          kind == 'imported'
              ? 'Imported GPX • stored track geometry'
              : 'Draft — straight lines, not road directions',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Text(
          '${(distance / 1000).toStringAsFixed(2)} km ${kind == 'imported' ? 'track geometry' : 'straight-line distance'}',
        ),
        const Text(
          'Tap the map to add stops. Editing stops replaces imported geometry with a draft.',
        ),
        for (var i = 0; i < stops.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(child: Text('${i + 1}')),
            title: Text(
              '${stops[i].lat.toStringAsFixed(5)}, ${stops[i].lon.toStringAsFixed(5)}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Move stop up',
                  onPressed: busy || i == 0
                      ? null
                      : () => editStops(() {
                          final p = stops.removeAt(i);
                          stops.insert(i - 1, p);
                        }),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: 'Move stop down',
                  onPressed: busy || i == stops.length - 1
                      ? null
                      : () => editStops(() {
                          final p = stops.removeAt(i);
                          stops.insert(i + 1, p);
                        }),
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  tooltip: 'Delete stop',
                  onPressed: busy
                      ? null
                      : () => editStops(() => stops.removeAt(i)),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        FilledButton.icon(
          onPressed: busy || stops.length < 2
              ? null
              : () async {
                  if (name.text.trim().isEmpty) {
                    await showError(context, 'Name this route before saving.');
                    return;
                  }
                  setState(() => busy = true);
                  try {
                    await widget.save(
                      SavedRoute(
                        widget.route.id,
                        name.text.trim(),
                        kind,
                        stops,
                        geometry,
                      ),
                    );
                  } catch (e) {
                    if (context.mounted) await showError(context, e);
                  }
                  if (mounted) setState(() => busy = false);
                },
          icon: const Icon(Icons.save_outlined),
          label: const Text('Save route'),
        ),
        if (stops.length < 2)
          const Text('Add at least two stops to save a route.'),
      ],
    );
  }
}
