import 'dart:async';
import 'package:flutter/material.dart';
import 'share_options_dialog.dart';
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
import 'account_store.dart';
import 'account_controller.dart';
import 'group_controller.dart';
import 'group_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.store,
    this.prepare,
    this.points,
    this.showTiles = true,
    this.accountController,
  });
  final LocalStore store;
  final AccountController? accountController;
  final Future<void> Function()? prepare;
  final Stream<GeoPoint> Function()? points;
  final bool showTiles;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final gps = GpsSource();
  late final AccountController account;
  GroupController? group;
  String? accountError;
  bool foreground = true, accountReady = false;
  Timer? clock;
  DeviceAccount? boundAccount;
  Future<void> loadAccount() async {
    try {
      await account.load();
      if (!mounted) return;
      accountReady = true;
      bindAccount();
    } catch (e) {
      if (mounted) {
        setState(() => accountError = 'Secure identity unavailable: $e');
      }
    }
  }

  void bindAccount() {
    if (!mounted) return;
    if (account.account != null && !identical(boundAccount, account.account)) {
      boundAccount = account.account;
      sender.removeListener(refresh);
      sender.dispose();
      sender = createSender();
      group?.dispose();
      group = GroupController(
        account.api,
        onMembershipLost: account.membershipEnded,
      )..addListener(refresh);
      group!.visible(tab == 3 && foreground && account.account!.enrolled);
      unawaited(sender.recover());
    }
    if (account.account?.enrolled != true) group?.visible(false);
    refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    group?.visible(tab == 3 && foreground && account.account?.enrolled == true);
  }

  final historyKey = GlobalKey<HistoryScreenState>();
  late final RideRecorder recorder;
  late LocationSender sender;
  int tab = 0;
  Future<void> Function() get prepare => widget.prepare ?? gps.prepare;
  Stream<GeoPoint> Function() get points => widget.points ?? () => gps.stream;
  LocationSender createSender() => LocationSender(
    api: account.account == null
        ? SharingApi(AccountController.defaultBackend, '')
        : account.api,
    accountStore: account.accounts,
    prepare: prepare,
    points: points,
  )..addListener(refresh);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    account =
        widget.accountController ??
        AccountController(
          SqlProfileRepository(widget.store),
          AccountStore(const PlatformSecretStore()),
        );
    account.addListener(bindAccount);
    recorder = RideRecorder(
      store: widget.store,
      prepare: prepare,
      points: points,
    )..addListener(refresh);
    sender = createSender();
    unawaited(loadAccount());
    clock = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
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
    if (sender.hasPending || sender.busy) return;
    if (!accountReady || account.profile == null) {
      setState(() => tab = 4);
      await showError(
        context,
        StateError('Add your name (and optional photo) in Settings first.'),
      );
      return;
    }
    final inGroup = account.account?.enrolled == true;
    final options = await showShareOptions(context, inGroup: inGroup);
    if (options == null || !mounted) return;
    try {
      await account.ensureRegistered();
    } catch (e) {
      if (mounted) await showError(context, e);
      return;
    }
    sender.audience = options.audience;
    sender.durationMinutes = options.minutes;
    sender.trail = options.trail;
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
    clock?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    group?.dispose();
    account.removeListener(bindAccount);
    if (widget.accountController == null) account.dispose();
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
          profile: account.profile,
        ),
        HistoryScreen(
          key: historyKey,
          store: widget.store,
          activeRideId: () => recorder.rideId,
          goRide: () => setState(() => tab = 0),
          showTiles: widget.showTiles,
        ),
        RoutesScreen(store: widget.store, showTiles: widget.showTiles),
        if (group != null)
          GroupScreen(
            controller: group!,
            showTiles: widget.showTiles,
            onMembershipChanged: account.membershipEnded,
          )
        else
          const Center(
            child: Text('Save your profile and join a group in Settings.'),
          ),
        if (accountError != null)
          ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(accountError!),
              FilledButton(
                onPressed: loadAccount,
                child: const Text('Retry secure storage'),
              ),
            ],
          )
        else if (!accountReady)
          const Center(child: CircularProgressIndicator())
        else
          SettingsScreen(
            key: ValueKey(account.account!.origin),
            account: account,
            sharingActive: sender.hasPending || sender.busy,
          ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (next) {
        setState(() => tab = next);
        if (next == 1) historyKey.currentState?.refresh();
        group?.visible(
          next == 3 && foreground && account.account?.enrolled == true,
        );
      },
      destinations: const [
        NavigationDestination(icon: Icon(Icons.two_wheeler), label: 'Ride'),
        NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        NavigationDestination(icon: Icon(Icons.alt_route), label: 'Routes'),
        NavigationDestination(icon: Icon(Icons.group_outlined), label: 'Group'),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          label: 'Settings',
        ),
      ],
    ),
  );
}
