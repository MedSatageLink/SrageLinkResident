import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:gap/gap.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/services/attendance_sync_service.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  final String lectureId;
  const ScannerScreen({super.key, required this.lectureId});
  @override
  ConsumerState<ScannerScreen> createState() => _State();
}

class _State extends ConsumerState<ScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _processing = false;
  String? _lastResult;
  bool _lastSuccess = false;

  @override
  void initState() {
    super.initState();
    AttendanceSyncService.instance.syncPendingQueue();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null) return;

    setState(() => _processing = true);

    try {
      final payload = jsonDecode(code) as Map<String, dynamic>;
      final studentId = payload['student_id'] as String?;
      final lectureId = payload['lecture_id'] as String?;

      if (studentId == null ||
          lectureId == null ||
          lectureId != widget.lectureId) {
        setState(() {
          _lastResult = 'رمز QR غير صالح';
          _lastSuccess = false;
        });
        await Future.delayed(const Duration(seconds: 2));
        setState(() => _processing = false);
        return;
      }

      final result = await AttendanceSyncService.instance.processScan(
        lectureId: lectureId,
        studentId: studentId,
      );

      setState(() {
        _lastResult = result.message;
        _lastSuccess = result.success;
      });
    } on PostgrestException catch (e) {
      String msg = 'فشل التسجيل';
      if (e.message.contains('prerequisite')) {
        msg = 'لم يُشاهد الفيديو الإلزامي';
      } else if (e.message.contains('duplicate') ||
          e.message.contains('unique')) {
        msg = 'تم تسجيل هذا الطالب مسبقاً';
      }
      setState(() {
        _lastResult = msg;
        _lastSuccess = false;
      });
    } catch (e) {
      setState(() {
        _lastResult = 'خطأ: $e';
        _lastSuccess = false;
      });
    } finally {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح رمز QR'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on_rounded),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),

          // Overlay frame
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),

          // Result banner
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
