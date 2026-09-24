import 'dart:ui' as ui;
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:stagelink_resident/core/utils/app_error_message.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_mode_provider.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/device_service.dart';

DateTime _todayStartLocal() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

const _residentSubjectsCacheKey = 'resident_home_subjects_v1';

String _lecturesCacheKey(String subjectId) {
  final dayKey = DateFormat('yyyy-MM-dd').format(_todayStartLocal());
  return 'resident_home_lectures_${subjectId}_$dayKey';
}

List<Map<String, dynamic>> _decodeListCache(String? raw) {
  if (raw == null || raw.trim().isEmpty) return <Map<String, dynamic>>[];
  final decoded = jsonDecode(raw);
  return List<Map<String, dynamic>>.from(
    (decoded as List).cast<Map<String, dynamic>>(),
  );
}

Future<void> _saveListCache(
  String key,
  List<Map<String, dynamic>> value,
) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(key, jsonEncode(value));
}

Future<List<Map<String, dynamic>>> _fetchResidentSubjectsFromServer() async {
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
}

Future<List<Map<String, dynamic>>> _fetchLecturesBySubjectFromServer(
  String subjectId,
) async {
  final dayStartLocal = _todayStartLocal();
  final dayEndLocal = dayStartLocal.add(const Duration(days: 1));
  final dayStartUtcIso = dayStartLocal.toUtc().toIso8601String();
  final dayEndUtcIso = dayEndLocal.toUtc().toIso8601String();

  final res = await Supabase.instance.client
      .from('lectures')
      .select(
        'id, resident_id, start_at, end_at, target_category_id, categories(name), profiles(full_name, phone_number), practical_sessions!inner(title, subjects(name, location), subject_id)',
      )
      .eq('practical_sessions.subject_id', subjectId)
      .gte('start_at', dayStartUtcIso)
      .lt('start_at', dayEndUtcIso)
      .order('start_at', ascending: false);

  return List<Map<String, dynamic>>.from(res as List);
}

final residentSubjectsProvider = StreamProvider<List<Map<String, dynamic>>>((
  ref,
) async* {
  final prefs = await SharedPreferences.getInstance();
  final cached = _decodeListCache(prefs.getString(_residentSubjectsCacheKey));
  if (cached.isNotEmpty) {
    yield cached;
  }

  try {
    final fresh = await _fetchResidentSubjectsFromServer();
    await _saveListCache(_residentSubjectsCacheKey, fresh);
    yield fresh;
  } catch (e) {
    if (cached.isEmpty) rethrow;
  }
});

final myLecturesBySubjectProvider =
    StreamProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      subjectId,
    ) async* {
      final key = _lecturesCacheKey(subjectId);
      final prefs = await SharedPreferences.getInstance();
      final cached = _decodeListCache(prefs.getString(key));
      if (cached.isNotEmpty) {
        yield cached;
      }

      try {
        final fresh = await _fetchLecturesBySubjectFromServer(subjectId);
        await _saveListCache(key, fresh);
        yield fresh;
      } catch (e) {
        if (cached.isEmpty) rethrow;
      }
    });

class ResidentHomeScreen extends ConsumerStatefulWidget {
  const ResidentHomeScreen({super.key});

  @override
  ConsumerState<ResidentHomeScreen> createState() => _ResidentHomeScreenState();
}

