import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:stagelink_resident/core/utils/app_error_message.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/device_service.dart';

class ResidentLoginScreen extends ConsumerStatefulWidget {
  const ResidentLoginScreen({super.key});
  @override
  ConsumerState<ResidentLoginScreen> createState() => _State();
}

class _State extends ConsumerState<ResidentLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  static const _cardBg = Color(0xFFF8FAFC);
  static const _fieldBg = Color(0xFFF1F5F9);
  static const _fieldBorder = Color(0xFFCBD5E1);
  static const _fieldText = Color(0xFF0F172A);
  static const _fieldHint = Color(0xFF64748B);
  static const _buttonBg = Color(0xFF059669);

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  InputDecoration _fieldDecoration({
    required String label,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: _fieldHint),
      suffixIcon: suffix,
      filled: true,
      fillColor: _fieldBg,
      labelStyle: const TextStyle(color: _fieldHint),
      hintStyle: const TextStyle(color: _fieldHint),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _fieldBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _buttonBg, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.error, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final username = _usernameCtrl.text.trim().toLowerCase();
      final resolve = await Supabase.instance.client.rpc(
        'resolve_login_username',
        params: {'p_username': username},
      );
      final resolveMap = Map<String, dynamic>.from(resolve as Map);
      if (resolveMap['status'] != 'ok') {
        throw Exception('اسم المستخدم أو كلمة المرور غير صحيحة');
      }

      await Supabase.instance.client.auth.signInWithPassword(
        email: resolveMap['auth_email'] as String,
        password: _passCtrl.text,
      );

      final deviceId = await DeviceService().getDeviceId();
      final lockRes = await Supabase.instance.client.rpc(
        'finalize_device_login',
        params: {'p_device_id': deviceId},
      );
      final lockMap = Map<String, dynamic>.from(lockRes as Map);
      if (lockMap['status'] != 'ok') {
        await Supabase.instance.client.auth.signOut();
        final msg = lockMap['message'] as String?;
        if (msg == 'reactivation_required') {
          throw Exception('الحساب مقفول. يرجى طلب إعادة تفعيل من الإدارة');
        }
        if (msg == 'same_device_only') {
          throw Exception('إعادة التفعيل مقيدة بنفس الجهاز السابق فقط');
        }
        if (msg == 'account_disabled') {
          throw Exception('الحساب معطّل حالياً');
        }
        throw Exception('غير مسموح بتسجيل الدخول من هذا الجهاز');
      }

      ref.invalidate(routerProvider);
    } catch (e) {
      setState(() => _error = AppErrorMessage.from(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF065F46), Color(0xFF059669), Color(0xFF475569)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Icon(
                        Icons.medical_services_rounded,
                        color: Colors.white,
                        size: 48,
                      ),
                    ).animate().scale(
                      duration: 600.ms,
                      curve: Curves.elasticOut,
                    ),
                    const Gap(20),
                    Text(
                      'StageLink',
                      style: GoogleFonts.cairo(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ).animate(delay: 200.ms).fadeIn().slideY(begin: 0.2),
                    Text(
                      'بوابة المقيم',
                      style: GoogleFonts.cairo(
                        fontSize: 15,
                        color: Colors.white70,
                      ),
                    ).animate(delay: 300.ms).fadeIn(),
                    const Gap(36),
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: _cardBg,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.65),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x22000000),
                            blurRadius: 20,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          TextFormField(
                            controller: _usernameCtrl,
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(color: _fieldText),
                            decoration: _fieldDecoration(
                              label: 'اسم المستخدم',
                              icon: Icons.alternate_email_rounded,
                            ),
                            validator: (v) =>
                                v!.isEmpty ? 'أدخل اسم المستخدم' : null,
                          ),
                          const Gap(16),
                          TextFormField(
                            controller: _passCtrl,
                            obscureText: _obscure,
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(color: _fieldText),
                            decoration: _fieldDecoration(
                              label: 'كلمة المرور',
                              icon: Icons.lock_outline_rounded,
                              suffix: IconButton(
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: _fieldHint,
                                ),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ),
                            validator: (v) =>
                                v!.isEmpty ? 'أدخل كلمة المرور' : null,
                          ),
                          if (_error != null) ...[
                            const Gap(12),
                            Text(
                              _error!,
                              style: const TextStyle(color: AppColors.error),
                            ),
                          ],
                          const Gap(20),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _loading ? null : _login,
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                backgroundColor: _buttonBg,
                                foregroundColor: Colors.white,
                              ),
                              child: _loading
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text(
                                      'تسجيل الدخول',
                                      style: TextStyle(fontSize: 16),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ).animate(delay: 400.ms).fadeIn().slideY(begin: 0.1),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
