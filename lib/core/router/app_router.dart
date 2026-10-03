import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/screens/login_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/scanner/screens/scanner_screen.dart';
import '../../features/scanner/screens/multi_lecture_scanner_screen.dart';
import '../../features/lectures/screens/my_lectures_screen.dart';
import '../../features/videos/screens/create_practical_video_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final session = Supabase.instance.client.auth.currentSession;
      final isLoggedIn = session != null;
      if (!isLoggedIn && state.matchedLocation != '/login') return '/login';
      if (isLoggedIn && state.matchedLocation == '/login') return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const ResidentLoginScreen()),
      GoRoute(path: '/', builder: (_, _) => const ResidentHomeScreen()),
      GoRoute(
        path: '/scan/:lectureId',
        builder: (_, state) =>
            ScannerScreen(lectureId: state.pathParameters['lectureId']!),
      ),
      GoRoute(
        path: '/scan-subject/:subjectId',
        builder: (_, state) {
          final lectures =
              (state.extra as List?)?.cast<Map<String, dynamic>>() ??
              <Map<String, dynamic>>[];
          return MultiLectureScannerScreen(
            subjectId: state.pathParameters['subjectId']!,
            lectures: lectures,
          );
        },
      ),
      GoRoute(
        path: '/scan-compensation/:subjectId',
        builder: (_, state) => MultiLectureScannerScreen(
          subjectId: state.pathParameters['subjectId']!,
          lectures: const <Map<String, dynamic>>[],
          compensationMode: true,
        ),
      ),
      GoRoute(
        path: '/my-lectures',
        builder: (_, _) => const MyLecturesScreen(),
      ),
      GoRoute(
        path: '/practical-videos/create',
        builder: (_, _) => const CreatePracticalVideoScreen(),
      ),
    ],
  );
});
