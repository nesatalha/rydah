import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'local_store.dart';

String normalizeOrigin(String value) {
  final uri = Uri.parse(value.trim());
  final local = [
    'localhost',
    '127.0.0.1',
    '10.0.2.2',
    '::1',
  ].contains(uri.host.toLowerCase());
  if ((uri.scheme.toLowerCase() != 'https' &&
          !(uri.scheme.toLowerCase() == 'http' && local)) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      !['', '/'].contains(uri.path) ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Use an HTTPS backend origin (HTTP is only allowed for localhost/emulator development).',
    );
  }
  return Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    port: uri.hasPort ? uri.port : null,
  ).origin;
}

String randomToken() {
  final random = Random.secure();
  return List.generate(
    32,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String randomId() {
  final chars = randomToken().substring(0, 32).split('');
  chars[12] = '4';
  chars[16] = ((int.parse(chars[16], radix: 16) & 3) | 8).toRadixString(16);
  final s = chars.join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PlatformSecretStore implements SecretStore {
  const PlatformSecretStore();
  static const storage = FlutterSecureStorage(aOptions: AndroidOptions());
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
}

class DeviceAccount {
  DeviceAccount(
    this.origin,
    this.deviceId,
    this.token, {
    this.enrolled = false,
    bool registered = false,
    this.retired = false,
    this.enrollment,
    this.pending,
  }) : registered = registered || enrolled;
  final String origin, deviceId, token;
  // The backend knows this device; it can share a private link without a group.
  bool registered;
  // A retired identity's server membership ended; the backend never re-admits
  // a revoked device to the same group, so the next join uses a new identity.
  bool enrolled, retired;
  Map<String, dynamic>? enrollment, pending;
  Map<String, dynamic> toJson() => {
    'origin': origin,
    'deviceId': deviceId,
    'token': token,
    'enrolled': enrolled,
    'registered': registered,
    'retired': retired,
    'enrollment': enrollment,
    'pending': pending,
  };
  factory DeviceAccount.fromJson(Map<String, dynamic> j) => DeviceAccount(
    j['origin'],
    j['deviceId'],
    j['token'],
    enrolled: j['enrolled'] == true,
    registered: j['registered'] == true,
    retired: j['retired'] == true,
    enrollment: (j['enrollment'] as Map?)?.cast<String, dynamic>(),
    pending: (j['pending'] as Map?)?.cast<String, dynamic>(),
  );
}

class AccountStore {
  AccountStore(this.secrets);
  final SecretStore secrets;
  Future<DeviceAccount> load(String url) async {
    final origin = normalizeOrigin(url);
    final raw = await secrets.read('account:$origin');
    if (raw != null) {
      return DeviceAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
    return fresh(origin);
  }

  Future<DeviceAccount> fresh(String origin) async {
    final account = DeviceAccount(origin, randomId(), randomToken());
    await save(account);
    return account;
  }

  Future<void> save(DeviceAccount account) =>
      secrets.write('account:${account.origin}', jsonEncode(account.toJson()));
}

class LocalProfile {
  LocalProfile(String name, this.photo, this.dirty) : name = name.trim() {
    if (this.name.isEmpty || this.name.length > 60) {
      throw const FormatException('Name must have 1–60 characters');
    }
  }
  final String name;
  final Uint8List? photo;
  final bool dirty;
}

abstract interface class ProfileRepository {
  Future<LocalProfile?> load();
  Future<void> save(LocalProfile profile);
  Future<String?> backend();
  Future<void> saveBackend(String origin);
}

class MemoryProfileRepository implements ProfileRepository {
  LocalProfile? value;
  String? origin;
  @override
  Future<LocalProfile?> load() async => value;
  @override
  Future<void> save(LocalProfile profile) async {
    value = profile;
  }

  @override
  Future<String?> backend() async => origin;
  @override
  Future<void> saveBackend(String value) async {
    origin = value;
  }
}

class SqlProfileRepository implements ProfileRepository {
  SqlProfileRepository(this.store);
  final LocalStore store;
  Future<void> _table() => store.db.execute(
    'CREATE TABLE IF NOT EXISTS local_profile(id INTEGER PRIMARY KEY CHECK(id=1),name TEXT,photo BLOB,dirty INTEGER NOT NULL DEFAULT 0,backend TEXT)',
  );
  @override
  Future<LocalProfile?> load() async {
    await _table();
    final rows = await store.db.query('local_profile');
    if (rows.isEmpty || rows.first['name'] == null) return null;
    final r = rows.first;
    return LocalProfile(
      r['name'] as String,
      r['photo'] as Uint8List?,
      r['dirty'] == 1,
    );
  }

  @override
  Future<void> save(LocalProfile p) async {
    await _table();
    await store.db.rawInsert(
      'INSERT INTO local_profile(id,name,photo,dirty) VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,photo=excluded.photo,dirty=excluded.dirty',
      [p.name, p.photo, p.dirty ? 1 : 0],
    );
  }

  @override
  Future<String?> backend() async {
    await _table();
    final rows = await store.db.query('local_profile', columns: ['backend']);
    return rows.isEmpty ? null : rows.first['backend'] as String?;
  }

  @override
  Future<void> saveBackend(String origin) async {
    await _table();
    await store.db.rawInsert(
      'INSERT INTO local_profile(id,backend) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET backend=excluded.backend',
      [origin],
    );
  }
}
