import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/app_lock.dart';
import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

class SignCenterScreen extends ConsumerWidget {
  const SignCenterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enrolled =
        ref.watch(sessionProvider).valueOrNull?.hasEnrollment ?? false;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const PageHeader(
          title: 'Signature center',
          subtitle:
              'Enroll, replace, or verify your behavioral signature identity.',
        ),
        const SizedBox(height: 24),
        _SignAction(
          icon: Icons.fingerprint_rounded,
          title: enrolled ? 'Replace enrollment' : 'Create enrollment',
          subtitle: 'Capture exactly five natural signatures.',
          onTap: () => context.push('/enrollment'),
        ),
        const SizedBox(height: 14),
        _SignAction(
          icon: Icons.verified_user_outlined,
          title: 'Verify signature',
          subtitle: enrolled
              ? 'Compare a new signature with five encrypted references.'
              : 'Enrollment is required before verification.',
          onTap: enrolled ? () => context.push('/verify') : null,
        ),
      ],
    );
  }
}

class _SignAction extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _SignAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: AppColors.tealLight,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: AppColors.teal, size: 30),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 7),
                      Text(subtitle),
                    ],
                  ),
                ),
                Icon(
                  onTap == null
                      ? Icons.lock_outline_rounded
                      : Icons.arrow_forward_rounded,
                  color: AppColors.muted,
                ),
              ],
            ),
          ),
        ),
      );
}

class EnrollmentScreen extends ConsumerStatefulWidget {
  const EnrollmentScreen({super.key});

  @override
  ConsumerState<EnrollmentScreen> createState() =>
      _EnrollmentScreenState();
}

class _EnrollmentScreenState extends ConsumerState<EnrollmentScreen> {
  final List<CapturedSignature> signatures = [];
  int step = 0;
  bool captured = false;
  bool busy = false;

  bool get finalStep => step == 4;

