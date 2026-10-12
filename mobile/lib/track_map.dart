import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'route_models.dart';

class TrackMap extends StatelessWidget {
  const TrackMap({
    super.key,
    required this.points,
    this.stops = const [],
    this.onTap,
    this.showTiles = true,
  });
  final List<RoutePoint> points, stops;
  final void Function(LatLng)? onTap;
  final bool showTiles;
  @override
  Widget build(BuildContext context) {
    final positions = points.map((p) => LatLng(p.lat, p.lon)).toList();
    final segments = <int, List<LatLng>>{};
    for (final p in points) {
      (segments[p.segment] ??= []).add(LatLng(p.lat, p.lon));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 270,
        child: FlutterMap(
          key: ValueKey(
            '${positions.length}-${positions.isEmpty ? '' : positions.last}',
          ),
          options: MapOptions(
            initialCenter: positions.isEmpty
                ? const LatLng(41.0082, 28.9784)
                : positions.first,
            initialZoom: positions.isEmpty ? 10 : 15,
            initialCameraFit:
                positions.length > 1 &&
                    positions.any((p) => p != positions.first)
                ? CameraFit.bounds(
                    bounds: LatLngBounds.fromPoints(positions),
                    padding: const EdgeInsets.all(32),
                  )
                : null,
            onTap: onTap == null ? null : (_, point) => onTap!(point),
          ),
          children: [
            if (showTiles)
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.mobile',
              ),
            PolylineLayer(
              polylines: segments.values
                  .where((s) => s.length > 1)
                  .map(
                    (s) => Polyline(
                      points: s,
                      color: const Color(0xFF63E3C4),
                      strokeWidth: 4,
                    ),
                  )
                  .toList(),
            ),
            MarkerLayer(
              markers: [
                for (var i = 0; i < stops.length; i++)
                  Marker(
                    point: LatLng(stops[i].lat, stops[i].lon),
                    width: 30,
                    height: 30,
                    child: CircleAvatar(
                      backgroundColor: const Color(0xFF63E3C4),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(color: Colors.black),
                      ),
                    ),
                  ),
                if (stops.isEmpty && positions.isNotEmpty)
                  Marker(
                    point: positions.last,
                    width: 28,
                    height: 28,
                    child: const Icon(Icons.my_location, color: Colors.white),
                  ),
              ],
            ),
            const Positioned(
              bottom: 4,
              right: 6,
              child: ColoredBox(
                color: Colors.black54,
                child: Text(
                  '© OpenStreetMap contributors',
                  style: TextStyle(fontSize: 10),
                ),
              ),
            ),
            if (positions.isEmpty && onTap == null)
              const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('No GPS points yet'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
