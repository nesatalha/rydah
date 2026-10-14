import 'dart:convert';
import 'package:http/http.dart' as http;

class ShareSession {
  ShareSession(this.id, this.writeToken, this.readToken, this.expiresAt);
  final String id, writeToken, readToken;
  final DateTime expiresAt;
}

class GeoPoint {
  GeoPoint(this.lat, this.lon, this.accuracyM, this.observedAt);
  final double lat, lon, accuracyM;
  final DateTime observedAt;
}

class SharingApiException implements Exception {
  SharingApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'Exception: $message';
}

class SharingApi {
  SharingApi(String url, this.key) : base = url.replaceAll(RegExp(r'/+$'), '');
  final String base, key;
  Future<http.Response> request(
    String method,
    String path,
    String token, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse('$base$path');
    if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      throw Exception('Enter a valid backend URL');
    }
    final request = http.Request(method, uri)
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      });
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(seconds: 12)),
    ).timeout(const Duration(seconds: 12));
    if (response.statusCode >= 400) {
      String message = 'Server error ${response.statusCode}';
      try {
        message = (jsonDecode(response.body) as Map)['error'].toString();
      } catch (_) {}
      throw SharingApiException(response.statusCode, message);
    }
    return response;
  }

  Future<ShareSession> create() async {
    final r = await request('POST', '/api/sessions', key, {'source': 'device'});
    final b = jsonDecode(r.body) as Map;
    return ShareSession(
      b['id'],
      b['writeToken'],
      b['readToken'],
      DateTime.fromMillisecondsSinceEpoch(b['expiresAt']),
    );
  }

  Future<void> upload(ShareSession s, int seq, GeoPoint point) async {
    await request('PUT', '/api/sessions/${s.id}/location', s.writeToken, {
      'seq': seq,
      'lat': point.lat,
      'lon': point.lon,
      'accuracyM': point.accuracyM,
      'observedAt': point.observedAt.millisecondsSinceEpoch,
    });
  }

  Future<void> stop(ShareSession s) async {
    await request('DELETE', '/api/sessions/${s.id}', s.writeToken);
  }

  String viewerLink(ShareSession s) =>
      '${base.replaceFirst('://10.0.2.2:', '://localhost:')}/view.html#id=${Uri.encodeComponent(s.id)}&token=${Uri.encodeComponent(s.readToken)}';
}
