import 'dart:math';
import 'ride_models.dart';

double distanceBetween(double lat1, double lon1, double lat2, double lon2) {
  const r = pi / 180;
  final a =
      pow(sin((lat2 - lat1) * r / 2), 2) +
      cos(lat1 * r) * cos(lat2 * r) * pow(sin((lon2 - lon1) * r / 2), 2);
  return 6371000 * 2 * atan2(sqrt(a.clamp(0, 1)), sqrt((1 - a).clamp(0, 1)));
}

double trackDistance(List<RidePoint> track) {
  var sum = 0.0;
  for (var i = 1; i < track.length; i++) {
    if (track[i].segment == track[i - 1].segment) {
      sum += distanceBetween(
        track[i - 1].lat,
        track[i - 1].lon,
        track[i].lat,
        track[i].lon,
      );
    }
  }
  return sum;
}

String durationLabel(Duration d) {
  final seconds = d.inSeconds.clamp(0, 99999999);
  return '${seconds ~/ 3600}:${((seconds ~/ 60) % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}
