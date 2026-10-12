import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:mobile/gpx_service.dart';
import 'package:mobile/ride_models.dart';

void main() {
  test(
    'escaped names, UTC times and segment breaks survive GPX export/import',
    () {
      final xml = GpxService.export('Ride & <friends>', [
        RidePoint(1, 0, 41, 29, 5, DateTime.utc(2026)),
        RidePoint(2, 1, 42, 30, 5, DateTime.utc(2026, 1, 2)),
      ]);
      final document = XmlDocument.parse(xml);
      expect(
        document.findAllElements('time').first.innerText,
        '2026-01-01T00:00:00.000Z',
      );
      final route = GpxService.parse(xml);
      expect(route.name, 'Ride & <friends>');
      expect(route.geometry.map((p) => p.lat), [41, 42]);
      expect(route.geometry.last.segment, 1);
    },
  );
  test('namespaced routes import and invalid input is rejected', () {
    expect(
      GpxService.parse(
        '<g:gpx xmlns:g="http://www.topografix.com/GPX/1/1"><g:rte><g:rtept lat="0" lon="0"/><g:rtept lat="1" lon="1"/></g:rte></g:gpx>',
      ).geometry,
      hasLength(2),
    );
    for (final invalid in [
      '<invalid>',
      '<gpx/>',
      '<gpx><rte><rtept lat="NaN" lon="0"/><rtept lat="1" lon="1"/></rte></gpx>',
    ]) {
      expect(() => GpxService.parse(invalid), throwsFormatException);
    }
  });
}
