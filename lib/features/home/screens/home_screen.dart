import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:stagelink_resident/core/utils/app_error_message.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_mode_provider.dart';

DateTime _currentWeekStartSaturdayLocal() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final daysSinceSaturday = (today.weekday - DateTime.saturday + 7) % 7;
  return today.subtract(Duration(days: daysSinceSaturday));
}

final myLecturesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;
  final me = await Supabase.instance.client
      .from('profiles')
      .select('subject_id')
      .eq('id', uid)
      .maybeSingle();
  final subjectId = me?['subject_id'] as String?;
  if (subjectId == null) return [];

  final weekStartLocal = _currentWeekStartSaturdayLocal();
  final weekEndLocal = weekStartLocal.add(const Duration(days: 7));
  final weekStartUtcIso = weekStartLocal.toUtc().toIso8601String();
  final weekEndUtcIso = weekEndLocal.toUtc().toIso8601String();

  final res = await Supabase.instance.client
      .from('lectures')
      .select(
        'id, resident_id, start_at, end_at, practical_sessions!inner(title, subjects(name, location), subject_id)',
      )
      .eq('practical_sessions.subject_id', subjectId)
      .or('resident_id.is.null,resident_id.eq.$uid')
      .gte('start_at', weekStartUtcIso)
      .lt('start_at', weekEndUtcIso)
      .order('start_at', ascending: false);

  return List<Map<String, dynamic>>.from(res as List);
});

class ResidentHomeScreen extends ConsumerWidget {
  const ResidentHomeScreen({super.key});

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
    final lecturesAsync = ref.watch(myLecturesProvider);
    final themeMode = ref.watch(themeModeProvider);
    final isDark = themeMode == ThemeMode.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('الجلسات السريرية'),
        actions: [
          IconButton(
            icon: const Icon(Icons.video_call_rounded),
            onPressed: () => context.push('/practical-videos/create'),
          ),
          IconButton(
            tooltip: isDark ? 'الوضع النهاري' : 'الوضع الليلي',
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
            ),
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
        ],
      ),
      body: lecturesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
        data: (lectures) {
          final muted = Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.6);
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(myLecturesProvider);
              await ref.read(myLecturesProvider.future);
            },
            child: lectures.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 180),
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.event_note_rounded,
                              size: 72,
                              color: muted.withValues(alpha: 0.4),
                            ),
                            const Gap(16),
                            const Text('لا توجد محاضرات مطابقة حالياً'),
                          ],
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: lectures.length,
                    itemBuilder: (context, i) {
                      final l = lectures[i];
                      final session =
                          l['practical_sessions'] as Map<String, dynamic>?;
                      final subject =
                          (session?['subjects']
                              as Map<String, dynamic>?)?['name'] ??
                          '—';
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => context.push('/scan/${l['id']}'),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryContainer,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Icon(
                                    Icons.bluetooth_searching_rounded,
                                    color: AppColors.primary,
                                    size: 28,
                                  ),
                                ),
                                const Gap(14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        session?['title'] as String? ?? '—',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                      Text(
                                        subject,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyMedium,
                                      ),
                                      const Gap(4),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.event_outlined,
                                            size: 13,
                                            color: muted,
                                          ),
                                          const Gap(4),
                                          Text(
                                            _formatLectureLine(l),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(fontSize: 12),
                                          ),
                                          const Gap(8),
                                          Icon(
                                            Icons.location_on_outlined,
                                            size: 13,
                                            color: muted,
                                          ),
                                          const Gap(4),
                                          Expanded(
                                            child: Text(
                                              ((session?['subjects']
                                                          as Map<
                                                            String,
                                                            dynamic
                                                          >?)?['location']
                                                      as String?) ??
                                                  '',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyMedium
                                                  ?.copyWith(fontSize: 12),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(
                                  Icons.bluetooth_searching_rounded,
                                  color: AppColors.primary,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ).animate(delay: (40 * i).ms).fadeIn();
                    },
                  ),
          );
        },
      ),
    );
  }
}
