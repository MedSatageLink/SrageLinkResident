import 'dart:typed_data';

class BleBoundAttendancePacket {
  final String studentId;
  final int lectureToken16;
  final int eventCode;
  final int requestNonce16;

  const BleBoundAttendancePacket({
    required this.studentId,
    required this.lectureToken16,
    required this.eventCode,
    required this.requestNonce16,
  });
}

class BleAttendanceCodec {
  static const int manufacturerId = 0x1234;
  static const String markerServiceUuidShort = 'a100';
  static const String markerServiceUuidFull =
      '0000a100-0000-1000-8000-00805f9b34fb';
  static const int ackManufacturerVersion = 6;

  // New sender format: [4, event_code, student_uuid_16_bytes, lecture_token_hi, lecture_token_lo]
  // Version 5 adds request nonce: [..., lecture_token_hi, lecture_token_lo, nonce_hi, nonce_lo]
  static const int studentLectureBindingVersion = 5;
  static const int legacyStudentLectureBindingVersion = 4;

  static List<String> buildAckServiceUuids({
    required int lectureToken16,
    required int eventCode,
    required int statusCode,
    required int requestNonce16,
  }) {
    final tokenHex = lectureToken16.toRadixString(16).padLeft(4, '0');
    final eventHex = eventCode.toRadixString(16).padLeft(2, '0');
    final statusHex = statusCode.toRadixString(16).padLeft(2, '0');
    final ackMeta = (tokenHex + eventHex + statusHex).toLowerCase();
    final nonceHex = requestNonce16.toRadixString(16).padLeft(4, '0');
    final nonceMarker = (nonceHex + 'a500').toLowerCase();

    return <String>[markerServiceUuidShort, ackMeta, nonceMarker];
  }

  static Uint8List buildAckManufacturerData({
    required int lectureToken16,
    required int eventCode,
    required int statusCode,
    required int requestNonce16,
  }) {
    return Uint8List.fromList(<int>[
      ackManufacturerVersion,
      eventCode & 0xFF,
      statusCode & 0xFF,
      (lectureToken16 >> 8) & 0xFF,
      lectureToken16 & 0xFF,
      (requestNonce16 >> 8) & 0xFF,
      requestNonce16 & 0xFF,
    ]);
  }

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
    if (bytes.isEmpty) return null;
    if (bytes[0] != studentLectureBindingVersion &&
        bytes[0] != legacyStudentLectureBindingVersion) {
      return null;
    }

    if (bytes[0] == legacyStudentLectureBindingVersion) {
      if (bytes.length != 20) return null;
      final eventCode = bytes[1] & 0xFF;
      if (eventCode != 1 && eventCode != 2) return null;
      final student = _bytesToUuid(bytes.sublist(2, 18));
      final token = ((bytes[18] & 0xFF) << 8) | (bytes[19] & 0xFF);
      return BleBoundAttendancePacket(
        studentId: student,
        lectureToken16: token,
        eventCode: eventCode,
        requestNonce16: 0,
      );
    }

    if (bytes.length != 22) return null;
    final eventCode = bytes[1] & 0xFF;
    if (eventCode != 1 && eventCode != 2) return null;
    final student = _bytesToUuid(bytes.sublist(2, 18));
    final token = ((bytes[18] & 0xFF) << 8) | (bytes[19] & 0xFF);
    final nonce = ((bytes[20] & 0xFF) << 8) | (bytes[21] & 0xFF);
    return BleBoundAttendancePacket(
      studentId: student,
      lectureToken16: token,
      eventCode: eventCode,
      requestNonce16: nonce,
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

  /// Parse service UUIDs broadcasted by student devices.
  /// Returns map with keys: 'studentUuid' (String), 'lectureToken' (int), 'eventCode' (int), 'requestNonce16' (int)
  static Map<String, dynamic> parseServiceBroadcastInfo(
    Iterable<String> serviceUuids,
  ) {
    final normalized = <String>[];
    for (final uuid in serviceUuids) {
      final n = _tryNormalizeUuid(uuid);
      if (n != null) normalized.add(n);
    }
    final out = <String, dynamic>{};
    if (normalized.isEmpty) return out;

    // detect marker (may be omitted by some platforms when adv payload is tight)
    final hasMarker = normalized.contains(markerServiceUuidFull);
    out['hasMarker'] = hasMarker;

    // find student UUID: prefer a true 128-bit raw UUID entry (32 hex chars).
    for (final raw in serviceUuids) {
      final clean = raw.replaceAll('-', '').toLowerCase();
      if (clean.length != 32) continue;
      final n = _tryNormalizeUuid(raw);
      if (n == null || n == markerServiceUuidFull) continue;
      out['studentUuid'] = n;
      break;
    }

    // also scan raw/expanded list for token/event payload.
    // payload layout (8 hex chars): [token_hi2][token_lo2][event][reserved]
    int? parsedToken;
    int? parsedEvent;

    Iterable<String> payloadCandidates() sync* {
      const baseSuffix = '00001000800000805f9b34fb';
      for (final raw in serviceUuids) {
        final clean = raw.replaceAll('-', '').toLowerCase();
        if (clean.length == 8) {
          yield clean;
          continue;
        }
        if (clean.length == 32 && clean.endsWith(baseSuffix)) {
          yield clean.substring(0, 8);
        }
      }
    }

    for (final payload in payloadCandidates()) {
      try {
        final tokenHex = payload.substring(0, 4);
        final eventHex = payload.substring(4, 6);
        final token = int.parse(tokenHex, radix: 16);
        final event = int.parse(eventHex, radix: 16);
        if (event == 1 || event == 2) {
          parsedToken = token;
          parsedEvent = event;
          break;
        }
      } catch (_) {}
    }

    // Fallback for legacy short token UUID (4-char), ignore marker UUID a100.
    if (parsedToken == null) {
      for (final raw in serviceUuids) {
        final clean = raw.replaceAll('-', '').toLowerCase();
        if (clean.length != 4) continue;
        if (clean == 'a100') continue;
        try {
          parsedToken = int.parse(clean, radix: 16);
          break;
        } catch (_) {}
      }
    }

    if (parsedToken != null) out['lectureToken'] = parsedToken;
    if (parsedEvent != null) out['eventCode'] = parsedEvent;

    for (final payload in payloadCandidates()) {
      if (payload.endsWith('a500')) {
        try {
          out['requestNonce16'] = int.parse(payload.substring(0, 4), radix: 16);
          break;
        } catch (_) {}
      }
    }

    /*
     * NOTE:
     * We intentionally do not treat 4-char marker UUIDs (a100) as lecture tokens,
     * because that causes false token mismatches (e.g., 41216 from a100).
     */

    return out;
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
