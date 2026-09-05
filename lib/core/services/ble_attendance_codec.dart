import 'dart:typed_data';

class BleAttendanceCodec {
  static const int manufacturerId = 0x1234;
  static const String markerServiceUuidFull =
      '0000a100-0000-1000-8000-00805f9b34fb';

  static String? parse(Uint8List bytes) {
    if (bytes.length != 17 && bytes.length != 18) return null;
    if (bytes[0] != 1) return null;

    // Legacy fallback (older app builds): [1, event, uuid16]
    if (bytes.length == 18 && (bytes[1] == 1 || bytes[1] == 2)) {
      final legacy = bytes.sublist(2, 18);
      return _bytesToUuid(legacy);
    }

    // New format: [1, uuid16]
    if (bytes.length == 17) {
      final direct = bytes.sublist(1, 17);
      return _bytesToUuid(direct);
    }
    return null;
  }

  static String? parseServiceUuids(Iterable<String> serviceUuids) {
    final normalized = <String>[];
    for (final uuid in serviceUuids) {
      final n = _tryNormalizeUuid(uuid);
      if (n != null) normalized.add(n);
    }
    if (normalized.isEmpty) return null;

    // Ignore any advertisement that does not carry our marker UUID.
    if (!normalized.contains(markerServiceUuidFull)) return null;

    for (final uuid in normalized) {
      if (uuid == markerServiceUuidFull) {
        continue;
      }
      return uuid;
    }
    return null;
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
    if (clean.length == 4) {
      return '0000$clean-0000-1000-8000-00805f9b34fb';
    }
    if (clean.length == 8) {
      return '$clean-0000-1000-8000-00805f9b34fb';
    }
    if (clean.length != 32) return null;
    final isHex = RegExp(r'^[0-9a-f]{32}$').hasMatch(clean);
    if (!isHex) return null;
    return '${clean.substring(0, 8)}-${clean.substring(8, 12)}-${clean.substring(12, 16)}-${clean.substring(16, 20)}-${clean.substring(20, 32)}';
  }
}
