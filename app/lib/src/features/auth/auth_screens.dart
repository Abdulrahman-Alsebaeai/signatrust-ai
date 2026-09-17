import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../core/api_client.dart';

String? _validateFullName(String? value) {
  final name = value?.trim() ?? '';

  if (name.isEmpty) {
    return 'Enter your full name';
  }

  if (name.length < 2) {
    return 'Use at least 2 characters';
  }

  if (name.length > 120) {
    return 'Full name is too long';
  }

  return null;
}

String? _validateEmail(String? value) {
  final email = value?.trim() ?? '';

  if (email.isEmpty) {
    return 'Enter your email address';
  }

  final validEmail = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email);

  if (!validEmail) {
    return 'Enter a valid email address';
  }

  return null;
}

String? _validatePhone(String? value) {
  final phone = value?.trim() ?? '';

  // Phone number is optional.
  if (phone.isEmpty) {
    return null;
  }

  final validPhone = RegExp(r'^\+?[0-9]{7,15}$').hasMatch(phone);

  if (!validPhone) {
    return 'Enter a valid phone number';
  }

  return null;
}

String? _validateLoginPassword(String? value) {
  if ((value ?? '').isEmpty) {
    return 'Enter your password';
  }

  return null;
}

String? _validateNewPassword(String? value) {
  final password = value ?? '';

  if (password.isEmpty) {
    return 'Enter a password';
  }

  if (password.length < 10) {
    return 'Use at least 10 characters';
  }

  if (!RegExp(r'[A-Z]').hasMatch(password)) {
    return 'Add one uppercase letter';
  }

  if (!RegExp(r'[a-z]').hasMatch(password)) {
    return 'Add one lowercase letter';
  }

  if (!RegExp(r'[0-9]').hasMatch(password)) {
    return 'Add one number';
  }

  return null;
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BrandMark(size: 86),
          SizedBox(height: 22),
          CircularProgressIndicator(),
        ],
      ),
    ),
  );
}

class AuthFrame extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  const AuthFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const BrandMark(size: 64),
                const SizedBox(height: 28),
                Text(title, style: Theme.of(context).textTheme.displaySmall),
                const SizedBox(height: 10),
                Text(
                  subtitle,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(color: AppColors.muted),
                ),
                const SizedBox(height: 32),
                child,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  final password = TextEditingController();
  bool obscure = true;
  bool busy = false;
  @override
  Widget build(BuildContext context) => AuthFrame(
    title: 'Welcome back',
    subtitle: 'Access your secure biometric signature workspace.',
    child: Form(
      key: form,
      child: Column(
        children: [
          TextFormField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email address',
              prefixIcon: Icon(Icons.alternate_email_rounded),
            ),
            validator: _validateEmail,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: password,
            obscureText: obscure,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                onPressed: () => setState(() => obscure = !obscure),
                icon: Icon(
                  obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
            validator: _validateLoginPassword,
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: busy ? null : submit,
            child:
                busy
                    ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                    : const Text('Sign in securely'),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => context.go('/register'),
            child: const Text('Create a new account'),
          ),
        ],
      ),
    ),
  );
  Future<void> submit() async {
    if (!form.currentState!.validate()) {
      return;
    }

    setState(() => busy = true);

    try {
      await ref
          .read(sessionProvider.notifier)
          .login(email.text.trim(), password.text);

      if (mounted) {
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
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final email = TextEditingController();
  final phone = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  bool acceptedLegal = false;

  @override
  Widget build(BuildContext context) => AuthFrame(
    title: 'Create your account',
    subtitle: 'Set up your secure identity before enrolling your signature.',
    child: Form(
      key: form,
      child: Column(
        children: [
          TextFormField(
            controller: name,
            decoration: const InputDecoration(
              labelText: 'Full name',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
            validator: _validateFullName,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Email address',
              prefixIcon: Icon(Icons.alternate_email_rounded),
            ),
            validator: _validateEmail,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone number',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
            validator: _validatePhone,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              prefixIcon: Icon(Icons.lock_outline_rounded),
              helperText:
                  'At least 10 characters with uppercase, lowercase, and a number.',
            ),
            validator: _validateNewPassword,
          ),
          const SizedBox(height: 14),
          FormField<bool>(
            initialValue: acceptedLegal,
            validator: (_) => acceptedLegal
                ? null
                : 'Accept the Terms of Use and Privacy Policy',
            builder: (field) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Checkbox(
                      value: acceptedLegal,
                      onChanged: busy
                          ? null
                          : (value) {
                              setState(() {
                                acceptedLegal = value ?? false;
                              });
                              field.didChange(acceptedLegal);
                            },
                    ),
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('I agree to the '),
                          TextButton(
                            onPressed: () => context.push('/terms'),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('Terms of Use'),
                          ),
                          const Text(' and '),
                          TextButton(
                            onPressed: () => context.push('/privacy'),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('Privacy Policy'),
                          ),
                          const Text('.'),
                        ],
                      ),
                    ),
                  ],
                ),
                if (field.hasError)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 2),
                    child: Text(
                      field.errorText!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: busy ? null : submit,
            child:
                busy
                    ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                    : const Text('Create account'),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => context.go('/login'),
            child: const Text('I already have an account'),
          ),
        ],
      ),
    ),
  );
  Future<void> submit() async {
    if (!form.currentState!.validate()) {
      return;
    }

    setState(() => busy = true);

    try {
      await ref
          .read(sessionProvider.notifier)
          .register(
            name.text.trim(),
            email.text.trim(),
            phone.text.trim(),
            password.text,
            acceptedLegal: acceptedLegal,
          );

      if (mounted) {
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
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }
}
