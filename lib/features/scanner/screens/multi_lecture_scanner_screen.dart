import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:gap/gap.dart';

import '../../../core/services/attendance_sync_service.dart';
import '../../../core/services/ble_attendance_codec.dart';
import '../../../core/theme/app_theme.dart';

class MultiLectureScannerScreen extends ConsumerStatefulWidget {
  final String subjectId;
  final List<Map<String, dynamic>> lectures;

  const MultiLectureScannerScreen({
    super.key,
    required this.subjectId,
    required this.lectures,
  });

  @override
  ConsumerState<MultiLectureScannerScreen> createState() => _State();
}

class _State extends ConsumerState<MultiLectureScannerScreen> {
  static const String _markerUuid = BleAttendanceCodec.markerServiceUuidFull;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  bool _isScanning = false;
  bool _isBluetoothOn = false;
  AttendanceEventType? _mode;
  int _acceptedCount = 0;
  int _rejectedCount = 0;
  final Map<String, DateTime> _recentEvents = <String, DateTime>{};
  final Set<String> _inFlightKeys = <String>{};
  final Set<String> _sessionProcessedKeys = <String>{};

  late final Map<int, List<String>> _lectureTokenMap;

  @override
  void initState() {
    super.initState();
    AttendanceSyncService.instance.syncPendingQueue();
    _lectureTokenMap = <int, List<String>>{};
    for (final l in widget.lectures) {
      final id = l['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final token = BleAttendanceCodec.lectureToken16(id);
      _lectureTokenMap.putIfAbsent(token, () => <String>[]).add(id);
    }

    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      setState(() => _isBluetoothOn = state == BluetoothAdapterState.on);
    });
  }

  bool _hasMarkerInServiceUuids(List<Guid> uuids) {
    for (final guid in uuids) {
      final raw = guid.toString().toLowerCase().replaceAll('-', '');
      if (raw.length == 4) {
        final expanded = '0000${raw}00001000800000805f9b34fb';
        if (expanded == _markerUuid.replaceAll('-', '')) return true;
      } else if (raw.length == 8) {
        final expanded = '${raw}00001000800000805f9b34fb';
        if (expanded == _markerUuid.replaceAll('-', '')) return true;
      } else if (raw.length == 32) {
        if (raw == _markerUuid.replaceAll('-', '')) return true;
      }
    }
    return false;
  }

  bool _hasMarkerInServiceData(Map<Guid, List<int>> serviceDataMap) {
    return _hasMarkerInServiceUuids(serviceDataMap.keys.toList());
  }

  Future<void> _startScanning() async {
    if (_isScanning) return;
    try {
      if (!await FlutterBluePlus.isSupported) {
        if (!mounted) return;
        setState(() => _isScanning = false);
        return;
      }

      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {}
      }

      await FlutterBluePlus.stopScan();
      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.onScanResults.listen(
        _onScanResults,
        onError: (_) {},
      );
      await FlutterBluePlus.startScan(
        timeout: const Duration(days: 365),
        androidUsesFineLocation: false,
      );
      if (!mounted) return;
      setState(() => _isScanning = true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isScanning = false);
    }
  }

  Future<void> _stopScanning() async {
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    if (!mounted) return;
    setState(() => _isScanning = false);
  }

  void _switchMode(AttendanceEventType mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _acceptedCount = 0;
      _rejectedCount = 0;
      _recentEvents.clear();
      _inFlightKeys.clear();
      _sessionProcessedKeys.clear();
    });
    if (!_isScanning) {
      unawaited(_startScanning());
    }
  }

  Future<void> _onScanResults(List<ScanResult> results) async {
    if (results.isEmpty || _mode == null) return;
    final mode = _mode!;

    for (final result in results) {
      final manufacturerMap = result.advertisementData.manufacturerData;
      final serviceDataMap = result.advertisementData.serviceData;
      final rawServiceUuids = result.advertisementData.serviceUuids;

      final hasMarkerInServiceUuids = _hasMarkerInServiceUuids(rawServiceUuids);
      final hasMarkerInServiceData = _hasMarkerInServiceData(serviceDataMap);
      final expectedManufacturerPayload =
          manufacturerMap[BleAttendanceCodec.manufacturerId];
      final hasExpectedManufacturerPayload =
          expectedManufacturerPayload != null &&
          expectedManufacturerPayload.isNotEmpty;

      if (!(hasMarkerInServiceUuids ||
          hasMarkerInServiceData ||
          hasExpectedManufacturerPayload)) {
        continue;
      }

      final candidates = <List<int>>[];
      if (expectedManufacturerPayload != null &&
          expectedManufacturerPayload.isNotEmpty) {
        candidates.add(expectedManufacturerPayload);
      }
      for (final entry in manufacturerMap.entries) {
        if (entry.value.isNotEmpty) {
          candidates.add(entry.value);
        }
      }
      for (final entry in serviceDataMap.entries) {
        if (entry.value.isNotEmpty) {
          candidates.add(entry.value);
        }
      }

      try {
        for (final guid in rawServiceUuids) {
          final su = guid.toString();
          final s = su.replaceAll('-', '').toLowerCase();
          if (s.length == 32) {
            final bytes = <int>[];
            for (var i = 0; i < 16; i++) {
              bytes.add(int.parse(s.substring(i * 2, i * 2 + 2), radix: 16));
            }
            candidates.add(bytes);
          }
        }
      } catch (_) {}

      final svcInfo = BleAttendanceCodec.parseServiceBroadcastInfo(
        rawServiceUuids.map((g) => g.toString()),
      );
      final svcStudent = svcInfo['studentUuid'] as String?;
      final svcToken = svcInfo['lectureToken'] as int?;
      final svcEvent = svcInfo['eventCode'] as int?;
      final svcNonce = svcInfo['requestNonce16'] as int?;

      BleBoundAttendancePacket? bound;
      for (final bytes in candidates) {
        bound = BleAttendanceCodec.parseBoundPacket(Uint8List.fromList(bytes));
        if (bound != null) break;
      }

      if (bound == null &&
          svcStudent != null &&
          svcToken != null &&
          svcEvent != null) {
        bound = BleBoundAttendancePacket(
          studentId: svcStudent,
          lectureToken16: svcToken,
          eventCode: svcEvent,
          requestNonce16: svcNonce ?? 0,
        );
      }

      if (bound == null) continue;

      final matchingLectureIds = _lectureTokenMap[bound.lectureToken16];
      if (matchingLectureIds == null || matchingLectureIds.isEmpty) continue;
      if (matchingLectureIds.length > 1) {
        // Rare token collision; skip to avoid wrong attendance.
        continue;
      }
      final lectureId = matchingLectureIds.first;

      final expectedEventCode = mode == AttendanceEventType.checkIn ? 1 : 2;
      if (bound.eventCode != expectedEventCode) continue;

      final dedupeKey = '${bound.studentId}_${lectureId}_${mode.value}';
      if (_sessionProcessedKeys.contains(dedupeKey)) continue;
      final now = DateTime.now();
      final recentAt = _recentEvents[dedupeKey];
      if (recentAt != null && now.difference(recentAt).inSeconds < 8) continue;

      _recentEvents[dedupeKey] = now;
      await _processAttendance(
        lectureId: lectureId,
        studentId: bound.studentId,
        eventType: mode,
      );
      break;
    }
  }

  Future<void> _processAttendance({
    required String lectureId,
    required String studentId,
    required AttendanceEventType eventType,
  }) async {
    final opKey = '${studentId}_${lectureId}_${eventType.value}';
    final sessionKey = '${studentId}_${lectureId}_${eventType.value}';
    if (_inFlightKeys.contains(opKey)) return;
    _inFlightKeys.add(opKey);

    try {
      final result = await AttendanceSyncService.instance
          .processAttendanceEvent(
            lectureId: lectureId,
            studentId: studentId,
            eventType: eventType,
          );

      final acceptedStatuses = <String>{
        'accepted_check_in',
        'accepted_check_out',
        'queued_for_approval',
        'queued_local',
      };
      final rejectedStatuses = <String>{
        'already_checked_in',
        'already_checked_out',
        'duplicate',
        'invalid_device_timezone',
      };

      if (mounted) {
        setState(() {
          if (acceptedStatuses.contains(result.status)) {
            _acceptedCount++;
            _sessionProcessedKeys.add(sessionKey);
          } else if (rejectedStatuses.contains(result.status)) {
            _rejectedCount++;
            _sessionProcessedKeys.add(sessionKey);
          }
        });
      }
    } catch (_) {
      // ignore transient errors
    } finally {
      _inFlightKeys.remove(opKey);
    }
  }

  @override
  void dispose() {
    unawaited(_stopScanning());
    unawaited(_adapterSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _isBluetoothOn ? AppColors.success : AppColors.warning;
    final isCheckInMode = _mode == AttendanceEventType.checkIn;
    final isCheckOutMode = _mode == AttendanceEventType.checkOut;
    final acceptedLabel = isCheckInMode
        ? 'تم تسجيل الدخول'
        : isCheckOutMode
        ? 'تم تسجيل الخروج'
        : 'تم قبول الطلب';
    final rejectedLabel = isCheckInMode
        ? 'مرفوض (دخل سابقاً)'
        : isCheckOutMode
        ? 'مرفوض (خرج سابقاً)'
        : 'طلبات مرفوضة';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isCheckInMode
              ? 'استقبال دخول (كل جلسات اليوم)'
              : isCheckOutMode
              ? 'استقبال خروج (كل جلسات اليوم)'
              : 'اختر وضع الاستقبال',
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isScanning
                  ? Icons.pause_circle_rounded
                  : Icons.play_circle_rounded,
            ),
            onPressed: _mode == null
                ? null
                : (_isScanning ? _stopScanning : _startScanning),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _switchMode(AttendanceEventType.checkIn),
                    icon: const Icon(Icons.login_rounded),
                    label: const Text('تسجيل دخول'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: isCheckInMode
                          ? AppColors.success.withValues(alpha: 0.16)
                          : Colors.grey.withValues(alpha: 0.12),
                      side: BorderSide(
                        color: isCheckInMode ? AppColors.success : Colors.grey,
                      ),
                    ),
                  ),
                ),
                const Gap(10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _switchMode(AttendanceEventType.checkOut),
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('تسجيل خروج'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: isCheckOutMode
                          ? AppColors.success.withValues(alpha: 0.16)
                          : Colors.grey.withValues(alpha: 0.12),
                      side: BorderSide(
                        color: isCheckOutMode ? AppColors.success : Colors.grey,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const Gap(18),
            Icon(
              Icons.bluetooth_searching_rounded,
              size: 76,
              color: AppColors.primary,
            ),
            const Gap(10),
            Text(
              _isScanning ? 'الاستقبال جارٍ' : 'الاستقبال متوقف',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Gap(6),
            Text(
              _isBluetoothOn
                  ? 'البلوتوث مفعل'
                  : 'البلوتوث غير مفعل، يرجى تفعيله',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: statusColor,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Gap(24),
            Row(
              children: [
                Expanded(
                  child: _CounterCard(
                    icon: Icons.verified_rounded,
                    color: AppColors.success,
                    title: acceptedLabel,
                    count: _acceptedCount,
                  ),
                ),
                const Gap(12),
                Expanded(
                  child: _CounterCard(
                    icon: Icons.block_rounded,
                    color: AppColors.error,
                    title: rejectedLabel,
                    count: _rejectedCount,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CounterCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final int count;

  const _CounterCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          const Gap(8),
          Text(
            '$count',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Gap(4),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
