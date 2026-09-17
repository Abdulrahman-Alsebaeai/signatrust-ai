import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../documents/documents_screen.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  bool loading = true;
  Map<String, dynamic> stats = {};
  List<Map<String, dynamic>> users = [];
  List<Map<String, dynamic>> documents = [];
  List<Map<String, dynamic>> verifications = [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final results = await Future.wait([
        ApiClient.instance.dio.get('/admin/stats'),
        ApiClient.instance.dio.get('/admin/users'),
        ApiClient.instance.dio.get('/admin/shared-documents'),
        ApiClient.instance.dio.get('/admin/verifications'),
      ]);
      stats = Map<String, dynamic>.from(results[0].data as Map);
      users = List<Map<String, dynamic>>.from(results[1].data as List);
      documents = List<Map<String, dynamic>>.from(results[2].data as List);
      verifications = List<Map<String, dynamic>>.from(results[3].data as List);
    } catch (error) {
      if (mounted) {
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(error),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Administrator console')),
      body: SafeArea(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
                  children: [
                    const PageHeader(
                      title: 'System oversight',
                      subtitle:
                          'Review local accounts, shared documents, verification activity, and AI readiness.',
                    ),
                    const SizedBox(height: 22),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _Metric(
                          label: 'Users',
                          value: '${stats['users'] ?? 0}',
                          icon: Icons.people_outline_rounded,
                        ),
                        _Metric(
                          label: 'Enrolled',
                          value: '${stats['enrolled_users'] ?? 0}',
                          icon: Icons.fingerprint_rounded,
                        ),
                        _Metric(
                          label: 'Checks',
                          value: '${stats['verifications'] ?? 0}',
                          icon: Icons.verified_user_outlined,
                        ),
                        _Metric(
                          label: 'AI model',
                          value: stats['model_ready'] == true ? 'Ready' : 'Missing',
                          icon: Icons.memory_rounded,
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),
                    _SectionTitle(
                      title: 'User accounts',
                      count: users.length,
                    ),
                    const SizedBox(height: 12),
                    if (users.isEmpty)
                      const _AdminEmpty(message: 'No user accounts are available.')
                    else
                      ...users.map(userTile),
                    const SizedBox(height: 26),
                    _SectionTitle(
                      title: 'Shared documents',
                      count: documents.length,
                    ),
                    const SizedBox(height: 12),
                    if (documents.isEmpty)
                      const _AdminEmpty(
                        message: 'No documents are currently shared for review.',
                      )
                    else
                      ...documents.take(20).map(documentTile),
                    const SizedBox(height: 26),
                    _SectionTitle(
                      title: 'Recent verification activity',
                      count: verifications.length,
                    ),
                    const SizedBox(height: 12),
                    if (verifications.isEmpty)
                      const _AdminEmpty(
                        message: 'No verification activity has been recorded.',
                      )
                    else
                      ...verifications.take(30).map(verificationTile),
                  ],
                ),
              ),
      ),
    );
  }

  Widget userTile(Map<String, dynamic> user) {
    final active = user['is_active'] == true;
    final name = user['full_name'] as String? ?? 'User';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: AppColors.tealLight,
              child: Text(name.substring(0, 1).toUpperCase()),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 3),
                  Text(
                    '${user['email']}  •  ${user['has_enrollment'] == true ? 'Enrolled' : 'Not enrolled'}',
                  ),
                ],
              ),
            ),
            Switch(
              value: active,
              onChanged: user['role'] == 'admin'
                  ? null
                  : (value) => toggle(user['id'] as int, value),
            ),
          ],
        ),
      ),
    );
  }

  Widget documentTile(Map<String, dynamic> item) {
    final owner = item['owner_name'] as String? ?? 'User ${item['owner_id']}';
    final probability =
        ((item['signature_probability'] as num?)?.toDouble() ?? 0) * 100;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () async {
            await Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => DocumentViewerScreen(
                  document: item,
                  administrator: true,
                ),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: AppColors.tealLight,
                  child: Icon(
                    Icons.verified_rounded,
                    color: AppColors.success,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item['original_name'] as String? ?? 'Document',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text('$owner  •  ${probability.toStringAsFixed(1)}%'),
                    ],
                  ),
                ),
                const Icon(
                  Icons.visibility_outlined,
                  color: AppColors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget verificationTile(Map<String, dynamic> item) {
    final genuine = item['decision'] == 'genuine';
    final color = genuine ? AppColors.success : AppColors.danger;
    final createdAt = DateTime.tryParse(item['created_at'] as String? ?? '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: .10),
              child: Icon(
                genuine ? Icons.verified_outlined : Icons.gpp_bad_outlined,
                color: color,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    genuine ? 'Genuine decision' : 'Rejected decision',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    createdAt == null
                        ? '${item['mode']} mode'
                        : '${DateFormat.yMMMd().add_jm().format(createdAt.toLocal())}  •  ${item['mode']}',
                  ),
                ],
              ),
            ),
            Text(
              '${(((item['score'] as num?)?.toDouble() ?? 0) * 100).toStringAsFixed(1)}%',
              style: TextStyle(color: color, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> toggle(int id, bool active) async {
    try {
      await ApiClient.instance.dio.post(
        '/admin/users/$id/${active ? 'activate' : 'deactivate'}',
      );
      await load();
    } catch (error) {
      if (mounted) {
        AppNotice.show(
          context,
          ApiClient.instance.errorMessage(error),
          error: true,
        );
      }
    }
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _Metric({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: (MediaQuery.sizeOf(context).width - 50) / 2,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.teal),
          const SizedBox(height: 15),
          Text(value, style: Theme.of(context).textTheme.headlineMedium),
          Text(label),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final int count;

  const _SectionTitle({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
        Text('$count', style: const TextStyle(color: AppColors.teal)),
      ],
    );
  }
}

class _AdminEmpty extends StatelessWidget {
  final String message;

  const _AdminEmpty({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: AppColors.muted),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
