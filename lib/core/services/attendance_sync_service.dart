import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:workmanager/workmanager.dart';

import '../../supabase_config.dart';
import 'device_service.dart';

const String _syncTaskName = 'residentAttendanceSyncTask';
const String _syncOneOffTaskName = 'residentAttendanceSyncOneOffTask';
const String _syncPeriodicUniqueName = 'residentAttendanceSyncPeriodicUnique';
const String _syncOneOffUniqueName = 'residentAttendanceSyncOneOffUnique';
const String _queueKey = 'resident_offline_scan_queue_v1';
const String _sessionSnapshotKey = 'resident_auth_session_snapshot_v1';
const String _clockSkewPrefix = 'resident_clock_skew_ms_v1';
const String _clockSkewMeasuredPrefix = 'resident_clock_skew_measured_at_v1';

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
  static const Duration _clockSkewRefreshInterval = Duration(minutes: 10);

  Future<void> _persistSessionSnapshot() async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionSnapshotKey, jsonEncode(session.toJson()));
  }

  Future<bool> _ensureAuthSessionForBackground() async {
    if (Supabase.instance.client.auth.currentUser != null) return true;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sessionSnapshotKey);
    if (raw == null || raw.trim().isEmpty) return false;

    try {
      await Supabase.instance.client.auth.recoverSession(raw);
    } catch (_) {
      return false;
    }

    return Supabase.instance.client.auth.currentUser != null;
  }

  bool _isSyriaTimezoneNow() {
    // Syria local timezone is UTC+3.
    return DateTime.now().timeZoneOffset.inMinutes == 180;
  }

  Future<String> _clockSkewKey(String uid) async {
    final deviceId = await DeviceService().getDeviceId();
    return '$_clockSkewPrefix:$uid:$deviceId';
  }

  Future<String> _clockSkewMeasuredAtKey(String uid) async {
    final deviceId = await DeviceService().getDeviceId();
    return '$_clockSkewMeasuredPrefix:$uid:$deviceId';
  }

  Future<Duration?> _readClockSkew(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _clockSkewKey(uid);
    final ms = prefs.getInt(key);
    if (ms == null) return null;
    return Duration(milliseconds: ms);
  }

  Future<void> _writeClockSkew(String uid, Duration skew) async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _clockSkewKey(uid);
    final measuredKey = await _clockSkewMeasuredAtKey(uid);
    await prefs.setInt(key, skew.inMilliseconds);
    await prefs.setString(
      measuredKey,
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<bool> _shouldRefreshClockSkew(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final measuredKey = await _clockSkewMeasuredAtKey(uid);
    final measuredRaw = prefs.getString(measuredKey);
    if (measuredRaw == null || measuredRaw.trim().isEmpty) return true;
    final measuredAt = DateTime.tryParse(measuredRaw);
    if (measuredAt == null) return true;
    return DateTime.now().toUtc().difference(measuredAt) >=
        _clockSkewRefreshInterval;
  }

  Future<void> _refreshClockSkewIfNeeded(
    String uid, {
    bool force = false,
  }) async {
    try {
      if (!force) {
        final should = await _shouldRefreshClockSkew(uid);
        if (!should) return;
      }

      final res = await Supabase.instance.client.rpc('get_server_now_utc');
      final serverNow = DateTime.tryParse(res.toString());
      if (serverNow == null) return;

      final deviceNowUtc = DateTime.now().toUtc();
      final skew = serverNow.difference(deviceNowUtc);
      await _writeClockSkew(uid, skew);
    } catch (_) {
      // Ignore transient failures; offline path continues.
    }
  }

  Future<Map<String, dynamic>> _buildScanTimePayload(String uid) async {
    final rawDeviceAt = DateTime.now().toUtc();
    final skew = await _readClockSkew(uid);
    final corrected = skew == null ? rawDeviceAt : rawDeviceAt.add(skew);
    return {
      'rawDeviceAtUtc': rawDeviceAt,
      'correctedUtc': corrected,
      'skewMsUsed': skew?.inMilliseconds,
    };
  }

  Future<Map<String, dynamic>> _prepareQueuedItemForSubmit(
    String uid,
    Map<String, dynamic> item,
  ) async {
    if (item['skew_ms_used'] != null) return item;

    final skew = await _readClockSkew(uid);
    if (skew == null) return item;

    final rawBase =
        DateTime.tryParse(item['raw_device_at_utc']?.toString() ?? '') ??
        DateTime.tryParse(item['scanned_local_at']?.toString() ?? '');
    if (rawBase == null) return item;

    final corrected = rawBase.toUtc().add(skew);
    return {
      ...item,
      'scanned_local_at': corrected.toIso8601String(),
      'skew_ms_used': skew.inMilliseconds,
    };
  }

  Future<void> initializeBackgroundSync() async {
    await Workmanager().initialize(attendanceSyncCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      _syncPeriodicUniqueName,
      _syncTaskName,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
    await _scheduleOneOffSync();
  }

  Future<void> _scheduleOneOffSync() async {
    await Workmanager().registerOneOffTask(
      _syncOneOffUniqueName,
      _syncOneOffTaskName,
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(networkType: NetworkType.connected),
      initialDelay: const Duration(seconds: 10),
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

    await _persistSessionSnapshot();

    if (!_isSyriaTimezoneNow()) {
      return const AttendanceSyncResult(
        false,
        'يرجى ضبط المنطقة الزمنية للجهاز على التوقيت السوري (UTC+3) قبل تسجيل الحضور',
        status: 'invalid_device_timezone',
      );
    }

    await _refreshClockSkewIfNeeded(uid);
    final timePayload = await _buildScanTimePayload(uid);
    final correctedUtc = timePayload['correctedUtc'] as DateTime;
    final rawDeviceAtUtc = timePayload['rawDeviceAtUtc'] as DateTime;
    final skewMsUsed = timePayload['skewMsUsed'] as int?;

    final payload = {
      'id': _uuid.v4(),
      'idempotency_key': _uuid.v4(),
      'lecture_id': lectureId,
      'student_id': studentId,
      'resident_id': uid,
      'event_type': eventType.value,
      'scanned_local_at': correctedUtc.toIso8601String(),
      'raw_device_at_utc': rawDeviceAtUtc.toIso8601String(),
      'skew_ms_used': skewMsUsed,
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
      await _scheduleOneOffSync();
      return AttendanceSyncResult(
        true,
        'تم حفظ ${eventType.arabicLabel} محلياً وسيتم رفعه تلقائياً عند عودة الاتصال',
        status: 'queued_local',
      );
    }
  }

  Future<void> syncPendingQueue() async {
    await _ensureAuthSessionForBackground();
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      await _scheduleOneOffSync();
      return;
    }

    await _refreshClockSkewIfNeeded(uid);

    final queue = await _readQueue();
    if (queue.isEmpty) return;

    final remaining = <Map<String, dynamic>>[];
    for (final queued in queue) {
      final item = await _prepareQueuedItemForSubmit(uid, queued);
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
    if (remaining.isNotEmpty) {
      await _scheduleOneOffSync();
    }
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
