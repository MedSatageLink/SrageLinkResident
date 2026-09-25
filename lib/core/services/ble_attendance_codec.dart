import 'dart:typed_data';

class BleBoundAttendancePacket {
  final String studentId;
  final int lectureToken16;
  final int eventCode;

  const BleBoundAttendancePacket({
    required this.studentId,
    required this.lectureToken16,
    required this.eventCode,
  });
}

class BleAttendanceCodec {
  static const int manufacturerId = 0x1234;
  static const String markerServiceUuidFull =
      '0000a100-0000-1000-8000-00805f9b34fb';

  // New sender format: [4, event_code, student_uuid_16_bytes, lecture_token_hi, lecture_token_lo]
  static const int studentLectureBindingVersion = 4;

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

  static String? parseLectureId(Uint8List bytes) {
    if (bytes.length != 17) return null;
    if (bytes[0] != 2) return null;
    final lecture = bytes.sublist(1, 17);
    return _bytesToUuid(lecture);
  }

  static BleBoundAttendancePacket? parseBoundPacket(Uint8List bytes) {
    if (bytes.length != 20) return null;
    if (bytes[0] != studentLectureBindingVersion) return null;
    final eventCode = bytes[1] & 0xFF;
    if (eventCode != 1 && eventCode != 2) return null;
    final student = _bytesToUuid(bytes.sublist(2, 18));
    final token = ((bytes[18] & 0xFF) << 8) | (bytes[19] & 0xFF);
    return BleBoundAttendancePacket(
      studentId: student,
      lectureToken16: token,
      eventCode: eventCode,
    );
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

  static String normalizeUuid(String uuid) {
    final clean = uuid.replaceAll('-', '').toLowerCase();
    if (clean.length != 32) {
      throw const FormatException('Invalid UUID');
    }
    final isHex = RegExp(r'^[0-9a-f]{32}$').hasMatch(clean);
    if (!isHex) {
      throw const FormatException('Invalid UUID');
    }
    return '${clean.substring(0, 8)}-${clean.substring(8, 12)}-${clean.substring(12, 16)}-${clean.substring(16, 20)}-${clean.substring(20, 32)}';
  }

  static bool isSameUuid(String a, String b) {
    return normalizeUuid(a) == normalizeUuid(b);
  }

  static int lectureToken16(String lectureId) {
    final clean = normalizeUuid(lectureId).replaceAll('-', '');
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }

    int hash = 0x811C9DC5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0xFFFF;
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
