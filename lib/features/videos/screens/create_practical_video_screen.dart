import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:gap/gap.dart';
import 'package:stagelink_resident/core/utils/app_error_message.dart';

import '../../../core/theme/app_theme.dart';

final residentSubjectProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;
  final res = await Supabase.instance.client
      .from('profiles')
      .select('subject_id, subjects(name)')
      .eq('id', uid)
      .single();
  return Map<String, dynamic>.from(res);
});

final myPracticalVideosProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;
  final res = await Supabase.instance.client
      .from('practical_videos')
      .select('id, title, description, youtube_video_id, created_at')
      .eq('resident_id', uid)
      .order('created_at', ascending: false);
  return List<Map<String, dynamic>>.from(res as List);
});

class CreatePracticalVideoScreen extends ConsumerStatefulWidget {
  const CreatePracticalVideoScreen({super.key});

  @override
  ConsumerState<CreatePracticalVideoScreen> createState() => _State();
}

class _State extends ConsumerState<CreatePracticalVideoScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  String? _extractYouTubeId(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return null;

    if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(raw)) return raw;

    final uri = Uri.tryParse(raw);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    if (host.contains('youtube.com')) {
      final v = uri.queryParameters['v'];
      if (v != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(v)) return v;
      final segments = uri.pathSegments;
      if (segments.length >= 2 && segments.first == 'shorts') {
        final id = segments[1];
        if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id)) return id;
      }
    }

    if (host.contains('youtu.be')) {
      final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id)) return id;
    }

    return null;
  }

  Future<void> _submit(String subjectId) async {
    if (!_formKey.currentState!.validate()) return;

    final ytId = _extractYouTubeId(_urlCtrl.text);
    if (ytId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('رابط يوتيوب غير صالح'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final uid = Supabase.instance.client.auth.currentUser!.id;
      await Supabase.instance.client.from('practical_videos').insert({
        'subject_id': subjectId,
        'resident_id': uid,
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim().isEmpty
            ? null
            : _descCtrl.text.trim(),
        'youtube_video_id': ytId,
      });

      if (!mounted) return;
      _titleCtrl.clear();
      _descCtrl.clear();
      _urlCtrl.clear();
      ref.invalidate(myPracticalVideosProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم إنشاء الفيديو بنجاح ✓'),
          backgroundColor: AppColors.success,
        ),
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppErrorMessage.from(e)),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editVideo(Map<String, dynamic> video) async {
    final titleCtrl = TextEditingController(
      text: video['title'] as String? ?? '',
    );
    final descCtrl = TextEditingController(
      text: video['description'] as String? ?? '',
    );
    final urlCtrl = TextEditingController(
      text: video['youtube_video_id'] as String? ?? '',
    );
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعديل الفيديو'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: 'اسم الفيديو'),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'اسم الفيديو مطلوب'
                      : null,
                ),
                const Gap(10),
                TextFormField(
                  controller: descCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'الوصف (اختياري)',
                  ),
                ),
                const Gap(10),
                TextFormField(
                  controller: urlCtrl,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'رابط فيديو يوتيوب أو Video ID',
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'رابط يوتيوب مطلوب'
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              final ytId = _extractYouTubeId(urlCtrl.text);
              if (ytId == null) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('رابط يوتيوب غير صالح'),
                    backgroundColor: AppColors.error,
                  ),
                );
                return;
              }

              final uid = Supabase.instance.client.auth.currentUser!.id;
              await Supabase.instance.client
                  .from('practical_videos')
                  .update({
                    'title': titleCtrl.text.trim(),
                    'description': descCtrl.text.trim().isEmpty
                        ? null
                        : descCtrl.text.trim(),
                    'youtube_video_id': ytId,
                  })
                  .eq('id', video['id'] as String)
                  .eq('resident_id', uid);

              if (ctx.mounted) Navigator.pop(ctx);
              ref.invalidate(myPracticalVideosProvider);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteVideo(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الفيديو؟'),
        content: const Text('لا يمكن التراجع بعد الحذف.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final uid = Supabase.instance.client.auth.currentUser!.id;
    await Supabase.instance.client
        .from('practical_videos')
        .delete()
        .eq('id', id)
        .eq('resident_id', uid);
    ref.invalidate(myPracticalVideosProvider);
  }

  @override
  Widget build(BuildContext context) {
    final subjectAsync = ref.watch(residentSubjectProvider);
    final videosAsync = ref.watch(myPracticalVideosProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('إنشاء فيديو عملي')),
      body: subjectAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
        data: (profile) {
          final subjectId = profile['subject_id'] as String?;

          if (subjectId == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'لا يمكن إنشاء فيديو قبل ربط المقيم بمادة (subject_id).',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _titleCtrl,
                      decoration: const InputDecoration(
                        labelText: 'اسم الفيديو',
                        prefixIcon: Icon(Icons.title_rounded),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'اسم الفيديو مطلوب';
                        }
                        return null;
                      },
                    ),
                    const Gap(10),
                    TextFormField(
                      controller: _descCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'الوصف (اختياري)',
                        prefixIcon: Icon(Icons.description_outlined),
                      ),
                    ),
                    const Gap(10),
                    TextFormField(
                      controller: _urlCtrl,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        labelText: 'رابط فيديو يوتيوب أو Video ID',
                        prefixIcon: Icon(Icons.link_rounded),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'رابط يوتيوب مطلوب';
                        }
                        return null;
                      },
                    ),
                    const Gap(14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : () => _submit(subjectId),
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add_circle_outline_rounded),
                        label: Text(
                          _saving ? 'جارِ الحفظ...' : 'إنشاء الفيديو',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Gap(20),
              Text('فيديوهاتي', style: Theme.of(context).textTheme.titleMedium),
              const Gap(8),
              videosAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(AppErrorMessage.from(e)),
                ),
                data: (videos) {
                  if (videos.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('لا توجد فيديوهات منشأة بعد.'),
                    );
                  }
                  return Column(
                    children: videos.map((v) {
                      final ytId = v['youtube_video_id'] as String? ?? '';
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedNetworkImage(
                              imageUrl:
                                  'https://img.youtube.com/vi/$ytId/mqdefault.jpg',
                              width: 72,
                              height: 44,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => Container(
                                width: 72,
                                height: 44,
                                color: AppColors.surfaceVariant,
                                child: const Icon(Icons.play_circle_outline),
                              ),
                            ),
                          ),
                          title: Text(v['title'] as String? ?? '—'),
                          subtitle:
                              (v['description'] as String?)
                                      ?.trim()
                                      .isNotEmpty ==
                                  true
                              ? Text(v['description'] as String)
                              : const Text('بدون وصف'),
                          trailing: Wrap(
                            spacing: 2,
                            children: [
                              IconButton(
                                tooltip: 'تعديل',
                                onPressed: () => _editVideo(v),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: 'حذف',
                                onPressed: () =>
                                    _deleteVideo(v['id'] as String),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: AppColors.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
