import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

class AppErrorMessage {
  static const noInternet = 'تحقق من الاتصال بالانترنت وحاول مجددا';

  static String from(Object error) {
    if (_isNoInternet(error)) return noInternet;

    if (error is AuthException) return _fromAuth(error.message);
    if (error is PostgrestException) return _fromBackend(error.message);
    if (error is StorageException) return _fromBackend(error.message);
    if (error is FunctionException) {
      return _fromBackend(
        error.details?.toString() ?? error.reasonPhrase ?? error.toString(),
      );
    }

    return _fromBackend(error.toString());
  }

  static bool _isNoInternet(Object error) {
    if (error is SocketException) return true;
    final msg = error.toString().toLowerCase();
    const keys = [
      'socketexception',
      'failed host lookup',
      'network is unreachable',
      'connection refused',
      'connection error',
      'connection reset',
      'timed out',
      'timeout',
      'dns',
      'clientexception',
    ];
    return keys.any(msg.contains);
  }

  static String _fromAuth(String message) {
    final msg = message.toLowerCase();
    if (msg.contains('invalid login credentials') ||
        msg.contains('email not found') ||
        msg.contains('invalid email or password')) {
      return 'البريد الإلكتروني أو كلمة المرور غير صحيحة';
    }
    if (msg.contains('email not confirmed')) {
      return 'يرجى تأكيد البريد الإلكتروني أولاً';
    }
    if (msg.contains('too many requests') || msg.contains('rate limit')) {
      return 'محاولات كثيرة، يرجى المحاولة بعد قليل';
    }
    return 'تعذر تسجيل الدخول حالياً. حاول مجددا.';
  }

  static String _fromBackend(String message) {
    final msg = message.toLowerCase();
    if (msg.isEmpty) return 'حدث خطأ غير متوقع. حاول مجددا.';
    if (_containsNoInternetText(msg)) return noInternet;
    if (msg.contains('permission denied') ||
        msg.contains('not allowed') ||
        msg.contains('unauthorized') ||
        msg.contains('forbidden')) {
      return 'ليس لديك صلاحية لتنفيذ هذا الإجراء';
    }
    if (msg.contains('not found')) {
      return 'البيانات المطلوبة غير موجودة';
    }
    if (msg.contains('duplicate') ||
        msg.contains('already exists') ||
        msg.contains('unique')) {
      return 'البيانات موجودة مسبقاً';
    }
    if (msg.contains('invalid') ||
        msg.contains('malformed') ||
        msg.contains('syntax')) {
      return 'البيانات المدخلة غير صحيحة';
    }
    if (msg.contains('timeout') || msg.contains('timed out')) {
      return noInternet;
    }
    if (msg.contains('jwt') || msg.contains('token')) {
      return 'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً';
    }
    if (msg.contains('prerequisite')) {
      return 'لم يُشاهد الفيديو الإلزامي بعد';
    }
    return 'حدث خطأ أثناء تنفيذ الطلب. حاول مجددا.';
  }

  static bool _containsNoInternetText(String msg) {
    return msg.contains('socketexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('network is unreachable') ||
        msg.contains('connection refused') ||
        msg.contains('connection error') ||
        msg.contains('timeout');
  }
}
