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
  final AttendanceEventType? initialMode;
  const ScannerScreen({
    super.key,
    required this.lectureId,
    this.initialMode,
  });
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
  AttendanceEventType _mode = AttendanceEventType.checkIn;
  int _acceptedCount = 0;
  int _rejectedCount = 0;
  final Map<String, DateTime> _recentEvents = <String, DateTime>{};
  final Set<String> _inFlightKeys = <String>{};
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

  String? _parseServiceUuidsHeuristic(List<String> serviceUuids) {
    final normalized = <String>[];
    for (final raw in serviceUuids) {
      final n = _normalizeUuidOrNull(raw);
      if (n != null) normalized.add(n);
    }
    if (normalized.isEmpty) return null;


    for (final uuid in normalized) {
      if (uuid == _checkInServiceUuid || uuid == _checkOutServiceUuid) {
        continue;
      }
      return uuid;
    }

    // If only event UUID is present, we still cannot identify a student.
    return null;
  }

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode ?? AttendanceEventType.checkIn;
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
        setState(() => _isScanning = false);
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
      if (text.contains('permission') || text.contains('Permission')) {
        _log('scan failed due to missing permission');
      } else if (text.contains('off') || text.contains('Off')) {
        _log('scan failed because bluetooth seems OFF');
      }
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
    });
    _log('mode switched to ${mode.value}; counters reset');
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
    if (results.isEmpty) return;
    _log('onScanResults batch size=${results.length}');

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
        final String? parsedService =
          (fromServiceUuids == null
              ? _parseServiceUuidsHeuristic(serviceUuidStrings)
              : fromServiceUuids);
      if (parsedService != null) {
        _log(
          'parsed from serviceUuids => studentId=$parsedService, eventType=${_mode.value}',
        );
        final dedupeKey =
            '${parsedService}_${widget.lectureId}_${_mode.value}';
        final now = DateTime.now();
        final recentAt = _recentEvents[dedupeKey];
        if (recentAt != null && now.difference(recentAt).inSeconds < 8) {
          _log('duplicate event ignored for key=$dedupeKey');
          continue;
        }

        _recentEvents[dedupeKey] = now;
        _log('event accepted from serviceUuids, sending to processAttendance');
        await _processAttendance(
          studentId: parsedService,
          eventType: _mode,
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

      String? parsed;
      for (var i = 0; i < candidates.length; i++) {
        final bytes = candidates[i];
        _log('trying candidate[$i] len=${bytes.length} hex=${_hex(bytes)}');
        parsed = BleAttendanceCodec.parse(Uint8List.fromList(bytes));
        if (parsed != null) {
          _log(
            'candidate[$i] parsed OK => studentId=$parsed, eventType=${_mode.value}',
          );
          break;
        }
        _log('candidate[$i] parse failed');
      }
      if (parsed == null) {
        _ignoredBleFrames++;
        _log('all candidates failed parsing; ignoredFrames=$_ignoredBleFrames');
        continue;
      }

      final dedupeKey =
          '${parsed}_${widget.lectureId}_${_mode.value}';
      final now = DateTime.now();
      final recentAt = _recentEvents[dedupeKey];
      if (recentAt != null && now.difference(recentAt).inSeconds < 8) {
        _log('duplicate event ignored for key=$dedupeKey');
        continue;
      }

      _recentEvents[dedupeKey] = now;
      _log('event accepted from byte payload, sending to processAttendance');
      await _processAttendance(
        studentId: parsed,
        eventType: _mode,
      );
      break;
    }
  }

  Future<void> _processAttendance({
    required String studentId,
    required AttendanceEventType eventType,
  }) async {
    final opKey = '${studentId}_${eventType.value}';
    if (_inFlightKeys.contains(opKey)) return;
    _inFlightKeys.add(opKey);

    _log(
      'processAttendance started: lectureId=${widget.lectureId}, '
      'studentId=$studentId, eventType=${eventType.value}',
    );

    try {
      final result = await AttendanceSyncService.instance
          .processAttendanceEvent(
            lectureId: widget.lectureId,
            studentId: studentId,
            eventType: eventType,
          );

      _log(
        'processAttendance result: success=${result.success}, '
        'status=${result.status}, message="${result.message}"',
      );

      final acceptedStatuses = <String>{
        'accepted_check_in',
        'accepted_check_out',
        'queued_for_approval',
        'queued_local',
      };
      if (mounted) {
        setState(() {
          if (acceptedStatuses.contains(result.status)) {
            _acceptedCount++;
          } else {
            _rejectedCount++;
          }
        });
      }
    } catch (e) {
      _log('processAttendance exception: $e');
      if (mounted) {
        setState(() => _rejectedCount++);
      }
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
    final acceptedLabel = isCheckInMode
      ? 'تم تسجيل الدخول'
      : 'تم تسجيل الخروج';
    final rejectedLabel = isCheckInMode
      ? 'مرفوض (دخل سابقاً)'
      : 'مرفوض (خرج سابقاً)';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isCheckInMode ? 'استقبال تسجيل الدخول' : 'استقبال تسجيل الخروج',
        ),
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
          Padding(
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
                              ? AppColors.primary.withValues(alpha: 0.08)
                              : null,
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
                          backgroundColor: !isCheckInMode
                              ? AppColors.primary.withValues(alpha: 0.08)
                              : null,
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
