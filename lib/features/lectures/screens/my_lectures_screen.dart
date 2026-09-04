import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:stagelink_resident/core/utils/app_error_message.dart';
import '../../../core/theme/app_theme.dart';

final myLecturesDetailProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;
  final lectures = await Supabase.instance.client
      .from('lectures')
      .select(
        'id, start_at, end_at, location, attendance_window_start, attendance_window_end, practical_sessions(title)',
      )
      .eq('resident_id', uid)
      .order('start_at', ascending: false);

  final lectureIds = (lectures as List).map((l) => l['id'] as String).toList();
  final attendanceCounts = lectureIds.isEmpty
      ? <dynamic>[]
      : await Supabase.instance.client
            .from('practical_attendance')
            .select('lecture_id')
            .inFilter('lecture_id', lectureIds);

  final countMap = <String, int>{};
  for (final a in attendanceCounts) {
    final id = a['lecture_id'] as String;
    countMap[id] = (countMap[id] ?? 0) + 1;
  }

  return lectures.map<Map<String, dynamic>>((l) {
    return {...l, 'attendance_count': countMap[l['id'] as String] ?? 0};
  }).toList();
});

class MyLecturesScreen extends ConsumerWidget {
  const MyLecturesScreen({super.key});

  String _formatLectureLine(Map<String, dynamic> lecture) {
    final start = DateTime.tryParse(lecture['start_at'] as String? ?? '');
    final end = DateTime.tryParse(lecture['end_at'] as String? ?? '');
    if (start == null) return '—';
    final dateStr = DateFormat('yyyy-MM-dd').format(start);
    final timeStr = DateFormat('HH:mm').format(start);
    final dur = end == null ? '' : '${end.difference(start).inMinutes} د';
    final durStr = dur.isEmpty ? '' : ' · $dur';
    return '$dateStr · $timeStr$durStr';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lecturesAsync = ref.watch(myLecturesDetailProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('محاضراتي')),
      body: lecturesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
        data: (lectures) => lectures.isEmpty
            ? const Center(child: Text('لا توجد محاضرات'))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                itemCount: lectures.length,
                itemBuilder: (context, i) {
                  final l = lectures[i];
                  final muted = Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6);
                  final session =
                      l['practical_sessions'] as Map<String, dynamic>?;
                  final count = l['attendance_count'] as int;

                  final now = DateTime.now();
                  final windowStart = DateTime.tryParse(
                    l['attendance_window_start'] as String? ?? '',
                  );
                  final windowEnd = DateTime.tryParse(
                    l['attendance_window_end'] as String? ?? '',
                  );
                  final isOpen =
                      windowStart != null &&
                      windowEnd != null &&
                      now.isAfter(windowStart) &&
                      now.isBefore(windowEnd);

                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: null,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    session?['title'] as String? ?? '—',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                if (isOpen)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.success.withValues(
                                        alpha: 0.1,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      'مفتوح',
                                      style: TextStyle(
                                        color: AppColors.success,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const Gap(6),
                            Row(
                              children: [
                                Icon(
                                  Icons.event_outlined,
                                  size: 14,
                                  color: muted,
                                ),
                                const Gap(4),
                                Text(
                                  _formatLectureLine(l),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                const Gap(12),
                                Icon(
                                  Icons.location_on_outlined,
                                  size: 14,
                                  color: muted,
                                ),
                                const Gap(4),
                                Text(
                                  l['location'] as String? ?? '',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                            const Gap(10),
                            Text(
                              'عدد الحضور: $count',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const Gap(10),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () =>
                                        context.push('/scan/${l['id']}'),
                                    icon: const Icon(Icons.login_rounded),
                                    label: const Text('تسجيل دخول'),
                                  ),
                                ),
                                const Gap(8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () =>
                                        context.push('/scan/${l['id']}'),
                                    icon: const Icon(Icons.logout_rounded),
                                    label: const Text('تسجيل خروج'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ).animate(delay: (40 * i).ms).fadeIn();
                },
              ),
      ),
    );
  }
}
