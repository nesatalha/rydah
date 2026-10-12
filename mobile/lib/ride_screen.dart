import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ride_recorder.dart';
import 'location_sender.dart';
import 'route_models.dart';
import 'ride_metrics.dart';
import 'track_map.dart';

class RideScreen extends StatelessWidget {
  const RideScreen({
    super.key,
    required this.recorder,
    required this.sender,
    required this.startSharing,
    required this.finishRide,
    this.showTiles = true,
  });
  final RideRecorder recorder;
  final LocationSender sender;
  final Future<void> Function() startSharing, finishRide;
  final bool showTiles;
  Widget section(BuildContext context, String title, List<Widget> children) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      );
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'Ride your way. Keep them close.',
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 14),
      TrackMap(
        points: recorder.track
            .map((p) => RoutePoint(p.lat, p.lon, segment: p.segment))
            .toList(),
        showTiles: showTiles,
      ),
      const SizedBox(height: 12),
      section(context, 'Record this ride', [
        Text(recorder.state),
        const SizedBox(height: 8),
        Text(
          '${(recorder.distanceM / 1000).toStringAsFixed(2)} km • GPS estimate',
          style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
        ),
        Text(
          '${durationLabel(recorder.elapsed)} session time • ${recorder.track.length} GPS points',
        ),
        if (recorder.track.isNotEmpty)
          Text(
            '${recorder.track.last.lat.toStringAsFixed(5)}, ${recorder.track.last.lon.toStringAsFixed(5)} • ±${recorder.track.last.accuracyM.toStringAsFixed(0)} m',
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: recorder.busy
              ? null
              : recorder.rideId != null
              ? finishRide
              : recorder.start,
          icon: Icon(
            recorder.rideId != null
                ? Icons.stop_circle
                : Icons.fiber_manual_record,
          ),
          label: Text(recorder.rideId != null ? 'Finish ride' : 'Start ride'),
        ),
        const Text('Recording saves GPS on this device. Keep the app open.'),
      ]),
      section(context, 'Private location sharing', [
        Text(sender.state),
        if (sender.lastUpload != null)
          Text(
            'Last upload ${sender.lastUpload!.toLocal().toString().substring(11, 19)}',
          ),
        if (sender.session != null)
          Text(
            'Link expires ${sender.session!.expiresAt.toLocal().toString().substring(11, 16)}',
          ),
        const SizedBox(height: 12),
        if (sender.session == null)
          OutlinedButton.icon(
            onPressed: sender.busy ? null : startSharing,
            icon: const Icon(Icons.sensors),
            label: const Text('Start sharing'),
          ),
        if (sender.session != null) ...[
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: sender.api.viewerLink(sender.session!)),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Private viewer link copied')),
                );
              }
            },
            icon: const Icon(Icons.link),
            label: const Text('Copy private link'),
          ),
          TextButton.icon(
            onPressed: sender.busy
                ? null
                : () async {
                    await sender.stop();
                    if (context.mounted && sender.session == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            recorder.recording
                                ? 'Sharing ended. Your ride is still recording.'
                                : 'Sharing ended.',
                          ),
                        ),
                      );
                    }
                  },
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Stop sharing'),
          ),
        ],
        const Text(
          'Sharing needs your backend connection. Recording works independently.',
        ),
      ]),
    ],
  );
}
