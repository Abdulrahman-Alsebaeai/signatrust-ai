import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const List<String> images = <String>[
    'https://images.unsplash.com/photo-1563013544-824ae1b704d3'
        '?auto=format&fit=crop&w=1400&q=88',
    'https://images.unsplash.com/photo-1450101499163-c8848c66ca85'
        '?auto=format&fit=crop&w=1400&q=88',
    'https://images.unsplash.com/photo-1556742049-0cfed4f6a45d'
        '?auto=format&fit=crop&w=1400&q=88',
  ];

  late final PageController _pageController;

  Timer? _timer;
  int _page = 0;
  bool _openingVerification = false;

  @override
  void initState() {
    super.initState();

    _pageController = PageController();

    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted ||
          !_pageController.hasClients ||
          images.isEmpty ||
          _openingVerification) {
        return;
      }

      final int nextPage = (_page + 1) % images.length;

      _pageController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  Future<void> _openVerification({required bool hasEnrollment}) async {
    if (_openingVerification) {
      return;
    }

    setState(() {
      _openingVerification = true;
    });

    try {
      await context.push(hasEnrollment ? '/verify' : '/enrollment');
    } finally {
      if (mounted) {
        setState(() {
          _openingVerification = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final user = session.valueOrNull;

    final String fullName = user?.fullName.trim() ?? '';

    final String firstName =
        fullName.isNotEmpty ? fullName.split(RegExp(r'\s+')).first : 'User';

    final double screenWidth = MediaQuery.sizeOf(context).width;

    final double carouselHeight = (screenWidth * 0.43).clamp(150.0, 185.0);

    final double verificationButtonSize = (screenWidth * 0.37).clamp(
      128.0,
      150.0,
    );

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  const BrandMark(size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SignaTrust AI',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Welcome, $firstName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  if (user?.role == 'admin') ...[
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Administrator console',
                      onPressed: () {
                        context.push('/admin');
                      },
                      icon: const Icon(Icons.admin_panel_settings_outlined),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 22),
            _ImageCarousel(
              controller: _pageController,
              images: images,
              page: _page,
              height: carouselHeight,
              onPageChanged: (int value) {
                if (!mounted) {
                  return;
                }

                setState(() {
                  _page = value;
                });
              },
            ),
            const SizedBox(height: 34),
            Center(
              child: _VerificationButton(
                size: verificationButtonSize,
                loading: _openingVerification,
                onTap: () {
                  _openVerification(hasEnrollment: user?.hasEnrollment == true);
                },
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Verify signature',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 7),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Start a protected behavioral signature check.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageCarousel extends StatelessWidget {
  final PageController controller;
  final List<String> images;
  final int page;
  final double height;
  final ValueChanged<int> onPageChanged;

  const _ImageCarousel({
    required this.controller,
    required this.images,
    required this.page,
    required this.height,
    required this.onPageChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return SizedBox(
        height: height,
        child: const ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(25)),
          child: _ImageFallback(),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(25),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F0D2639),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(25),
            child: PageView.builder(
              controller: controller,
              itemCount: images.length,
              onPageChanged: onPageChanged,
              itemBuilder: (BuildContext context, int index) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      images[index],
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                      loadingBuilder: (
                        BuildContext context,
                        Widget child,
                        ImageChunkEvent? progress,
                      ) {
                        if (progress == null) {
                          return child;
                        }

                        return const _ImageFallback(loading: true);
                      },
                      errorBuilder: (
                        BuildContext context,
                        Object error,
                        StackTrace? stackTrace,
                      ) {
                        return const _ImageFallback();
                      },
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x050D2639), Color(0x4D0D2639)],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: List<Widget>.generate(images.length, (int index) {
            final bool selected = index == page;

            return AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              width: selected ? 22 : 7,
              height: 7,
              decoration: BoxDecoration(
                color: selected ? AppColors.teal : const Color(0xFFD4DEE5),
                borderRadius: BorderRadius.circular(20),
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _ImageFallback extends StatelessWidget {
  final bool loading;

  const _ImageFallback({this.loading = false});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.navyDark, AppColors.teal],
        ),
      ),
      child: _FallbackContent(),
    );
  }
}

class _FallbackContent extends StatelessWidget {
  const _FallbackContent();

  @override
  Widget build(BuildContext context) {
    final _ImageFallback? parent =
        context.findAncestorWidgetOfExactType<_ImageFallback>();

    final bool loading = parent?.loading ?? false;

    return Center(
      child:
          loading
              ? const SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
              : const Icon(
                Icons.security_rounded,
                color: Colors.white,
                size: 48,
              ),
    );
  }
}

class _VerificationButton extends StatefulWidget {
  final VoidCallback onTap;
  final double size;
  final bool loading;

  const _VerificationButton({
    required this.onTap,
    required this.size,
    required this.loading,
  });

  @override
  State<_VerificationButton> createState() => _VerificationButtonState();
}

class _VerificationButtonState extends State<_VerificationButton> {
  bool pressed = false;

  void _resetPressedState() {
    if (!mounted) {
      return;
    }

    setState(() {
      pressed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Verify signature',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown:
            widget.loading
                ? null
                : (_) {
                  setState(() {
                    pressed = true;
                  });
                },
        onTapCancel: widget.loading ? null : _resetPressedState,
        onTapUp:
            widget.loading
                ? null
                : (_) {
                  _resetPressedState();
                  widget.onTap();
                },
        child: AnimatedScale(
          scale: pressed ? 0.94 : 1,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: SizedBox.square(
            dimension: widget.size,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.tealLight.withOpacity(0.72),
              ),
              child: Padding(
                padding: const EdgeInsets.all(11),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.navy, AppColors.teal],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x4A148F8B),
                        blurRadius: 32,
                        offset: Offset(0, 13),
                      ),
                    ],
                  ),
                  child: Center(
                    child:
                        widget.loading
                            ? const SizedBox.square(
                              dimension: 34,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: Colors.white,
                              ),
                            )
                            : Icon(
                              Icons.draw_rounded,
                              color: Colors.white,
                              size: widget.size * 0.40,
                            ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
