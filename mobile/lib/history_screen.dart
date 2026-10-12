import 'package:flutter/material.dart';
import 'local_store.dart';
import 'ride_models.dart';
import 'ride_detail_screen.dart';
import 'ride_metrics.dart';
import 'ui_helpers.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.store,
    required this.goRide,
    required this.activeRideId,
    this.showTiles = true,
  });
  final LocalStore store;
  final VoidCallback goRide;
  final int? Function() activeRideId;
  final bool showTiles;
  @override
  State<HistoryScreen> createState() => HistoryScreenState();
}

class HistoryScreenState extends State<HistoryScreen> {
  late Future<List<Ride>> data = widget.store.rides();
  void refresh() {
    if (mounted) {
      setState(() {
        data = widget.store.rides();
      });
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Ride>>(
    future: data,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('History unavailable: ${snapshot.error}'),
              TextButton(onPressed: refresh, child: const Text('Retry')),
            ],
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final rides = snapshot.data!;
      if (rides.isEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.route, size: 56),
              const SizedBox(height: 16),
              const Text('Your rides stay on this device.'),
              const Text('Record your first ride to see it here.'),
              FilledButton(
                onPressed: widget.goRide,
                child: const Text('Go to Ride'),
              ),
            ],
          ),
        );
      }
      return RefreshIndicator(
        onRefresh: () async {
          refresh();
          await data;
        },
        child: ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: rides.length,
          itemBuilder: (context, i) {
            final ride = rides[i];
            return Card(
              child: ListTile(
                title: Text(ride.name),
                subtitle: FutureBuilder<List<RidePoint>>(
                  future: widget.store.points(ride.id),
                  builder: (context, points) => Text(
                    '${ride.startedAt.toLocal().toString().substring(0, 16)}\n${ride.status} • ${durationLabel((ride.endedAt ?? ride.startedAt).difference(ride.startedAt))}${points.hasData ? ' • ${(trackDistance(points.data!) / 1000).toStringAsFixed(2)} km GPS estimate' : ''}',
                  ),
                ),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  if (ride.status == 'recording') {
                    if (widget.activeRideId() == ride.id) {
                      widget.goRide();
                      return;
                    }
                    final finish = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Finish interrupted ride?'),
                        content: const Text(
                          'Keep committed points and end at the last saved fix. App downtime is excluded.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('Finish'),
                          ),
                        ],
                      ),
                    );
                    if (finish == true) {
                      try {
                        await widget.store.finishInterrupted(ride.id);
                        refresh();
                      } catch (e) {
                        if (context.mounted) await showError(context, e);
                      }
                    }
                    return;
                  }
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => RideDetailScreen(
                        store: widget.store,
                        ride: ride,
                        showTiles: widget.showTiles,
                      ),
                    ),
                  );
                  refresh();
                },
              ),
            );
          },
        ),
      );
    },
  );
}
