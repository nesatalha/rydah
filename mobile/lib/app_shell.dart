import 'dart:async';
import 'package:flutter/material.dart';
import 'local_store.dart';
import 'gps_source.dart';
import 'ride_recorder.dart';
import 'location_sender.dart';
import 'sharing_api.dart';
import 'ride_screen.dart';
import 'history_screen.dart';
import 'routes_screen.dart';
import 'settings_screen.dart';
import 'ui_helpers.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.store,
    this.prepare,
    this.points,
    this.showTiles = true,
  });
  final LocalStore store;
  final Future<void> Function()? prepare;
  final Stream<GeoPoint> Function()? points;
  final bool showTiles;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final gps = GpsSource();
  final url = TextEditingController(text: 'http://10.0.2.2:8787');
  final secret = TextEditingController(text: 'rydah-local-demo-only');
  final historyKey = GlobalKey<HistoryScreenState>();
  late final RideRecorder recorder;
  late LocationSender sender;
  int tab = 0;
  Future<void> Function() get prepare => widget.prepare ?? gps.prepare;
  Stream<GeoPoint> Function() get points => widget.points ?? () => gps.stream;
  LocationSender createSender() => LocationSender(
    api: SharingApi(url.text.trim(), secret.text),
    prepare: prepare,
    points: points,
  )..addListener(refresh);
  @override
  void initState() {
    super.initState();
    recorder = RideRecorder(
      store: widget.store,
      prepare: prepare,
      points: points,
    )..addListener(refresh);
    sender = createSender();
    WidgetsBinding.instance.addPostFrameCallback((_) => recoverInterrupted());
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> recoverInterrupted() async {
    try {
      final interrupted = (await widget.store.rides())
          .where((r) => r.status == 'recording')
          .toList();
      if (interrupted.isEmpty || !mounted) return;
      final finish = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Interrupted ride found'),
          content: Text(
            '${interrupted.length} ride(s) were left open. Finish at the last saved fix and preserve points? GPS will not resume automatically.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Later in History'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Finish saved rides'),
            ),
          ],
        ),
      );
      if (finish == true) {
        for (final r in interrupted) {
          await widget.store.finishInterrupted(r.id);
        }
        historyKey.currentState?.refresh();
      }
    } catch (e) {
      if (mounted) await showError(context, e);
    }
  }

  Future<void> startSharing() async {
    if (sender.session != null || sender.busy) return;
    sender.removeListener(refresh);
    sender.dispose();
    sender = createSender();
    refresh();
    await sender.start();
  }

  Future<void> finishRide() async {
    await recorder.stop();
    historyKey.currentState?.refresh();
    if (mounted && recorder.rideId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            sender.sharing
                ? 'Ride saved. Private sharing is still active.'
                : 'Ride saved in History.',
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    recorder.removeListener(refresh);
    sender.removeListener(refresh);
    recorder.dispose();
    sender.dispose();
    unawaited(gps.dispose());
    url.dispose();
    secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('rydah', style: TextStyle(fontWeight: FontWeight.w800)),
      actions: [
        if (recorder.recording)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.fiber_manual_record,
                  color: Color(0xFF63E3C4),
                  size: 14,
                ),
                SizedBox(width: 6),
                Text('Recording'),
              ],
            ),
          ),
      ],
    ),
    body: IndexedStack(
      index: tab,
      children: [
        RideScreen(
          recorder: recorder,
          sender: sender,
          startSharing: startSharing,
          finishRide: finishRide,
          showTiles: widget.showTiles,
        ),
        HistoryScreen(
          key: historyKey,
          store: widget.store,
          activeRideId: () => recorder.rideId,
          goRide: () => setState(() => tab = 0),
          showTiles: widget.showTiles,
        ),
        RoutesScreen(store: widget.store, showTiles: widget.showTiles),
        SettingsScreen(
          url: url,
          secret: secret,
          sharingActive: sender.session != null || sender.busy,
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (next) {
        setState(() => tab = next);
        if (next == 1) historyKey.currentState?.refresh();
      },
      destinations: const [
        NavigationDestination(icon: Icon(Icons.two_wheeler), label: 'Ride'),
        NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        NavigationDestination(icon: Icon(Icons.alt_route), label: 'Routes'),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          label: 'Settings',
        ),
      ],
    ),
  );
}
