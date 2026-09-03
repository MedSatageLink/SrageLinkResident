import 'dart:typed_data';

import 'attendance_sync_service.dart';

class BleAttendanceCodec {
  static const int manufacturerId = 0x1234;
  static const String _checkInServiceUuid =
      '0000a101-0000-1000-8000-00805f9b34fb';
  static const String _checkOutServiceUuid =
      '0000a102-0000-1000-8000-00805f9b34fb';

  static Uint8List buildManufacturerData({
    required String studentId,
    required AttendanceEventType eventType,
  }) {
    final studentBytes = _uuidToBytes(studentId);
    final eventByte = eventType == AttendanceEventType.checkIn ? 1 : 2;
    return Uint8List.fromList(<int>[1, eventByte, ...studentBytes]);
  }

  static ({String studentId, AttendanceEventType eventType})? parse(
    Uint8List bytes,
  ) {
    if (bytes.length < 18) return null;
    final version = bytes[0];
    if (version != 1) return null;

    final eventType = switch (bytes[1]) {
      1 => AttendanceEventType.checkIn,
      2 => AttendanceEventType.checkOut,
      _ => null,
    };
    if (eventType == null) return null;

    final studentBytes = bytes.sublist(2, 18);
    final studentId = _bytesToUuid(studentBytes);
    return (studentId: studentId, eventType: eventType);
  }

  static ({String studentId, AttendanceEventType eventType})? parseServiceUuids(
    Iterable<String> serviceUuids,
  ) {
    final normalized = <String>[];
    for (final uuid in serviceUuids) {
      final n = _tryNormalizeUuid(uuid);
      if (n != null) normalized.add(n);
    }
    if (normalized.isEmpty) return null;

    final eventType = normalized.contains(_checkInServiceUuid)
        ? AttendanceEventType.checkIn
        : normalized.contains(_checkOutServiceUuid)
        ? AttendanceEventType.checkOut
        : null;
    if (eventType == null) return null;

    for (final uuid in normalized) {
      if (uuid == _checkInServiceUuid || uuid == _checkOutServiceUuid) {
        continue;
      }
      return (studentId: uuid, eventType: eventType);
    }
    return null;
  }

  static Uint8List _uuidToBytes(String uuid) {
    final clean = uuid.replaceAll('-', '').toLowerCase();
    if (clean.length != 32) {
      throw const FormatException('Invalid UUID');
    }
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _bytesToUuid(List<int> bytes) {
    if (bytes.length != 16) {
      throw const FormatException('Invalid UUID bytes');
    }
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  static String? _tryNormalizeUuid(String value) {
    final clean = value.replaceAll('-', '').toLowerCase();
    if (clean.length != 32) return null;
    final isHex = RegExp(r'^[0-9a-f]{32}$').hasMatch(clean);
    if (!isHex) return null;
    return '${clean.substring(0, 8)}-${clean.substring(8, 12)}-${clean.substring(12, 16)}-${clean.substring(16, 20)}-${clean.substring(20, 32)}';
  }
}
