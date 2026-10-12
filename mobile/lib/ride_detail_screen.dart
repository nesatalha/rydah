import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'local_store.dart';
import 'ride_models.dart';
import 'ride_metrics.dart';
import 'route_models.dart';
import 'track_map.dart';
import 'gpx_service.dart';
import 'ui_helpers.dart';

class RideDetailScreen extends StatefulWidget {
  const RideDetailScreen({
    super.key,
    required this.store,
    required this.ride,
    this.showTiles = true,
  });
  final LocalStore store;
  final Ride ride;
  final bool showTiles;
  @override
  State<RideDetailScreen> createState() => _RideDetailScreenState();
}

class _RideDetailScreenState extends State<RideDetailScreen> {
  late String name = widget.ride.name;
  late final Future<List<RidePoint>> data = widget.store.points(widget.ride.id);
  bool busy = false;
  Future<void> action(Future<void> Function() run) async {
    setState(() => busy = true);
    try {
      await run();
    } catch (e) {
      if (mounted) await showError(context, e);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(name)),
    body: FutureBuilder<List<RidePoint>>(
      future: data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Unable to load ride: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final points = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TrackMap(
              points: points
                  .map((p) => RoutePoint(p.lat, p.lon, segment: p.segment))
                  .toList(),
              showTiles: widget.showTiles,
            ),
            const SizedBox(height: 16),
            Text(
              '${(trackDistance(points) / 1000).toStringAsFixed(2)} km • GPS estimate',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text(
              '${durationLabel((widget.ride.endedAt ?? widget.ride.startedAt).difference(widget.ride.startedAt))} session time • ${points.length} GPS points',
            ),
            Text('${widget.ride.startedAt.toLocal()} • ${widget.ride.status}'),
            if (points.isEmpty)
              const Text('No GPS points were captured for this ride.'),
            if (points.isNotEmpty)
              Text(
                'Last fix: ${points.last.lat.toStringAsFixed(5)}, ${points.last.lon.toStringAsFixed(5)}',
              ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => action(() async {
                      final next = await askName(context, name);
                      if (next == null) return;
                      await widget.store.renameRide(widget.ride.id, next);
                      if (mounted) setState(() => name = next);
                    }),
              icon: const Icon(Icons.edit),
              label: const Text('Rename'),
            ),
            OutlinedButton.icon(
              onPressed: busy || points.isEmpty
                  ? null
                  : () => action(() async {
                      final file = await FilePicker.saveFile(
                        fileName: 'rydah-ride-${widget.ride.id}.gpx',
                        bytes: Uint8List.fromList(
                          utf8.encode(GpxService.export(name, points)),
                        ),
                        mimeType: 'application/gpx+xml',
                      );
                      if (file != null && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('GPX file saved')),
                        );
                      }
                    }),
              icon: const Icon(Icons.file_download),
              label: const Text('Export GPX file'),
            ),
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () => action(() async {
                      if (!await confirmDelete(context, name)) return;
                      await widget.store.deleteRide(widget.ride.id);
                      if (context.mounted) Navigator.pop(context);
                    }),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete ride'),
            ),
          ],
        );
      },
    ),
  );
}