class _ResidentHomeScreenState extends ConsumerState<ResidentHomeScreen>
    with WidgetsBindingObserver {
  Timer? _deviceLockTimer;
  bool _checkingDeviceLock = false;
  bool _forcedLogout = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_enforceDeviceLock());
    _deviceLockTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => unawaited(_enforceDeviceLock()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_enforceDeviceLock());
    }
  }

  Future<void> _enforceDeviceLock() async {
    if (_checkingDeviceLock || _forcedLogout) return;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    _checkingDeviceLock = true;
    try {
      final myDeviceId = await DeviceService().getDeviceId();
      final row = await Supabase.instance.client
          .from('profiles')
          .select('role, login_enabled, login_device_id')
          .eq('id', user.id)
          .single();
      final profile = Map<String, dynamic>.from(row);
      final role = profile['role'] as String?;
      final enabled = (profile['login_enabled'] as bool?) ?? true;
      final lockedDeviceId = profile['login_device_id'] as String?;

      final shouldLogout =
          role != 'resident' ||
          !enabled ||
          lockedDeviceId == null ||
          lockedDeviceId != myDeviceId;

      if (shouldLogout) {
        _forcedLogout = true;
        await Supabase.instance.client.auth.signOut();
        if (mounted) {
          ref.invalidate(routerProvider);
        }
      }
    } catch (_) {
      // Ignore transient connectivity failures.
    } finally {
      _checkingDeviceLock = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deviceLockTimer?.cancel();
    super.dispose();
  }

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
  Widget build(BuildContext context) {
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

  String? _normalizeWhatsappPhone(String? rawPhone) {
    if (rawPhone == null) return null;
    final trimmed = rawPhone.trim();
    if (trimmed.isEmpty) return null;

    final digitsOnly = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digitsOnly.isEmpty) return null;

    if (digitsOnly.startsWith('00') && digitsOnly.length > 2) {
      return digitsOnly.substring(2);
    }
    return digitsOnly;
  }

  Future<void> _openWhatsApp(
    BuildContext context, {
    required String? phone,
    required String sessionTitle,
    required String subjectName,
  }) async {
    final normalized = _normalizeWhatsappPhone(phone);
    if (normalized == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('رقم الهاتف غير متوفر للتواصل عبر واتساب'),
        ),
      );
      return;
    }

    final text = 'مرحبا، يرجى توكيلي "$sessionTitle" من ستاج "$subjectName" وشكرا.';
    final encodedText = Uri.encodeComponent(text);
    final uri = Uri.parse('https://wa.me/$normalized?text=$encodedText');
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);

    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب على هذا الجهاز')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lecturesAsync = ref.watch(myLecturesBySubjectProvider(subjectId));
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.6);
    return RefreshIndicator(
      onRefresh: () async {
        final fresh = await _fetchLecturesBySubjectFromServer(subjectId);
        await _saveListCache(_lecturesCacheKey(subjectId), fresh);
        ref.invalidate(myLecturesBySubjectProvider(subjectId));
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
                        const Text('لا توجد محاضرات لهذه المادة اليوم'),
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
                  final myResidentId = Supabase.instance.client.auth.currentUser?.id;
                  final lectureResidentId = l['resident_id'] as String?;
                  final claimedByOther =
                    lectureResidentId != null &&
                    myResidentId != null &&
                    lectureResidentId != myResidentId;
                  final ownerProfile = l['profiles'] as Map<String, dynamic>?;
                  final ownerName = (ownerProfile?['full_name'] as String?)?.trim();
                  final ownerPhone = (ownerProfile?['phone_number'] as String?)?.trim();

                  final session =
                      l['practical_sessions'] as Map<String, dynamic>?;
                  final sessionTitle = (session?['title'] as String?)?.trim() ?? '—';
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
                    onTap: claimedByOther
                      ? null
                      : () => context.push('/scan/${l['id']}'),
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
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          sessionTitle,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ),
                                      if (claimedByOther)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.orange.withValues(
                                              alpha: 0.14,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            ownerName != null && ownerName.isNotEmpty
                                                ? 'مستلمة: $ownerName'
                                                : 'مستلمة من مقيم آخر',
                                            style: const TextStyle(
                                              color: Color(0xFF9A3412),
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                    ],
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
                            if (claimedByOther)
                              IconButton(
                                tooltip: 'التواصل عبر واتساب',
                                onPressed: () => _openWhatsApp(
                                  context,
                                  phone: ownerPhone,
                                  sessionTitle: sessionTitle,
                                  subjectName: subject.toString(),
                                ),
                                icon: const Icon(
                                  Icons.chat_rounded,
                                  color: Color(0xFF25D366),
                                ),
                              )
                            else
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
