class RoutePoint {
  RoutePoint(this.lat, this.lon, {this.segment = 0});
  final double lat, lon;
  final int segment;
}

class SavedRoute {
  SavedRoute(this.id, this.name, this.kind, this.stops, this.geometry);
  final int? id;
  final String name, kind;
  final List<RoutePoint> stops, geometry;
}
