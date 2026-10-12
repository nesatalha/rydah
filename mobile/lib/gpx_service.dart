import 'package:xml/xml.dart';
import 'ride_models.dart';
import 'route_models.dart';

class GpxService {
  static const maxBytes = 5 * 1024 * 1024;
  static SavedRoute parse(String input) {
    if (input.length > maxBytes) {
      throw const FormatException('GPX exceeds 5 MB');
    }
    try {
      final doc = XmlDocument.parse(input);
      if (doc.rootElement.name.local != 'gpx') {
        throw const FormatException('Choose a GPX file');
      }
      final points = <RoutePoint>[];
      var segment = 0;
      final tracks = doc.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'trkseg' || e.name.local == 'rte',
      );
      for (final track in tracks) {
        for (final element in track.childElements.where(
          (e) => e.name.local == 'trkpt' || e.name.local == 'rtept',
        )) {
          final lat = double.tryParse(element.getAttribute('lat') ?? ''),
              lon = double.tryParse(element.getAttribute('lon') ?? '');
          if (lat == null ||
              lon == null ||
              !lat.isFinite ||
              !lon.isFinite ||
              lat.abs() > 90 ||
              lon.abs() > 180) {
            throw const FormatException('GPX contains invalid coordinates');
          }
          points.add(RoutePoint(lat, lon, segment: segment));
          if (points.length > 100000) {
            throw const FormatException('GPX contains too many points');
          }
        }
        segment++;
      }
      if (points.length < 2) {
        throw const FormatException(
          'GPX needs at least two track or route points',
        );
      }
      final names = doc.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'name',
      );
      final name = names.isEmpty || names.first.innerText.trim().isEmpty
          ? 'Imported GPX'
          : names.first.innerText.trim();
      return SavedRoute(null, name, 'imported', [
        points.first,
        points.last,
      ], points);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Malformed GPX file');
    }
  }

  static String export(String name, List<RidePoint> points) {
    final b = XmlBuilder();
    b.processing('xml', 'version="1.0" encoding="UTF-8"');
    b.element(
      'gpx',
      attributes: {
        'version': '1.1',
        'creator': 'Rydah',
        'xmlns': 'http://www.topografix.com/GPX/1/1',
      },
      nest: () {
        b.element(
          'trk',
          nest: () {
            b.element('name', nest: name);
            final segments = <int, List<RidePoint>>{};
            for (final p in points) {
              (segments[p.segment] ??= []).add(p);
            }
            for (final segment in segments.values) {
              b.element(
                'trkseg',
                nest: () {
                  for (final p in segment) {
                    b.element(
                      'trkpt',
                      attributes: {
                        'lat': p.lat.toString(),
                        'lon': p.lon.toString(),
                      },
                      nest: () {
                        b.element(
                          'time',
                          nest: p.observedAt.toUtc().toIso8601String(),
                        );
                      },
                    );
                  }
                },
              );
            }
          },
        );
      },
    );
    return b.buildDocument().toXmlString(pretty: true);
  }
}
