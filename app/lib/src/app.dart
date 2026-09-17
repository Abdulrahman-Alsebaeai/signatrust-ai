import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app_lock.dart';
import 'core/app_state.dart';
import 'core/models.dart';
import 'core/theme.dart';
import 'features/admin/admin_screen.dart';
import 'features/auth/auth_screens.dart';
import 'features/auth/legal_screens.dart';
import 'features/documents/documents_screen.dart';
import 'features/history/history_screen.dart';
import 'features/home/home_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/signature/signature_screens.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final session = ref.watch(sessionProvider);
  final locked = ref.watch(appLockProvider);

  return GoRouter(
    initialLocation: '/home',
    redirect: (context, state) {
      final user = session.valueOrNull;
      final location = state.matchedLocation;
      final authRoute = location == '/login' || location == '/register';
      final legalRoute = location == '/terms' || location == '/privacy';
      final captureRoute = location == '/capture';
      final enrollmentRoute = location == '/enrollment';
      final unlockRoute = location == '/unlock';

      if (session.isLoading) {
        return location == '/splash' ? null : '/splash';
      }

      if (user == null) {
        return authRoute || legalRoute ? null : '/login';
      }

      if (legalRoute) return null;

      if (!user.hasEnrollment) {
        if (enrollmentRoute || captureRoute) return null;
        return '/enrollment';
      }

      if (locked) {
        if (unlockRoute || captureRoute) return null;
        return '/unlock';
      }

      if (authRoute || unlockRoute || location == '/splash') {
        return '/home';
      }

      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
      GoRoute(path: '/terms', builder: (_, __) => const TermsOfUseScreen()),
      GoRoute(path: '/privacy', builder: (_, __) => const PrivacyPolicyScreen()),
      GoRoute(
        path: '/unlock',
        builder: (_, __) => const SignatureUnlockScreen(),
      ),
      ShellRoute(
        builder:
            (context, state, child) =>
                AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/documents',
            pageBuilder:
                (_, __) => const NoTransitionPage(child: DocumentsScreen()),
          ),
          GoRoute(
            path: '/history',
            pageBuilder:
                (_, __) => const NoTransitionPage(child: HistoryScreen()),
          ),
          GoRoute(
            path: '/home',
            pageBuilder: (_, __) => const NoTransitionPage(child: HomeScreen()),
          ),
          GoRoute(
            path: '/sign',
            pageBuilder:
                (_, __) => const NoTransitionPage(child: SignCenterScreen()),
          ),
          GoRoute(
            path: '/profile',
            pageBuilder:
                (_, __) => const NoTransitionPage(child: ProfileScreen()),
          ),
        ],
      ),
      GoRoute(
        path: '/enrollment',
        builder: (_, __) => const EnrollmentScreen(),
      ),
      GoRoute(path: '/verify', builder: (_, __) => const VerificationScreen()),
      GoRoute(
        path: '/capture',
        builder:
            (_, state) => SignatureCaptureScreen(
              title: state.uri.queryParameters['title'] ?? 'Capture signature',
            ),
      ),
      GoRoute(
        path: '/result',
        builder:
            (_, state) =>
                ResultScreen(result: state.extra! as VerificationResultData),
      ),
      GoRoute(path: '/admin', builder: (_, __) => const AdminScreen()),
    ],
  );
});

class SignaTrustApp extends ConsumerStatefulWidget {
  const SignaTrustApp({super.key});

  @override
  ConsumerState<SignaTrustApp> createState() => _SignaTrustAppState();
}

class _SignaTrustAppState extends ConsumerState<SignaTrustApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      final user = ref.read(sessionProvider).valueOrNull;
      if (user?.hasEnrollment == true) {
        ref.read(appLockProvider.notifier).lock();
      }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    debugShowCheckedModeBanner: false,
    title: 'SignaTrust AI',
    theme: buildTheme(),
    routerConfig: ref.watch(routerProvider),
  );
}

class AppShell extends StatelessWidget {
  final String location;
  final Widget child;

  const AppShell({super.key, required this.location, required this.child});

  static const routes = <String>[
    '/documents',
    '/history',
    '/home',
    '/sign',
    '/profile',
  ];

  int get index {
    final selected = routes.indexWhere((route) => location.startsWith(route));
    return selected < 0 ? 2 : selected;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: child),
    bottomNavigationBar: _PremiumBottomNavigation(
      selectedIndex: index,
      onSelected: (value) => context.go(routes[value]),
    ),
  );
}

class _PremiumBottomNavigation extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _PremiumBottomNavigation({
    required this.selectedIndex,
    required this.onSelected,
  });

  static const destinations = <_ShellDestination>[
    _ShellDestination(
      icon: Icons.folder_outlined,
      selectedIcon: Icons.folder_rounded,
      label: 'Documents',
    ),
    _ShellDestination(
      icon: Icons.history_rounded,
      selectedIcon: Icons.manage_history_rounded,
      label: 'History',
    ),
    _ShellDestination(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
      label: 'Home',
      primary: true,
    ),
    _ShellDestination(
      icon: Icons.draw_outlined,
      selectedIcon: Icons.draw_rounded,
      label: 'Sign',
    ),
    _ShellDestination(
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      label: 'Profile',
    ),
  ];

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: Color(0xFFE8EDF1))),
      boxShadow: [
        BoxShadow(
          color: Color(0x160D2639),
          blurRadius: 28,
          offset: Offset(0, -8),
        ),
      ],
    ),
    child: SafeArea(
      top: false,
      child: SizedBox(
        height: 78,
        child: Row(
          children: List.generate(destinations.length, (index) {
            final destination = destinations[index];
            final selected = selectedIndex == index;
            return Expanded(
              child:
                  destination.primary
                      ? _CenterHomeDestination(
                        selected: selected,
                        destination: destination,
                        onTap: () => onSelected(index),
                      )
                      : _StandardDestination(
                        selected: selected,
                        destination: destination,
                        onTap: () => onSelected(index),
                      ),
            );
          }),
        ),
      ),
    ),
  );
}

class _StandardDestination extends StatelessWidget {
  final bool selected;
  final _ShellDestination destination;
  final VoidCallback onTap;

  const _StandardDestination({
    required this.selected,
    required this.destination,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkResponse(
    onTap: onTap,
    radius: 34,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.only(top: 10, bottom: 7),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            selected ? destination.selectedIcon : destination.icon,
            color: selected ? AppColors.teal : AppColors.muted,
            size: 24,
          ),
          const SizedBox(height: 4),
          Text(
            destination.label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            style: TextStyle(
              color: selected ? AppColors.ink : AppColors.muted,
              fontSize: 10.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}

class _CenterHomeDestination extends StatelessWidget {
  final bool selected;
  final _ShellDestination destination;
  final VoidCallback onTap;

  const _CenterHomeDestination({
    required this.selected,
    required this.destination,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 78,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          Positioned(
            top: -15,
            child: Material(
              color: Colors.transparent,
              child: InkResponse(
                onTap: onTap,
                radius: 42,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutBack,
                  width: selected ? 62 : 58,
                  height: selected ? 62 : 58,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.navy, AppColors.teal],
                    ),
                    border: Border.all(color: Colors.white, width: 5),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x3D148F8B),
                        blurRadius: 22,
                        offset: Offset(0, 9),
                      ),
                    ],
                  ),
                  child: Icon(
                    selected ? destination.selectedIcon : destination.icon,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 2,
            right: 2,
            bottom: 5,
            child: Text(
              destination.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.ink,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShellDestination {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool primary;

  const _ShellDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.primary = false,
  });
}
