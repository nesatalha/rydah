import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'account_store.dart';
import 'sharing_api.dart';

class Invitation {
  Invitation(this.origin, this.token);
  final String origin, token;
  factory Invitation.parse(String value, String current) {
    var token = value.trim();
    var origin = normalizeOrigin(current);
    if (token.contains('://')) {
      final uri = Uri.parse(token);
      if (uri.path != '/join.html' || uri.hasQuery || uri.userInfo.isNotEmpty) {
        throw const FormatException('Invalid invitation link');
      }
      origin = normalizeOrigin(uri.origin);
      token = Uri.splitQueryString(uri.fragment)['token'] ?? '';
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw const FormatException(
        'Invitation must be a full join link or a 64 character token',
      );
    }
    return Invitation(origin, token);
  }
}

class GroupApi extends SharingApi {
  GroupApi(this.account) : super(account.origin, account.token);
  final DeviceAccount account;
  Future<Map<String, dynamic>> json(
    String method,
    String path, [
    Map<String, dynamic>? body,
    String? token,
  ]) async {
    final response = await request(method, path, token ?? key, body);
    return response.body.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(response.body) as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> enroll(String invite, String name) => json(
    'POST',
    '/api/enroll',
    {'deviceId': account.deviceId, 'deviceToken': key, 'name': name},
    invite,
  );
  Future<Map<String, dynamic>> register(String name) => json(
    'POST',
    '/api/devices',
    {'deviceId': account.deviceId, 'deviceToken': key, 'name': name},
  );
  Future<Map<String, dynamic>> group() => json('GET', '/api/group');
  Future<Map<String, dynamic>> me() => json('GET', '/api/me');
  Future<void> profile(String name) async {
    await json('PUT', '/api/me', {'name': name});
  }

  Future<void> avatar(Uint8List? photo) async {
    if (photo == null) {
      await request('DELETE', '/api/me/avatar', key);
      return;
    }
    final r = http.Request('PUT', Uri.parse('$base/api/me/avatar'))
      ..headers.addAll({
        'Authorization': 'Bearer $key',
        'Content-Type': 'image/png',
      })
      ..bodyBytes = photo;
    final response = await http.Response.fromStream(
      await r.send().timeout(const Duration(seconds: 12)),
    ).timeout(const Duration(seconds: 12));
    if (response.statusCode >= 400) {
      throw SharingApiException(response.statusCode, 'Photo sync failed');
    }
  }

  Future<Uint8List> memberAvatar(String id) async => (await request(
    'GET',
    '/api/group/members/${Uri.encodeComponent(id)}/avatar',
    key,
  )).bodyBytes;
  Future<ShareSession> createSession(Map<String, dynamic> input) async {
    final b = await json('POST', '/api/me/sessions', input);
    return ShareSession(
      b['id'],
      b['writeToken'],
      b['readToken'],
      DateTime.fromMillisecondsSinceEpoch(b['expiresAt']),
    );
  }

  Future<List<Map<String, dynamic>>> invitations() async {
    final r = await request('GET', '/api/group/invitations', key);
    return (jsonDecode(r.body) as List)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }

  Future<Map<String, dynamic>> invite() =>
      json('POST', '/api/group/invitations');
  Future<void> revoke(String id) async {
    await json('DELETE', '/api/group/invitations/${Uri.encodeComponent(id)}');
  }

  Future<void> remove(String id) async {
    await json('DELETE', '/api/group/members/${Uri.encodeComponent(id)}');
  }

  Future<void> leave({bool owner = false}) async {
    await json('DELETE', owner ? '/api/group' : '/api/group/membership');
  }

  Future<void> meeting(Map<String, dynamic>? value) async {
    await json(
      value == null ? 'DELETE' : 'PUT',
      '/api/group/meeting-point',
      value,
    );
  }

  Future<Map<String, dynamic>> bootstrap(String name, String creator) =>
      json('POST', '/api/admin/groups', {'name': name}, creator);
}