  @override
  Widget build(BuildContext context) {
    final replacing =
        ref.watch(sessionProvider).valueOrNull?.hasEnrollment ?? false;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: replacing,
        title: Text(replacing ? 'Replace enrollment' : 'Signature setup'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
          child: Column(
            children: [
              _EnrollmentProgress(current: step, captured: captured),
              const SizedBox(height: 26),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 420),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(.08, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _EnrollmentStep(
                    key: ValueKey('$step-$captured'),
                    step: step,
                    captured: captured,
                    busy: busy,
                    onCapture: capture,
                    onRetake: retake,
                    onContinue: continueFlow,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> capture() async {
    final number = step + 1;
    final result = await context.push<CapturedSignature>(
      '/capture?title=Signature%20$number%20of%205',
    );

    if (result == null || !mounted) return;

    setState(() {
      if (signatures.length > step) {
        signatures[step] = result;
      } else {
        signatures.add(result);
      }
      captured = true;
    });
  }

  Future<void> retake() async {
    if (signatures.length > step) {
      signatures.removeAt(step);
    }
    setState(() => captured = false);
    await capture();
  }

  Future<void> continueFlow() async {
    if (!captured) return;

    if (!finalStep) {
      setState(() {
        step += 1;
        captured = false;
      });
      return;
    }

    await submit();
  }

  Future<void> submit() async {
    if (signatures.length != 5) {
      AppNotice.show(
        context,
        'Complete all five signatures.',
        error: true,
      );
      return;
    }

    setState(() => busy = true);
    try {
      await ApiClient.instance.dio.post(
        '/signatures/enrollment',
        data: {
          'references': [
            for (var i = 0; i < signatures.length; i++)
              signatures[i].toJson(session: i + 1),
          ],
        },
      );
      await ref.read(sessionProvider.notifier).refreshUser();
      ref.read(appLockProvider.notifier).unlock();

      if (mounted) {
        AppNotice.show(context, 'Signature identity is ready.');
        context.go('/home');
      }
    } catch (error) {
      if (mounted) {
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(error),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class _EnrollmentProgress extends StatelessWidget {
  final int current;
  final bool captured;

  const _EnrollmentProgress({
    required this.current,
    required this.captured,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Row(
            children: List.generate(5, (index) {
              final complete = index < current ||
                  (index == current && captured);
              final active = index == current;

              return Expanded(
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 260),
                      width: active ? 34 : 28,
                      height: active ? 34 : 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: complete
                            ? AppColors.teal
                            : active
                                ? AppColors.navy
                                : const Color(0xFFE4EBF0),
                      ),
                      child: Center(
                        child: complete
                            ? const Icon(
                                Icons.check_rounded,
                                color: Colors.white,
                                size: 18,
                              )
                            : Text(
                                '${index + 1}',
                                style: TextStyle(
                                  color: active
                                      ? Colors.white
                                      : AppColors.muted,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                      ),
                    ),
                    if (index < 4)
                      Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 260),
                          height: 3,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: index < current
                                ? AppColors.teal
                                : const Color(0xFFE4EBF0),
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            }),
          ),
          const SizedBox(height: 12),
          Text(
            'Step ${current + 1} of 5',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      );
}

class _EnrollmentStep extends StatelessWidget {
  final int step;
  final bool captured;
  final bool busy;
  final VoidCallback onCapture;
  final VoidCallback onRetake;
  final VoidCallback onContinue;

  const _EnrollmentStep({
    super.key,
    required this.step,
    required this.captured,
    required this.busy,
    required this.onCapture,
    required this.onRetake,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final number = step + 1;
    final nextLabel = step == 4
        ? 'Finish enrollment'
        : 'Continue to signature ${number + 1}';

    return Column(
      children: [
        const Spacer(),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: .88, end: 1),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOutBack,
          builder: (context, value, child) => Transform.scale(
            scale: value,
            child: child,
          ),
          child: Container(
            width: 188,
            height: 188,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: captured
                  ? AppColors.tealLight
                  : AppColors.tealLight.withValues(alpha: .66),
            ),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: captured
                      ? const [AppColors.teal, Color(0xFF38AAA5)]
                      : const [AppColors.navyDark, AppColors.navy],
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x32148F8B),
                    blurRadius: 30,
                    offset: Offset(0, 14),
                  ),
                ],
              ),
              child: Icon(
                captured ? Icons.check_rounded : Icons.draw_rounded,
                color: Colors.white,
                size: 76,
              ),
            ),
          ),
        ),
        const SizedBox(height: 34),
        Text(
          captured
              ? 'Signature $number captured'
              : 'Signature $number of 5',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.displaySmall,
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 390),
          child: Text(
            captured
                ? 'Your reference is ready. Continue when you are comfortable with this capture.'
                : 'Sign naturally at your usual speed and pressure. Use the same signature you normally use.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppColors.muted,
                ),
          ),
        ),
        const Spacer(),
        if (!captured)
          FilledButton.icon(
            onPressed: onCapture,
            icon: const Icon(Icons.draw_rounded),
            label: Text('Start signature $number'),
          )
        else ...[
          FilledButton.icon(
            onPressed: busy ? null : onContinue,
            icon: busy
                ? const SizedBox.square(
                    dimension: 19,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(step == 4
                    ? Icons.lock_rounded
                    : Icons.arrow_forward_rounded),
            label: Text(busy ? 'Saving securely...' : nextLabel),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: busy ? null : onRetake,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retake this signature'),
          ),
        ],
      ],
    );
  }
}

class SignatureUnlockScreen extends ConsumerStatefulWidget {
  const SignatureUnlockScreen({super.key});

  @override
  ConsumerState<SignatureUnlockScreen> createState() =>
      _SignatureUnlockScreenState();
}

class _SignatureUnlockScreenState
    extends ConsumerState<SignatureUnlockScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController pulseController;
  late final Animation<double> pulse;
  bool busy = false;
  String? message;

  @override
  void initState() {
    super.initState();
    pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    pulse = Tween<double>(begin: .96, end: 1.04).animate(
      CurvedAnimation(parent: pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider).valueOrNull;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            children: [
              Row(
                children: [
                  const BrandMark(size: 42),
                  const SizedBox(width: 11),
                  Text(
                    'SignaTrust AI',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Sign out',
                    onPressed: busy ? null : signOut,
                    icon: const Icon(Icons.logout_rounded),
                  ),
                ],
              ),
              const Spacer(),
              ScaleTransition(
                scale: pulse,
                child: Container(
                  width: 204,
                  height: 204,
                  padding: const EdgeInsets.all(17),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.tealLight.withValues(alpha: .78),
                  ),
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppColors.navyDark, AppColors.teal],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x42148F8B),
                          blurRadius: 36,
                          offset: Offset(0, 16),
                        ),
                      ],
                    ),
                    child: busy
                        ? const Center(
                            child: SizedBox.square(
                              dimension: 38,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: Colors.white,
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.draw_rounded,
                            color: Colors.white,
                            size: 82,
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 36),
              Text(
                'Sign to unlock',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 10),
              Text(
                'Welcome back, ${user?.fullName.split(' ').first ?? 'User'}.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppColors.muted,
                    ),
              ),
              if (message != null) ...[
                const SizedBox(height: 18),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    message!,
                    key: ValueKey(message),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.danger,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              FilledButton.icon(
                onPressed: busy ? null : unlock,
                icon: const Icon(Icons.fingerprint_rounded),
                label: Text(busy ? 'Verifying...' : 'Start signature'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: busy ? null : signOut,
                child: const Text('Use another account'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> unlock() async {
    setState(() => message = null);

    final captured = await context.push<CapturedSignature>(
      '/capture?title=Unlock%20with%20signature',
    );
    if (captured == null || !mounted) return;

    setState(() => busy = true);
    try {
      final response = await ApiClient.instance.dio.post(
        '/signatures/verify',
        data: {
          'signature': captured.toJson(),
          'mode': 'balanced',
        },
      );
      final result = VerificationResultData.fromJson(
        response.data as Map<String, dynamic>,
      );

      if (!mounted) return;

      if (result.genuine) {
        ref.read(appLockProvider.notifier).unlock();
        context.go('/home');
      } else {
        setState(() {
          message = 'Signature not recognized. Please try again.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          message = ApiClient.instance.errorMessage(error);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> signOut() async {
    ref.read(appLockProvider.notifier).reset();
    await ref.read(sessionProvider.notifier).logout();
    if (mounted) context.go('/login');
  }
}

class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  String mode = 'balanced';
  bool busy = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Verify signature')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const PageHeader(
                title: 'Choose a verification mode',
                subtitle:
                    'Balanced mode improves usability. Secure mode lowers false acceptance but may reject more genuine signatures.',
              ),
              const SizedBox(height: 24),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'balanced',
                    label: Text('Balanced'),
                    icon: Icon(Icons.balance_rounded),
                  ),
                  ButtonSegment(
                    value: 'secure',
                    label: Text('Secure'),
                    icon: Icon(Icons.security_rounded),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (value) =>
                    setState(() => mode = value.first),
                showSelectedIcon: false,
              ),
              const SizedBox(height: 28),
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  children: [
                    Icon(
                      mode == 'secure'
                          ? Icons.shield_outlined
                          : Icons.verified_user_outlined,
                      color: AppColors.teal,
                      size: 58,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      mode == 'secure'
                          ? 'Security-prioritized decision'
                          : 'Balanced biometric decision',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      mode == 'secure'
                          ? 'Recommended when avoiding false acceptance is more important than convenience.'
                          : 'Recommended for normal application demonstrations and everyday verification.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: busy ? null : verify,
                icon: const Icon(Icons.draw_rounded),
                label: Text(
                  busy ? 'Analyzing behavioral data...' : 'Capture and verify',
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> verify() async {
    final captured = await context.push<CapturedSignature>(
      '/capture?title=Verification%20signature',
    );
    if (captured == null) return;

    setState(() => busy = true);
    try {
      final response = await ApiClient.instance.dio.post(
        '/signatures/verify',
        data: {'signature': captured.toJson(), 'mode': mode},
      );
      final result = VerificationResultData.fromJson(
        response.data as Map<String, dynamic>,
      );
      if (mounted) context.pushReplacement('/result', extra: result);
    } catch (error) {
      if (mounted) {
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(error),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class SignatureCaptureScreen extends StatefulWidget {
  final String title;

  const SignatureCaptureScreen({
    super.key,
    required this.title,
  });

  @override
  State<SignatureCaptureScreen> createState() =>
      _SignatureCaptureScreenState();
}

class _SignatureCaptureScreenState extends State<SignatureCaptureScreen> {
  final points = <SignaturePointData>[];
  final stopwatch = Stopwatch();
  Size canvasSize = Size.zero;

  @override
  void initState() {
    super.initState();
    stopwatch.start();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            TextButton(
              onPressed: points.isEmpty ? null : clear,
              child: const Text('Clear'),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
            child: Column(
              children: [
                Text(
                  'Use your normal speed and pressure. Keep the full signature inside the canvas.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      canvasSize = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );

                      return Listener(
                        onPointerDown: addPoint,
                        onPointerMove: addPoint,
                        onPointerUp: (event) {
                          addPoint(event);
                          setState(() {});
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(
                              color: const Color(0xFFD6E0E7),
                              width: 1.5,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x120D2639),
                                blurRadius: 20,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CustomPaint(
                                painter: _SignatureGuidePainter(),
                              ),
                              CustomPaint(
                                painter: SignaturePainter(points),
                                child: const SizedBox.expand(),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: points.length < 12 ? null : save,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(
                    points.length < 12
                        ? 'Continue signing'
                        : 'Use this signature',
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  void addPoint(PointerEvent event) {
    final local = event.localPosition;
    final kind = switch (event.kind) {
      PointerDeviceKind.stylus => 'stylus',
      PointerDeviceKind.touch => 'touch',
      PointerDeviceKind.mouse => 'mouse',
      _ => 'unknown',
    };

    points.add(
      SignaturePointData(
        x: local.dx.clamp(0, canvasSize.width).toDouble(),
        y: local.dy.clamp(0, canvasSize.height).toDouble(),
        timestampMs: stopwatch.elapsedMicroseconds / 1000.0,
        pressure: event.pressure.isFinite ? event.pressure : 0.0,
        touchArea: math.max(event.size, 0.0),
        pointerType: kind,
      ),
    );
    setState(() {});
  }

  void clear() {
    points.clear();
    stopwatch
      ..reset()
      ..start();
    setState(() {});
  }

  void save() => context.pop(
        CapturedSignature(
          points: List.unmodifiable(points),
          width: canvasSize.width,
          height: canvasSize.height,
        ),
      );
}

class _SignatureGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = const Color(0xFFE8EEF2)
      ..strokeWidth = 1.2;

    canvas.drawLine(
      Offset(size.width * .08, size.height * .72),
      Offset(size.width * .92, size.height * .72),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SignatureGuidePainter oldDelegate) => false;
}

class SignaturePainter extends CustomPainter {
  final List<SignaturePointData> points;

  SignaturePainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final paint = Paint()
      ..color = AppColors.navy
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final path = Path()..moveTo(points.first.x, points.first.y);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].x, points[i].y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant SignaturePainter oldDelegate) =>
      oldDelegate.points.length != points.length;
}

class ResultScreen extends StatelessWidget {
  final VerificationResultData result;

  const ResultScreen({
    super.key,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final color = result.genuine ? AppColors.success : AppColors.danger;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: result.probability),
                duration: const Duration(milliseconds: 1100),
                curve: Curves.easeOutCubic,
                builder: (_, value, __) => SizedBox(
                  width: 180,
                  height: 180,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: value,
                        strokeWidth: 14,
                        color: color,
                        backgroundColor: color.withValues(alpha: .12),
                      ),
                      Icon(
                        result.genuine
                            ? Icons.verified_rounded
                            : Icons.gpp_bad_rounded,
                        color: color,
                        size: 66,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                result.genuine
                    ? 'Genuine signature'
                    : 'Signature rejected',
                style: Theme.of(context)
                    .textTheme
                    .displaySmall
                    ?.copyWith(color: color),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                result.genuine
                    ? 'The captured behavioral pattern met the selected verification threshold.'
                    : 'The behavioral pattern did not meet the selected verification threshold.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 30),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  children: [
                    metric(
                      'Confidence',
                      '${(result.probability * 100).toStringAsFixed(1)}%',
                    ),
                    metric(
                      'Required threshold',
                      '${(result.threshold * 100).toStringAsFixed(1)}%',
                    ),
                    metric(
                      'Cosine similarity',
                      result.cosine.toStringAsFixed(3),
                    ),
                    metric(
                      'Capture quality',
                      '${(result.quality * 100).toStringAsFixed(0)}%',
                    ),
                    metric(
                      'Mode',
                      result.mode[0].toUpperCase() + result.mode.substring(1),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => context.go('/sign'),
                child: const Text('Return to signature center'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget metric(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
          ],
        ),
      );
}
