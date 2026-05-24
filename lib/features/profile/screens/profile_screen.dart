import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:gap/gap.dart';
import '../../../core/theme/app_theme.dart';

class ResidentProfileScreen extends StatelessWidget {
  const ResidentProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    return FutureBuilder(
      future: Supabase.instance.client
          .from('profiles')
          .select()
          .eq('id', user!.id)
          .single(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final p = snap.data as Map<String, dynamic>;
        return Scaffold(
          appBar: AppBar(title: const Text('ملفي الشخصي')),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: CircleAvatar(
                  radius: 48,
                  backgroundColor: AppColors.primaryContainer,
                  child: Text(
                    (p['full_name'] as String? ?? '?')[0],
                    style: TextStyle(
                      fontSize: 36,
                      color: AppColors.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const Gap(16),
              Center(
                child: Text(
                  p['full_name'] as String? ?? '',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Center(
                child: Text(
                  user.email ?? '',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const Gap(24),
              _tile(
                context,
                Icons.badge_outlined,
                'رقم الجامعة',
                p['university_id'] as String? ?? '—',
              ),
              const Gap(24),
              OutlinedButton.icon(
                onPressed: () async =>
                    await Supabase.instance.client.auth.signOut(),
                icon: const Icon(Icons.logout_rounded),
                label: const Text('تسجيل الخروج'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: BorderSide(color: AppColors.error),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(BuildContext ctx, IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.primary, size: 20),
          const Gap(12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              Text(value, style: Theme.of(ctx).textTheme.bodyLarge),
            ],
          ),
        ],
      ),
    );
  }
}
