import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
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
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  bool _isScanning = false;
  bool _isBluetoothOn = false;
  bool _processing = false;
  String? _lastResult;
  bool _lastSuccess = false;
  final Map<String, DateTime> _recentEvents = <String, DateTime>{};
  int _ignoredBleFrames = 0;

  @override
  void initState() {
    super.initState();
    AttendanceSyncService.instance.syncPendingQueue();
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (!mounted) return;
      setState(() => _isBluetoothOn = state == BluetoothAdapterState.on);
    });
    _startScanning();
  }

  Future<void> _startScanning() async {
    if (_isScanning) return;
    try {
      if (!await FlutterBluePlus.isSupported) {
        if (!mounted) return;
        setState(() {
          _lastResult = 'هذا الجهاز لا يدعم BLE';
          _lastSuccess = false;
          _isScanning = false;
        });
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
        timeout: const Duration(days: 1),
        androidUsesFineLocation: false,
      );
      if (!mounted) return;
      setState(() => _isScanning = true);
    } catch (e) {
      final text = e.toString();
      var msg = 'تعذر بدء استقبال BLE، تحقق من صلاحيات البلوتوث';
      if (text.contains('permission') || text.contains('Permission')) {
        msg =
            'لا توجد صلاحية كافية للبلوتوث. فعّل Nearby devices/Location ثم أعد المحاولة';
      } else if (text.contains('off') || text.contains('Off')) {
        msg = 'البلوتوث غير مفعل، يرجى تفعيله أولاً';
      }
      if (!mounted) return;
      setState(() {
        _lastResult = '$msg\n($text)';
        _lastSuccess = false;
        _isScanning = false;
      });
    }
  }

  Future<void> _stopScanning() async {
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    if (!mounted) return;
    setState(() => _isScanning = false);
  }

  Future<void> _onScanResults(List<ScanResult> results) async {
    if (_processing || results.isEmpty) return;

    for (final result in results) {
      final manufacturerMap = result.advertisementData.manufacturerData;
      final serviceDataMap = result.advertisementData.serviceData;
      final rawServiceUuids = result.advertisementData.serviceUuids;

      final serviceUuidStrings = <String>[];
      for (final uuid in rawServiceUuids) {
        final text = uuid.toString();
        if (text.isNotEmpty) serviceUuidStrings.add(text);
      }

      final fromServiceUuids = BleAttendanceCodec.parseServiceUuids(
        serviceUuidStrings,
      );
      if (fromServiceUuids != null) {
        final dedupeKey =
            '${fromServiceUuids.studentId}_${widget.lectureId}_${fromServiceUuids.eventType.value}';
        final now = DateTime.now();
        final recentAt = _recentEvents[dedupeKey];
        if (recentAt != null && now.difference(recentAt).inSeconds < 8) {
          continue;
        }

        _recentEvents[dedupeKey] = now;
        await _processAttendance(
          studentId: fromServiceUuids.studentId,
          eventType: fromServiceUuids.eventType,
        );
        break;
      }

      if (manufacturerMap.isEmpty && serviceDataMap.isEmpty) {
        _ignoredBleFrames++;
        continue;
      }

      final candidates = <List<int>>[];
      final expected = manufacturerMap[BleAttendanceCodec.manufacturerId];
      if (expected != null && expected.isNotEmpty) {
        candidates.add(expected);
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

      ({String studentId, AttendanceEventType eventType})? parsed;
      for (final bytes in candidates) {
        parsed = BleAttendanceCodec.parse(Uint8List.fromList(bytes));
        if (parsed != null) break;
      }
      if (parsed == null) {
        _ignoredBleFrames++;
        if (mounted && _ignoredBleFrames % 20 == 0) {
          setState(() {
            _lastResult =
                'تم التقاط إشارات BLE، لكن ليست بصيغة حضور الطالب المتوقعة';
            _lastSuccess = false;
          });
        }
        continue;
      }

      final dedupeKey =
          '${parsed.studentId}_${widget.lectureId}_${parsed.eventType.value}';
      final now = DateTime.now();
      final recentAt = _recentEvents[dedupeKey];
      if (recentAt != null && now.difference(recentAt).inSeconds < 8) {
        continue;
      }

      _recentEvents[dedupeKey] = now;
      await _processAttendance(
        studentId: parsed.studentId,
        eventType: parsed.eventType,
      );
      break;
    }
  }

  Future<void> _processAttendance({
    required String studentId,
    required AttendanceEventType eventType,
  }) async {
    if (_processing) return;

    setState(() => _processing = true);

    try {
      final result = await AttendanceSyncService.instance
          .processAttendanceEvent(
            lectureId: widget.lectureId,
            studentId: studentId,
            eventType: eventType,
          );

      setState(() {
        _lastResult = result.message;
        _lastSuccess = result.success;
      });
    } catch (_) {
      setState(() {
        _lastResult = 'فشل تسجيل الحضور، حاول مجدداً';
        _lastSuccess = false;
      });
    } finally {
      await Future.delayed(const Duration(milliseconds: 1400));
      if (mounted) setState(() => _processing = false);
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('استقبال حضور BLE'),
        actions: [
          IconButton(
            icon: Icon(
              _isScanning
                  ? Icons.pause_circle_rounded
                  : Icons.play_circle_rounded,
            ),
            onPressed: _isScanning ? _stopScanning : _startScanning,
          ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bluetooth_searching_rounded,
                    size: 90,
                    color: AppColors.primary,
                  ),
                  const Gap(16),
                  Text(
                    _isScanning
                        ? 'قيد استقبال إشارات الحضور من الطلاب'
                        : 'الاستقبال متوقف',
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const Gap(8),
                  Text(
                    _isBluetoothOn
                        ? 'البلوتوث مفعل'
                        : 'البلوتوث غير مفعل، يرجى تفعيله',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),

          if (_lastResult != null)
            Positioned(
              bottom: 32,
              left: 16,
              right: 16,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _lastSuccess ? AppColors.success : AppColors.error,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(
                      _lastSuccess
                          ? Icons.check_circle_rounded
                          : Icons.error_outline_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                    const Gap(12),
                    Expanded(
                      child: Text(
                        _lastResult!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (_processing)
            Container(
              color: Colors.black45,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}
