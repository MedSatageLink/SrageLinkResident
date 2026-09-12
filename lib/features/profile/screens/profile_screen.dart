import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:gap/gap.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_mode_provider.dart';

class ResidentProfileScreen extends ConsumerWidget {
  const ResidentProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = Supabase.instance.client.auth.currentUser;
    final themeMode = ref.watch(themeModeProvider);
    final isDark = themeMode == ThemeMode.dark;
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
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                child: SwitchListTile.adaptive(
                  value: isDark,
                  onChanged: (value) => ref
                      .read(themeModeProvider.notifier)
                      .setThemeMode(value ? ThemeMode.dark : ThemeMode.light),
                  title: const Text('الوضع الداكن'),
                  subtitle: Text(isDark ? 'مفعل' : 'غير مفعل'),
                  secondary: Icon(
                    isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                    color: AppColors.primary,
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const Gap(24),
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
        color: Theme.of(ctx).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(ctx).colorScheme.outline),
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
                  color: Theme.of(
                    ctx,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
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
