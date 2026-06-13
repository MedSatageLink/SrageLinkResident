import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/theme/app_theme.dart';

final myLecturesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;
  Future<List<Map<String, dynamic>>> fetchRemote() async {
    final res = await Supabase.instance.client
        .from('lectures')
        .select(
          'id, start_at, end_at, location, practical_sessions(title, subjects(name))',
        )
        .eq('resident_id', uid)
        .order('start_at', ascending: false);
    return List<Map<String, dynamic>>.from(res as List);
  }

  final prefs = await SharedPreferences.getInstance();
  final cacheKey = 'resident_lectures_$uid';
  final cachedRaw = prefs.getString(cacheKey);
  if (cachedRaw != null) {
    final cached = List<Map<String, dynamic>>.from(
      (jsonDecode(cachedRaw) as List).cast<Map<String, dynamic>>(),
    );

    unawaited(
      fetchRemote()
          .then((fresh) async {
            await prefs.setString(cacheKey, jsonEncode(fresh));
          })
          .catchError((_) {}),
    );

    return cached;
  }

  final fresh = await fetchRemote();
  await prefs.setString(cacheKey, jsonEncode(fresh));
  return fresh;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('محاضراتي'),
        actions: [
          IconButton(
            icon: const Icon(Icons.video_call_rounded),
            onPressed: () => context.go('/practical-videos/create'),
          ),
          IconButton(
            icon: const Icon(Icons.person_outline_rounded),
            onPressed: () => context.go('/profile'),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            onPressed: () async =>
                await Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      body: lecturesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(e.toString())),
        data: (lectures) {
          final muted = Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.6);
          if (lectures.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.event_note_rounded,
                    size: 72,
                    color: muted.withValues(alpha: 0.4),
                  ),
                  const Gap(16),
                  const Text('لا توجد محاضرات مسندة إليك'),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: lectures.length,
            itemBuilder: (context, i) {
              final l = lectures[i];
              final session = l['practical_sessions'] as Map<String, dynamic>?;
              final subject =
                  (session?['subjects'] as Map<String, dynamic>?)?['name'] ??
                  '—';
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => context.go('/scan/${l['id']}'),
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
                            Icons.qr_code_scanner_rounded,
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
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              Text(
                                subject,
                                style: Theme.of(context).textTheme.bodyMedium,
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
                                      l['location'] as String? ?? '',
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
                          Icons.qr_code_scanner_rounded,
                          color: AppColors.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ).animate(delay: (40 * i).ms).fadeIn();
            },
          );
        },
      ),
    );
  }
}
