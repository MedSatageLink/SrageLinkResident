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

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  bool _isScanning = false;
  bool _isBluetoothOn = false;
  AttendanceEventType? _mode;
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
    if (!_isScanning) {
      unawaited(_startScanning());
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
    if (results.isEmpty) return;
    if (_mode == null) return;
    final mode = _mode!;
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
      final String? parsedService = fromServiceUuids;
      if (parsedService != null) {
        _log(
          'parsed from serviceUuids => studentId=$parsedService, eventType=${mode.value}',
        );
        final dedupeKey = '${parsedService}_${widget.lectureId}_${mode.value}';
        final now = DateTime.now();
        final recentAt = _recentEvents[dedupeKey];
        if (recentAt != null && now.difference(recentAt).inSeconds < 8) {
          _log('duplicate event ignored for key=$dedupeKey');
          continue;
        }

        _recentEvents[dedupeKey] = now;
        _log('event accepted from serviceUuids, sending to processAttendance');
        await _processAttendance(studentId: parsedService, eventType: mode);
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
            'candidate[$i] parsed OK => studentId=$parsed, eventType=${mode.value}',
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

      final dedupeKey = '${parsed}_${widget.lectureId}_${mode.value}';
      final now = DateTime.now();
      final recentAt = _recentEvents[dedupeKey];
      if (recentAt != null && now.difference(recentAt).inSeconds < 8) {
        _log('duplicate event ignored for key=$dedupeKey');
        continue;
      }

      _recentEvents[dedupeKey] = now;
      _log('event accepted from byte payload, sending to processAttendance');
      await _processAttendance(studentId: parsed, eventType: mode);
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
      final rejectedStatuses = <String>{
        'already_checked_in',
        'already_checked_out',
        'duplicate',
      };
      if (mounted) {
        setState(() {
          if (acceptedStatuses.contains(result.status)) {
            _acceptedCount++;
          } else if (rejectedStatuses.contains(result.status)) {
            _rejectedCount++;
          }
        });

        if (result.status == 'lecture_claimed_by_other_resident') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم استلام هذه المحاضرة من مقيم آخر')),
          );
          await _stopScanning();
          if (mounted && context.mounted) Navigator.of(context).maybePop();
        }
      }
    } catch (e) {
      _log('processAttendance exception: $e');
    } finally {
      _inFlightKeys.remove(opKey);
    }
  }

  Future<void> _delegateLecture() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('توكيل مقيم آخر'),
        content: const Text(
          'سيتم إلغاء استلامك الحالي للمحاضرة لتصبح متاحة لمقيم آخر من نفس المادة. هل تريد المتابعة؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('توكيل'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final result = await AttendanceSyncService.instance.releaseLectureResident(
      lectureId: widget.lectureId,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));

    if (!result.success) return;

    await _stopScanning();
    if (!mounted || !context.mounted) return;
    Navigator.of(context).maybePop();
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
          TextButton.icon(
            onPressed: _delegateLecture,
            icon: const Icon(Icons.swap_horiz_rounded),
            label: const Text('توكيل مقيم آخر'),
          ),
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
                            _switchMode(AttendanceEventType.checkIn),
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
                            _switchMode(AttendanceEventType.checkOut),
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
