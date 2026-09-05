import 'dart:io';

import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DeviceService {
  static const String _deviceIdKey = 'device_id';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  Future<String> getDeviceId() async {
    final cached = await _storage.read(key: _deviceIdKey);
    if (cached != null && cached.isNotEmpty) return cached;

    final generated = await _generateDeviceId();
    await _storage.write(key: _deviceIdKey, value: generated);
    return generated;
  }

  Future<String> _generateDeviceId() async {
    try {
      if (Platform.isAndroid) {
        final value = await const AndroidId().getId();
        return value ?? _fallback();
      }
      if (Platform.isIOS) {
        final ios = await _deviceInfo.iosInfo;
        return ios.identifierForVendor ?? _fallback();
      }
      return _fallback();
    } catch (_) {
      return _fallback();
    }
  }

  String _fallback() {
    final now = DateTime.now();
    return 'fallback_${now.millisecondsSinceEpoch}_${now.microsecondsSinceEpoch}';
  }
}
