import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:workmanager/workmanager.dart';

import '../../supabase_config.dart';

const String _syncTaskName = 'residentAttendanceSyncTask';
const String _queueKey = 'resident_offline_scan_queue_v1';

@pragma('vm:entry-point')
void attendanceSyncCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await Supabase.initialize(
        url: SupabaseConfig.supabaseUrl,
        anonKey: SupabaseConfig.supabaseAnonKey,
      );
    } catch (_) {
      // Already initialized in this isolate.
    }

    await AttendanceSyncService.instance.syncPendingQueue();
    return Future.value(true);
  });
}

class AttendanceSyncResult {
  final bool success;
  final String message;
  final String status;
  const AttendanceSyncResult(
    this.success,
    this.message, {
    required this.status,
  });
}

enum AttendanceEventType { checkIn, checkOut }

extension AttendanceEventTypeValue on AttendanceEventType {
  String get value =>
      this == AttendanceEventType.checkIn ? 'check_in' : 'check_out';

  String get arabicLabel =>
      this == AttendanceEventType.checkIn ? 'تسجيل الدخول' : 'تسجيل الخروج';
}

class AttendanceSyncService {
  AttendanceSyncService._();
  static final AttendanceSyncService instance = AttendanceSyncService._();
  static const _uuid = Uuid();

  Future<void> initializeBackgroundSync() async {
    await Workmanager().initialize(attendanceSyncCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      'residentAttendanceSyncUnique',
      _syncTaskName,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  Future<AttendanceSyncResult> processAttendanceEvent({
    required String lectureId,
    required String studentId,
    required AttendanceEventType eventType,
  }) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      return const AttendanceSyncResult(
        false,
        'غير مسجل الدخول',
        status: 'not_logged_in',
      );
    }

    final payload = {
      'id': _uuid.v4(),
      'idempotency_key': _uuid.v4(),
      'lecture_id': lectureId,
      'student_id': studentId,
      'resident_id': uid,
      'event_type': eventType.value,
      'scanned_local_at': DateTime.now().toUtc().toIso8601String(),
      'queued_at': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      final result = await _submitAttempt(payload);
      final status = result['status'] as String? ?? '';
      if (status == 'accepted_check_in') {
        return const AttendanceSyncResult(
          true,
          'تم تسجيل الدخول ✓',
          status: 'accepted_check_in',
        );
      }
      if (status == 'accepted_check_out') {
        return const AttendanceSyncResult(
          true,
          'تم تسجيل الخروج ✓',
          status: 'accepted_check_out',
        );
      }
      if (status == 'already_checked_in') {
        return const AttendanceSyncResult(
          false,
          'تم تسجيل الدخول مسبقاً',
          status: 'already_checked_in',
        );
      }
      if (status == 'already_checked_out') {
        return const AttendanceSyncResult(
          false,
          'تم تسجيل الخروج مسبقاً',
          status: 'already_checked_out',
        );
      }
      if (status == 'duplicate') {
        return const AttendanceSyncResult(
          false,
          'تم تسجيل هذا الحدث مسبقاً',
          status: 'duplicate',
        );
      }
      if ((result['message'] as String?) ==
          'lecture_claimed_by_other_resident') {
        return const AttendanceSyncResult(
          false,
          'تم استلام هذه المحاضرة من مقيم آخر',
          status: 'lecture_claimed_by_other_resident',
        );
      }
      if ((result['message'] as String?) ==
          'resident_not_allowed_for_subject') {
        return const AttendanceSyncResult(
          false,
          'غير مسموح لك باستقبال هذه المحاضرة (اختلاف المادة)',
          status: 'resident_not_allowed_for_subject',
        );
      }
      final serverMessage = result['message'] as String?;
      if (serverMessage == 'missing_check_in') {
        return const AttendanceSyncResult(
          false,
          'لا يمكن تسجيل الخروج قبل تسجيل الدخول',
          status: 'missing_check_in',
        );
      }
      if (status == 'queued_for_approval') {
        return AttendanceSyncResult(
          true,
          'تم حفظ ${eventType.arabicLabel} كحالة متأخرة بانتظار موافقة الإدارة',
          status: 'queued_for_approval',
        );
      }
      final msg = serverMessage;
      return AttendanceSyncResult(
        false,
        msg ?? 'فشل التسجيل',
        status: status.isEmpty ? 'failed' : status,
      );
    } catch (_) {
      await _enqueueLocal(payload);
      return AttendanceSyncResult(
        true,
        'تم حفظ ${eventType.arabicLabel} محلياً وسيتم رفعه تلقائياً عند عودة الاتصال',
        status: 'queued_local',
      );
    }
  }

