import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool loading = true;
  List<Map<String, dynamic>> items = [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final response = await ApiClient.instance.dio.get('/signatures/history');
      items = List<Map<String, dynamic>>.from(response.data as List);
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
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(
            title: 'Verification history',
            subtitle: 'Review decisions generated for your account.',
          ),
          const SizedBox(height: 22),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? const EmptyState(
                        icon: Icons.history_toggle_off_rounded,
                        title: 'No verification activity',
                        message: 'Completed signature checks will appear here.',
                      )
                    : RefreshIndicator(
                        onRefresh: load,
                        child: ListView.separated(
                          itemCount: items.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (_, index) {
                            final item = items[index];
                            final genuine = item['decision'] == 'genuine';
                            final color = genuine
                                ? AppColors.success
                                : AppColors.danger;
                            final createdAt = DateTime.parse(
                              item['created_at'] as String,
                            ).toLocal();
                            final score = (item['score'] as num).toDouble();

                            return Container(
                              padding: const EdgeInsets.all(17),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(19),
                              ),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: color.withValues(alpha: .11),
                                    child: Icon(
                                      genuine
                                          ? Icons.verified_outlined
                                          : Icons.gpp_bad_outlined,
                                      color: color,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          genuine
                                              ? 'Genuine signature'
                                              : 'Signature rejected',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${DateFormat.yMMMd().add_jm().format(createdAt)}  •  ${item['mode']}',
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '${(score * 100).toStringAsFixed(1)}%',
                                    style: TextStyle(
                                      color: color,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
