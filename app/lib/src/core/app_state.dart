import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'app_lock.dart';
import 'models.dart';

final sessionProvider =
    StateNotifierProvider<SessionController, AsyncValue<AppUser?>>(
      (ref) => SessionController(ref),
    );

class SessionController extends StateNotifier<AsyncValue<AppUser?>> {
  SessionController(this.ref) : super(const AsyncValue.loading()) {
    restore();
  }

  final Ref ref;
  final api = ApiClient.instance;

  Future<void> restore() async {
    final token = await api.storage.read(key: 'access_token');
    if (token == null) {
      state = const AsyncValue<AppUser?>.data(null);
      return;
    }

    try {
      final response = await api.dio.get('/auth/me');
      state = AsyncValue.data(
        AppUser.fromJson(response.data as Map<String, dynamic>),
      );
    } catch (_) {
      await api.clearTokens();
      state = const AsyncValue.data(null);
    }
  }

  Future<void> login(String email, String password) async {
    final response = await api.dio.post(
      '/auth/login',
      data: {'email': email.trim(), 'password': password},
    );

    await api.saveTokens(response.data as Map<String, dynamic>);

    final me = await api.dio.get('/auth/me');

    final user = AppUser.fromJson(me.data as Map<String, dynamic>);

    ref.read(appLockProvider.notifier).unlock();

    state = AsyncValue<AppUser?>.data(user);
  }

  Future<void> register(
    String name,
    String email,
    String phone,
    String password, {
    required bool acceptedLegal,
  }) async {
    await api.dio.post(
      '/auth/register',
      data: {
        'full_name': name.trim(),
        'email': email.trim(),
        'phone': phone.trim().isEmpty ? null : phone.trim(),
        'password': password,
        'accepted_terms': acceptedLegal,
        'accepted_privacy': acceptedLegal,
      },
    );
    await login(email, password);
  }

  Future<void> refreshUser() async {
    final response = await api.dio.get('/auth/me');
    state = AsyncValue.data(
      AppUser.fromJson(response.data as Map<String, dynamic>),
    );
  }

  Future<void> logout() async {
    ref.read(appLockProvider.notifier).reset();
    await api.clearTokens();
    state = const AsyncValue.data(null);
  }
}