  Future<AttendanceSyncResult> releaseLectureResident({
    required String lectureId,
  }) async {
    try {
      final res = await Supabase.instance.client.rpc(
        'release_practical_lecture_resident',
        params: {'p_lecture_id': lectureId},
      );
      final map = Map<String, dynamic>.from(res as Map);
      final status = map['status'] as String? ?? '';
      final message = map['message'] as String?;

      if (status == 'released') {
        return const AttendanceSyncResult(
          true,
          'تمت إعادة فتح المحاضرة لمقيم آخر بنجاح',
          status: 'released',
        );
      }
      if (status == 'already_unclaimed') {
        return const AttendanceSyncResult(
          true,
          'المحاضرة غير مستلمة حالياً',
          status: 'already_unclaimed',
        );
      }
      if (message == 'not_lecture_owner') {
        return const AttendanceSyncResult(
          false,
          'لا يمكنك التوكيل لأنك لست المستلم الحالي للمحاضرة',
          status: 'not_lecture_owner',
        );
      }

      return AttendanceSyncResult(
        false,
        message ?? 'تعذر تنفيذ التوكيل',
        status: status.isEmpty ? 'failed' : status,
      );
    } catch (_) {
      return const AttendanceSyncResult(
        false,
        'تعذر الاتصال بالخادم لتنفيذ التوكيل',
        status: 'network_error',
      );
    }
  }

  Future<void> syncPendingQueue() async {
    final queue = await _readQueue();
    if (queue.isEmpty) return;

    final remaining = <Map<String, dynamic>>[];
    for (final item in queue) {
      try {
        final result = await _submitAttempt(item);
        final status = result['status'] as String? ?? '';
        if (status == 'accepted_check_in' ||
            status == 'accepted_check_out' ||
            status == 'already_checked_in' ||
            status == 'already_checked_out' ||
            status == 'duplicate' ||
            status == 'queued_for_approval') {
          continue;
        }
        if ((result['message'] as String?) == 'missing_check_in') {
          continue;
        }
        remaining.add(item);
      } catch (_) {
        remaining.add(item);
      }
    }

    await _writeQueue(remaining);
  }

  Future<Map<String, dynamic>> _submitAttempt(Map<String, dynamic> item) async {
    final res = await Supabase.instance.client.rpc(
      'submit_practical_attendance_event',
      params: {
        'p_lecture_id': item['lecture_id'],
        'p_student_id': item['student_id'],
        'p_event_type': item['event_type'] ?? 'check_in',
        'p_idempotency_key': item['idempotency_key'],
        'p_scanned_local_at': item['scanned_local_at'],
      },
    );
    return Map<String, dynamic>.from(res as Map);
  }

  Future<void> _enqueueLocal(Map<String, dynamic> item) async {
    final queue = await _readQueue();
    final exists = queue.any(
      (q) =>
          q['lecture_id'] == item['lecture_id'] &&
          q['student_id'] == item['student_id'] &&
          q['event_type'] == item['event_type'],
    );
    if (!exists) {
      queue.add(item);
      await _writeQueue(queue);
    }
  }

  Future<List<Map<String, dynamic>>> _readQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_queueKey);
    if (raw == null || raw.trim().isEmpty) return [];
    return List<Map<String, dynamic>>.from(
      (jsonDecode(raw) as List).cast<Map<String, dynamic>>(),
    );
  }

  Future<void> _writeQueue(List<Map<String, dynamic>> queue) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queueKey, jsonEncode(queue));
  }
}
