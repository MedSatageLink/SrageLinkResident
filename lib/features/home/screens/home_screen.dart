import 'dart:ui' as ui;

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

final residentSubjectsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;
  final res = await Supabase.instance.client
      .from('user_subject_assignments')
      .select('subject_id, subjects(id, name, location, rotation_order)')
      .eq('user_id', uid)
      .order('created_at');

  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final row in (res as List)) {
    final map = Map<String, dynamic>.from(row as Map);
    final subject = map['subjects'] as Map<String, dynamic>?;
    final subjectId = subject?['id'] as String?;
    if (subjectId == null || seen.contains(subjectId)) continue;
    seen.add(subjectId);
    out.add(subject!);
  }
  out.sort((a, b) {
    final ao = (a['rotation_order'] as int?) ?? 1 << 30;
    final bo = (b['rotation_order'] as int?) ?? 1 << 30;
    if (ao != bo) return ao.compareTo(bo);
    final an = (a['name'] as String? ?? '').trim();
    final bn = (b['name'] as String? ?? '').trim();
    return an.compareTo(bn);
  });
  return out;
});

final myLecturesBySubjectProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      subjectId,
    ) async {
      final uid = Supabase.instance.client.auth.currentUser!.id;

      final weekStartLocal = _currentWeekStartSaturdayLocal();
      final weekEndLocal = weekStartLocal.add(const Duration(days: 7));
      final weekStartUtcIso = weekStartLocal.toUtc().toIso8601String();
      final weekEndUtcIso = weekEndLocal.toUtc().toIso8601String();

      final res = await Supabase.instance.client
          .from('lectures')
          .select(
            'id, resident_id, start_at, end_at, target_category_id, categories(name), practical_sessions!inner(title, subjects(name, location), subject_id)',
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

  DateTime _toSyriaTime(DateTime value) {
    const syriaOffset = Duration(hours: 3);
    return (value.isUtc ? value : value.toUtc()).add(syriaOffset);
  }

  String _formatLectureLine(Map<String, dynamic> lecture) {
    final startRaw = DateTime.tryParse(lecture['start_at'] as String? ?? '');
    final endRaw = DateTime.tryParse(lecture['end_at'] as String? ?? '');
    final start = startRaw == null ? null : _toSyriaTime(startRaw);
    final end = endRaw == null ? null : _toSyriaTime(endRaw);
    if (start == null) return '—';
    final dateStr = DateFormat('yyyy-MM-dd').format(start);
    final timeStr = DateFormat('HH:mm').format(start);
    final dur = end == null ? '' : '${end.difference(start).inMinutes} د';
    final durStr = dur.isEmpty ? '' : ' · $dur';
    return '$dateStr · $timeStr$durStr';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subjectsAsync = ref.watch(residentSubjectsProvider);
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
      body: subjectsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
        data: (subjects) {
          final muted = Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.6);
          if (subjects.isEmpty) {
            return ListView(
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
                      const Text('لا توجد مواد مخصصة لهذا المقيم'),
                    ],
                  ),
                ),
              ],
            );
          }

          return DefaultTabController(
            length: subjects.length,
            child: Column(
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: Directionality(
                    textDirection: ui.TextDirection.ltr,
                    child: TabBar(
                      isScrollable: true,
                      tabs: subjects
                          .map((s) => Tab(text: s['name'] as String? ?? '—'))
                          .toList(),
                    ),
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: subjects
                        .map(
                          (s) => _SubjectLecturesTab(
                            subjectId: s['id'] as String,
                            formatLectureLine: _formatLectureLine,
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SubjectLecturesTab extends ConsumerWidget {
  final String subjectId;
  final String Function(Map<String, dynamic> lecture) formatLectureLine;

  const _SubjectLecturesTab({
    required this.subjectId,
    required this.formatLectureLine,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lecturesAsync = ref.watch(myLecturesBySubjectProvider(subjectId));
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.6);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(myLecturesBySubjectProvider(subjectId));
        await ref.read(myLecturesBySubjectProvider(subjectId).future);
      },
      child: lecturesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
        data: (lectures) => lectures.isEmpty
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
                        const Text('لا توجد محاضرات لهذه المادة هذا الأسبوع'),
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
                  final categoryName =
                      (l['categories'] as Map<String, dynamic>?)?['name']
                          as String? ??
                      '—';
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                                  const Gap(2),
                                  Text(
                                    categoryName,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: muted),
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
                                        formatLectureLine(l),
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
      ),
    );
  }
}
