import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:gap/gap.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/services/attendance_sync_service.dart';
import '../../../core/services/ble_attendance_codec.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  final String lectureId;
  const ScannerScreen({super.key, required this.lectureId});
  @override
  ConsumerState<ScannerScreen> createState() => _State();
}

class _State extends ConsumerState<ScannerScreen> {
  static const String _markerUuid = BleAttendanceCodec.markerServiceUuidFull;
  final FlutterBlePeripheral _ackPeripheral = FlutterBlePeripheral();

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
  bool _isSendingAck = false;

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

  @override
  void initState() {
    super.initState();
    AttendanceSyncService.instance.syncPendingQueue();
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      setState(() => _isBluetoothOn = state == BluetoothAdapterState.on);
    });
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
      setState(() {
        _isScanning = false;
      });
    }
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

  void _onModePressed(AttendanceEventType mode) {
    _switchMode(mode);
  }

  Future<void> _stopScanning() async {
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    if (!mounted) return;
    setState(() => _isScanning = false);
  }

  Future<void> _onScanResults(List<ScanResult> results) async {
    if (results.isEmpty) return;
    if (_mode == null) return;
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

      // Parse service UUID payload early; some iOS devices may omit marker UUID.
      final svcInfo = BleAttendanceCodec.parseServiceBroadcastInfo(
        rawServiceUuids.map((g) => g.toString()),
      );
      final svcStudent = svcInfo['studentUuid'] as String?;
      final svcToken = svcInfo['lectureToken'] as int?;
      final svcEvent = svcInfo['eventCode'] as int?;
      final svcNonce = svcInfo['requestNonce16'] as int?;
      final hasStructuredServicePayload =
          svcStudent != null && svcToken != null && svcEvent != null;

      final hasTrustedSignature =
          hasMarkerInServiceUuids ||
          hasMarkerInServiceData ||
          hasExpectedManufacturerPayload ||
          hasStructuredServicePayload;

      if (!hasTrustedSignature) {
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

      // Also include full service UUIDs as candidate raw bytes when present
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

      String? parsedLectureId;
      // service UUID info already parsed above

      for (final bytes in candidates) {
        final lecture = BleAttendanceCodec.parseLectureId(
          Uint8List.fromList(bytes),
        );
        if (lecture != null) {
          parsedLectureId = lecture;
          break;
        }
      }

      BleBoundAttendancePacket? bound;
      for (final bytes in candidates) {
        bound = BleAttendanceCodec.parseBoundPacket(Uint8List.fromList(bytes));
        if (bound != null) {
          break;
        }
      }

      // If manufacturer/serviceData payload missing but service UUIDs provided, synthesize bound info
      if (bound == null &&
          svcStudent != null &&
          svcToken != null &&
          svcEvent != null) {
        try {
          bound = BleBoundAttendancePacket(
            studentId: svcStudent,
            lectureToken16: svcToken,
            eventCode: svcEvent,
            requestNonce16: svcNonce ?? 0,
          );
        } catch (_) {}
      }

      if (bound == null) {
        continue;
      }

      final expectedLectureToken = BleAttendanceCodec.lectureToken16(
        widget.lectureId,
      );
      if (bound.lectureToken16 != expectedLectureToken) {
        continue;
      }

      if (parsedLectureId != null &&
          !BleAttendanceCodec.isSameUuid(parsedLectureId, widget.lectureId)) {
        continue;
      }

      final expectedEventCode = mode == AttendanceEventType.checkIn ? 1 : 2;
      if (bound.eventCode != expectedEventCode) {
        continue;
      }

      final dedupeKey = '${bound.studentId}_${widget.lectureId}_${mode.value}';
      if (_sessionProcessedKeys.contains(dedupeKey)) {
        continue;
      }
      final now = DateTime.now();
      final recentAt = _recentEvents[dedupeKey];
      if (recentAt != null && now.difference(recentAt).inSeconds < 8) {
        continue;
      }

      _recentEvents[dedupeKey] = now;
      await _processAttendance(packet: bound, eventType: mode);
      break;
    }
  }

  Future<void> _sendAckBurst({
    required BleBoundAttendancePacket packet,
    required int statusCode,
  }) async {
    if (_isSendingAck) return;
    _isSendingAck = true;

    final wasScanning = _isScanning;
    try {
      if (wasScanning) {
        await _stopScanning();
      }

      final serviceUuids = BleAttendanceCodec.buildAckServiceUuids(
        lectureToken16: packet.lectureToken16,
        eventCode: packet.eventCode,
        statusCode: statusCode,
        requestNonce16: packet.requestNonce16,
      );
      final ackPayload = BleAttendanceCodec.buildAckManufacturerData(
        lectureToken16: packet.lectureToken16,
        eventCode: packet.eventCode,
        statusCode: statusCode,
        requestNonce16: packet.requestNonce16,
      );

      // Send multiple short bursts to reduce ACK loss when student starts
      // scanning slightly after submitting attendance.
      await Future<void>.delayed(const Duration(milliseconds: 180));
      for (var i = 0; i < 3; i++) {
        try {
          await _ackPeripheral.start(
            advertiseData: AdvertiseDataCore(
              serviceUuids: serviceUuids,
              manufacturerId: BleAttendanceCodec.manufacturerId,
              manufacturerData: ackPayload,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 1000));
        } catch (_) {
          // Best effort per burst.
        } finally {
          try {
            await _ackPeripheral.stop();
          } catch (_) {}
        }

        if (i < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
        }
      }
    } catch (_) {
      // Best effort ACK.
    } finally {
      try {
        await _ackPeripheral.stop();
      } catch (_) {}

      if (mounted && wasScanning && _mode != null) {
        unawaited(_startScanning());
      }
      _isSendingAck = false;
    }
  }

  Future<void> _processAttendance({
    required BleBoundAttendancePacket packet,
    required AttendanceEventType eventType,
  }) async {
    final studentId = packet.studentId;
    final opKey = '${studentId}_${eventType.value}';
    final sessionKey = '${studentId}_${widget.lectureId}_${eventType.value}';
    if (_inFlightKeys.contains(opKey)) return;
    _inFlightKeys.add(opKey);

    try {
      final result = await AttendanceSyncService.instance
          .processAttendanceEvent(
            lectureId: widget.lectureId,
            studentId: studentId,
            eventType: eventType,
          );

      final acceptedStatuses = <String>{
        'accepted_check_in',
        'accepted_check_out',
        'queued_local',
      };
      final rejectedStatuses = <String>{
        'already_checked_in',
        'already_checked_out',
        'duplicate',
        'invalid_device_timezone',
        'internet_required',
        'compensation_day_not_allowed',
        'compensation_quota_exhausted',
        'compensation_already_used_today',
      };
      if (mounted) {
        int? ackStatusCode;
        setState(() {
          if (acceptedStatuses.contains(result.status)) {
            _acceptedCount++;
            _sessionProcessedKeys.add(sessionKey);
            ackStatusCode = 1;
          } else if (rejectedStatuses.contains(result.status)) {
            _rejectedCount++;
            _sessionProcessedKeys.add(sessionKey);
          }
        });

        if (result.status == 'queued_local') {
          ackStatusCode = 2;
        }

        if (ackStatusCode != null) {
          unawaited(_sendAckBurst(packet: packet, statusCode: ackStatusCode!));
        }
      }
    } catch (_) {
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
              ? 'استقبال تسجيل الدخول'
              : isCheckOutMode
              ? 'استقبال تسجيل الخروج'
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
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _onModePressed(AttendanceEventType.checkIn),
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('تسجيل دخول'),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: isCheckInMode
                              ? AppColors.success.withValues(alpha: 0.16)
                              : Colors.grey.withValues(alpha: 0.12),
                          side: BorderSide(
                            color: isCheckInMode
                                ? AppColors.success
                                : Colors.grey,
                          ),
                        ),
                      ),
                    ),
                    const Gap(10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _onModePressed(AttendanceEventType.checkOut),
                        icon: const Icon(Icons.logout_rounded),
                        label: const Text('تسجيل خروج'),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: isCheckOutMode
                              ? AppColors.success.withValues(alpha: 0.16)
                              : Colors.grey.withValues(alpha: 0.12),
                          side: BorderSide(
                            color: isCheckOutMode
                                ? AppColors.success
                                : Colors.grey,
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
        ],
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
