import 'package:flutter_riverpod/flutter_riverpod.dart';

final appLockProvider =
    StateNotifierProvider<AppLockController, bool>((ref) {
  return AppLockController();
});

class AppLockController extends StateNotifier<bool> {
  AppLockController() : super(true);

  void lock() {
    if (!state) state = true;
  }

  void unlock() {
    if (state) state = false;
  }

  void reset() {
    state = true;
  }
}
