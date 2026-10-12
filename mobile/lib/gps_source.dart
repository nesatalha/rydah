import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'sharing_api.dart';

class GpsSource {
  GpsSource() {
    _controller = StreamController<GeoPoint>.broadcast(
      onListen: _listen,
      onCancel: _cancel,
    );
  }
  late final StreamController<GeoPoint> _controller;
  StreamSubscription<Position>? _source;
  Stream<GeoPoint> get stream => _controller.stream;
  Future<void> prepare() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Turn on Location in Android settings.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location blocked. Open app permissions.');
    }
    if (permission == LocationPermission.denied) {
      throw Exception('Location permission denied.');
    }
  }

  void _listen() {
    _source =
        Geolocator.getPositionStream(
          locationSettings: AndroidSettings(
            forceLocationManager: const bool.fromEnvironment(
              'RYDAH_NATIVE_GPS',
            ),
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 5),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Rydah GPS active',
              notificationText: 'Recording or sharing while the app is open.',
              enableWakeLock: true,
            ),
          ),
        ).listen(
          (p) => _controller.add(
            GeoPoint(p.latitude, p.longitude, p.accuracy, p.timestamp),
          ),
          onError: _controller.addError,
        );
  }

  Future<void> _cancel() async {
    await _source?.cancel();
    _source = null;
  }

  Future<void> dispose() async {
    await _cancel();
    await _controller.close();
  }
}
