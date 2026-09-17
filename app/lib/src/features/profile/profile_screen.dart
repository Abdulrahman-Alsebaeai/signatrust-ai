import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider).valueOrNull;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const PageHeader(
          title: 'Profile',
          subtitle: 'Manage your account and security preferences.',
        ),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 38,
                backgroundColor: AppColors.tealLight,
                child: Icon(
                  Icons.person_rounded,
                  color: AppColors.navy,
                  size: 42,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?.fullName ?? '',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(user?.email ?? ''),
                    const SizedBox(height: 7),
                    Text(
                      user?.role == 'admin' ? 'Administrator' : 'Verified user',
                      style: const TextStyle(
                        color: AppColors.teal,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _ProfileItem(
          icon: Icons.edit_outlined,
          title: 'Edit personal information',
          onTap:
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const EditProfileScreen()),
              ),
        ),
        _ProfileItem(
          icon: Icons.lock_outline_rounded,
          title: 'Change password',
          onTap:
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
              ),
        ),
        if (user?.role == 'admin')
          _ProfileItem(
            icon: Icons.admin_panel_settings_outlined,
            title: 'Administrator console',
            onTap: () => context.push('/admin'),
          ),
        _ProfileItem(
          icon: Icons.logout_rounded,
          title: 'Sign out',
          color: AppColors.danger,
          onTap: () async {
            await ref.read(sessionProvider.notifier).logout();
            if (context.mounted) context.go('/login');
          },
        ),
      ],
    );
  }
}

class _ProfileItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final Color? color;
  const _ProfileItem({
    required this.icon,
    required this.title,
    required this.onTap,
    this.color,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        leading: Icon(icon, color: color ?? AppColors.navy),
        title: Text(title, style: TextStyle(color: color)),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    ),
  );
}

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});
  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final TextEditingController name;
  late final TextEditingController phone;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    final u = ref.read(sessionProvider).valueOrNull!;
    name = TextEditingController(text: u.fullName);
    phone = TextEditingController(text: u.phone);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Edit profile')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const PageHeader(
            title: 'Personal information',
            subtitle: 'Update the information stored securely on this device.',
          ),
          const SizedBox(height: 24),
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Full name'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: phone,
            decoration: const InputDecoration(labelText: 'Phone number'),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : save,
            child: const Text('Save changes'),
          ),
        ],
      ),
    ),
  );
  Future<void> save() async {
    setState(() => busy = true);
    try {
      await ApiClient.instance.dio.patch(
        '/users/me',
        data: {'full_name': name.text, 'phone': phone.text},
      );
      await ref.read(sessionProvider.notifier).refreshUser();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted)
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(e),
          error: true,
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final current = TextEditingController();
  final next = TextEditingController();
  bool busy = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Change password')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const PageHeader(
            title: 'Account password',
            subtitle:
                'Use at least ten characters with uppercase, lowercase, and numeric characters.',
          ),
          const SizedBox(height: 24),
          TextField(
            controller: current,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Current password'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: next,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'New password'),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : save,
            child: const Text('Update password'),
          ),
        ],
      ),
    ),
  );
  Future<void> save() async {
    setState(() => busy = true);
    try {
      await ApiClient.instance.dio.post(
        '/users/me/change-password',
        data: {'current_password': current.text, 'new_password': next.text},
      );
      if (mounted) {
        AppNotice.show(context, 'Password changed successfully.');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted)
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(e),
          error: true,
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
