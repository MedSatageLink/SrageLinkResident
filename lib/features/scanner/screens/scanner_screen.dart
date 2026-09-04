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
  static const bool _bleDebug = true;
  static const String _checkInServiceUuid =
      '0000a101-0000-1000-8000-00805f9b34fb';
  static const String _checkOutServiceUuid =
      '0000a102-0000-1000-8000-00805f9b34fb';

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  bool _isScanning = false;
  bool _isBluetoothOn = false;
  bool _processing = false;
  String? _lastResult;
  bool _lastSuccess = false;
  final Map<String, DateTime> _recentEvents = <String, DateTime>{};
  int _ignoredBleFrames = 0;

  void _log(String message) {
    if (!_bleDebug) return;
    debugPrint('[BLE][Scanner] $message');
  }

  String _hex(List<int> bytes, {int maxBytes = 24}) {
    final view = bytes.length > maxBytes ? bytes.sublist(0, maxBytes) : bytes;
    final hex = view.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    if (bytes.length > maxBytes) {
      return '$hex ... (+${bytes.length - maxBytes} bytes)';
    }
    return hex;
  }

  void _logAdvertisement(ScanResult result) {
    final ad = result.advertisementData;
    final serviceUuids = ad.serviceUuids.map((u) => u.toString()).toList();
    _log(
      'frame from id=${result.device.remoteId.str}, '
      'name="${result.device.platformName}", rssi=${result.rssi}, '
      'serviceUuids=$serviceUuids',
    );

    if (ad.manufacturerData.isEmpty) {
      _log('manufacturerData: empty');
    } else {
      for (final entry in ad.manufacturerData.entries) {
        _log(
          'manufacturerData[0x${entry.key.toRadixString(16)}] '
          'len=${entry.value.length} hex=${_hex(entry.value)}',
        );
      }
    }

    if (ad.serviceData.isEmpty) {
      _log('serviceData: empty');
    } else {
      for (final entry in ad.serviceData.entries) {
        _log(
          'serviceData[${entry.key}] '
          'len=${entry.value.length} hex=${_hex(entry.value)}',
        );
      }
    }
  }

  String? _normalizeUuidOrNull(String value) {
    final clean = value.replaceAll('-', '').toLowerCase();
    final isHex = RegExp(r'^[0-9a-f]+$').hasMatch(clean);
    if (!isHex) return null;

    if (clean.length == 4) {
      return '0000$clean-0000-1000-8000-00805f9b34fb';
    }
    if (clean.length == 8) {
      return '$clean-0000-1000-8000-00805f9b34fb';
    }
    if (clean.length != 32) return null;

    return '${clean.substring(0, 8)}-${clean.substring(8, 12)}-${clean.substring(12, 16)}-${clean.substring(16, 20)}-${clean.substring(20, 32)}';
  }

  ({String studentId, AttendanceEventType eventType})? _parseServiceUuidsHeuristic(
    List<String> serviceUuids,
  ) {
    final normalized = <String>[];
    for (final raw in serviceUuids) {
      final n = _normalizeUuidOrNull(raw);
      if (n != null) normalized.add(n);
    }
    if (normalized.isEmpty) return null;

    final hasCheckOut = normalized.contains(_checkOutServiceUuid);
    final eventType = hasCheckOut
        ? AttendanceEventType.checkOut
        : AttendanceEventType.checkIn;

    for (final uuid in normalized) {
      if (uuid == _checkInServiceUuid || uuid == _checkOutServiceUuid) {
        continue;
      }
      return (studentId: uuid, eventType: eventType);
    }

    // If only event UUID is present, we still cannot identify a student.
    return null;
  }

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
      _log('start scan requested for lectureId=${widget.lectureId}');
      if (!await FlutterBluePlus.isSupported) {
        _log('BLE not supported on this device');
        if (!mounted) return;
        setState(() {
          _lastResult = 'هذا الجهاز لا يدعم BLE';
          _lastSuccess = false;
          _isScanning = false;
        });
        return;
      }

      final adapterState = await FlutterBluePlus.adapterState.first;
      _log('adapterState before scan: $adapterState');
      if (adapterState != BluetoothAdapterState.on) {
        try {
          _log('adapter is not ON, trying to turn on bluetooth');
          await FlutterBluePlus.turnOn();
          _log('turnOn request sent');
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
      _log('scan started successfully');
      if (!mounted) return;
      setState(() => _isScanning = true);
    } catch (e) {
      _log('scan start failed: $e');
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
    _log('stop scan requested');
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    if (!mounted) return;
    setState(() => _isScanning = false);
  }

  Future<void> _onScanResults(List<ScanResult> results) async {
    if (_processing || results.isEmpty) return;
    _log('onScanResults batch size=${results.length}, processing=$_processing');

    for (final result in results) {
      _logAdvertisement(result);

      final manufacturerMap = result.advertisementData.manufacturerData;
      final serviceDataMap = result.advertisementData.serviceData;
      final rawServiceUuids = result.advertisementData.serviceUuids;

      final serviceUuidStrings = <String>[];
      for (final uuid in rawServiceUuids) {
        final text = uuid.toString();
        if (text.isNotEmpty) serviceUuidStrings.add(text);
      }

      _log('serviceUuids strings for parsing: $serviceUuidStrings');

      final fromServiceUuids = BleAttendanceCodec.parseServiceUuids(
        serviceUuidStrings,
      );
      final parsedService =
          fromServiceUuids ?? _parseServiceUuidsHeuristic(serviceUuidStrings);
      if (parsedService != null) {
        _log(
          'parsed from serviceUuids => studentId=${parsedService.studentId}, '
          'eventType=${parsedService.eventType.value}',
        );
        final dedupeKey =
            '${parsedService.studentId}_${widget.lectureId}_${parsedService.eventType.value}';
        final now = DateTime.now();
        final recentAt = _recentEvents[dedupeKey];
        if (recentAt != null && now.difference(recentAt).inSeconds < 8) {
          _log('duplicate event ignored for key=$dedupeKey');
          continue;
        }

        _recentEvents[dedupeKey] = now;
        _log('event accepted from serviceUuids, sending to processAttendance');
        await _processAttendance(
          studentId: parsedService.studentId,
          eventType: parsedService.eventType,
        );
        break;
      }

      _log('serviceUuids parsing did not match attendance format');

      if (manufacturerMap.isEmpty && serviceDataMap.isEmpty) {
        _ignoredBleFrames++;
        _log('ignored frame: no manufacturerData and no serviceData');
        continue;
      }

      final candidates = <List<int>>[];
      final expected = manufacturerMap[BleAttendanceCodec.manufacturerId];
      if (expected != null && expected.isNotEmpty) {
        candidates.add(expected);
        _log(
          'candidate added from expected manufacturerId '
          '0x${BleAttendanceCodec.manufacturerId.toRadixString(16)} '
          'len=${expected.length} hex=${_hex(expected)}',
        );
      }
      for (final entry in manufacturerMap.entries) {
        if (entry.value.isNotEmpty) {
          candidates.add(entry.value);
          _log(
            'candidate added from manufacturerData '
            'id=0x${entry.key.toRadixString(16)} '
            'len=${entry.value.length} hex=${_hex(entry.value)}',
          );
        }
      }
      for (final entry in serviceDataMap.entries) {
        if (entry.value.isNotEmpty) {
          candidates.add(entry.value);
          _log(
            'candidate added from serviceData uuid=${entry.key} '
            'len=${entry.value.length} hex=${_hex(entry.value)}',
          );
        }
      }

      _log('total raw-byte candidates count=${candidates.length}');

      ({String studentId, AttendanceEventType eventType})? parsed;
      for (var i = 0; i < candidates.length; i++) {
        final bytes = candidates[i];
        _log('trying candidate[$i] len=${bytes.length} hex=${_hex(bytes)}');
        parsed = BleAttendanceCodec.parse(Uint8List.fromList(bytes));
        if (parsed != null) {
          _log(
            'candidate[$i] parsed OK => studentId=${parsed.studentId}, '
            'eventType=${parsed.eventType.value}',
          );
          break;
        }
        _log('candidate[$i] parse failed');
      }
      if (parsed == null) {
        _ignoredBleFrames++;
        _log('all candidates failed parsing; ignoredFrames=$_ignoredBleFrames');
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
        _log('duplicate event ignored for key=$dedupeKey');
        continue;
      }

      _recentEvents[dedupeKey] = now;
      _log('event accepted from byte payload, sending to processAttendance');
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

    _log(
      'processAttendance started: lectureId=${widget.lectureId}, '
      'studentId=$studentId, eventType=${eventType.value}',
    );

    setState(() => _processing = true);

    try {
      final result = await AttendanceSyncService.instance
          .processAttendanceEvent(
            lectureId: widget.lectureId,
            studentId: studentId,
            eventType: eventType,
          );

      _log(
        'processAttendance result: success=${result.success}, '
        'message="${result.message}"',
      );

      setState(() {
        _lastResult = result.message;
        _lastSuccess = result.success;
      });
    } catch (e) {
      _log('processAttendance exception: $e');
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
