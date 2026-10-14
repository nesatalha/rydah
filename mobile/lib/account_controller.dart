import 'package:flutter/foundation.dart';
import 'account_store.dart';
import 'group_api.dart';

class AccountController extends ChangeNotifier {
  AccountController(this.profiles, this.accounts);
  final ProfileRepository profiles;
  final AccountStore accounts;
  LocalProfile? profile;
  DeviceAccount? account;
  String? error;
  bool busy = false;
  GroupApi get api => GroupApi(account!);
  static const defaultBackend = String.fromEnvironment(
    'RYDAH_BACKEND_URL',
    defaultValue: 'http://10.0.2.2:8787',
  );
  Future<void> load() async {
    profile = await profiles.load();
    account = await accounts.load(await profiles.backend() ?? defaultBackend);
    notifyListeners();
  }

  Future<void> backend(String value, {required bool blocked}) async {
    if (blocked) {
      throw StateError('Stop or recover sharing before changing backend');
    }
    final origin = normalizeOrigin(value);
    final next = await accounts.load(origin);
    await profiles.saveBackend(origin);
    account = next;
    notifyListeners();
  }

  Future<void> saveProfile(String name, Uint8List? photo) async {
    final next = LocalProfile(name, photo, true);
    await profiles.save(next);
    profile = next;
    notifyListeners();
    if (account?.registered == true) await sync();
  }

  Future<void> sync() async {
    final saved = profile;
    if (saved == null || account?.registered != true) return;
    try {
      await api.profile(saved.name);
      await api.avatar(saved.photo);
      if (identical(profile, saved)) {
        final clean = LocalProfile(saved.name, saved.photo, false);
        await profiles.save(clean);
        profile = clean;
      }
      error = null;
    } catch (e) {
      error = 'Profile saved locally; sync pending: $e';
    }
    notifyListeners();
  }

  Future<void> enroll(Invitation invitation, {required bool blocked}) async {
    if (profile == null) throw StateError('Save your local profile first');
    if (blocked) throw StateError('Stop or recover sharing before joining');
    if (account!.origin != invitation.origin) {
      await backend(invitation.origin, blocked: blocked);
    }
    await prepareIdentity();
    final a = account!;
    a.enrollment ??= {'token': invitation.token, 'name': profile!.name};
    await accounts.save(a);
    notifyListeners();
    await retryEnrollment();
  }

  /// Registers this device so it can share a private link without a group.
  Future<void> ensureRegistered() async {
    final p = profile;
    if (p == null) throw StateError('Add your name in Settings first');
    final a = account!;
    if (a.registered) return;
    await api.register(p.name);
    a.registered = true;
    await accounts.save(a);
    notifyListeners();
    await sync();
  }

  /// Replaces a retired identity before a new enrollment.
  Future<void> prepareIdentity() async {
    final a = account!;
    if (!a.retired || a.enrollment != null) return;
    if (a.pending != null) {
      throw StateError('Stop or recover sharing before joining');
    }
    account = await accounts.fresh(a.origin);
    error = null;
    notifyListeners();
  }

  /// Records that the server no longer accepts this device's membership.
  Future<void> membershipEnded() async {
    final a = account;
    if (a == null || a.retired) return;
    a.enrolled = false;
    a.retired = true;
    await accounts.save(a);
    notifyListeners();
  }

  Future<void> retryEnrollment() async {
    final a = account!;
    final input = a.enrollment;
    if (input == null) return;
    busy = true;
    notifyListeners();
    try {
      await api.enroll(input['token'], input['name']);
      a.enrolled = true;
      a.registered = true;
      a.enrollment = null;
      await accounts.save(a);
      error = null;
      await sync();
    } catch (e) {
      error = 'Enrollment pending — retry: $e';
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> bootstrap(
    String name,
    String creator, {
    required bool blocked,
  }) async {
    if (profile == null) throw StateError('Save your local profile first');
    if (blocked) throw StateError('Stop sharing first');
    final result = await api.bootstrap(name, creator);
    final invitation = result['invitation'] as Map;
    await enroll(
      Invitation(account!.origin, invitation['token']),
      blocked: blocked,
    );
  }
}
