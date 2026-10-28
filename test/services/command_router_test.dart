import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/command_router.dart';

void main() {
  const router = LocalCommandRouter();

  group('Navigation commands', () {
    test('recognizes back and home commands', () {
      expect(router.route('Go back')?.action?.type, 'back');
      expect(router.route('back')?.action?.type, 'back');
      expect(router.route('Go home')?.action?.type, 'home');
      expect(router.route('home')?.action?.type, 'home');
    });
  });

  group('App launching', () {
    test('recognizes common apps regardless of capitalization', () {
      expect(
        router.route('OPEN YouTube!')?.action?.params['package'],
        'com.google.android.youtube',
      );
      expect(
        router.route('open Chrome')?.action?.params['package'],
        'com.android.chrome',
      );
      expect(
        router.route('open Settings')?.action?.params['package'],
        'com.android.settings',
      );
    });

    test('supports polite app commands', () {
      expect(
        router.route('Please open YouTube')?.action?.params['package'],
        'com.google.android.youtube',
      );
      expect(
        router.route('launch WhatsApp')?.action?.params['package'],
        'com.whatsapp',
      );
    });

    test('rejects unknown applications and unrelated sentences', () {
      expect(router.route('open an unknown application'), isNull);
      expect(router.route('I like watching YouTube'), isNull);
      expect(router.route(''), isNull);
    });
  });

  group('YouTube search', () {
    test('creates a YouTube search URL', () {
      final command = router.route('search YouTube for Flutter tutorials');

      expect(command?.action?.type, 'open_url');

      final url = Uri.parse(command!.action!.params['url'] as String);

      expect(url.host, 'www.youtube.com');
      expect(url.path, '/results');
      expect(url.queryParameters['search_query'], 'flutter tutorials');
    });

    test('supports play requests as searches, not guaranteed playback', () {
      final command = router.route('play Flutter animations');

      final url = Uri.parse(command!.action!.params['url'] as String);

      expect(url.queryParameters['search_query'], 'flutter animations');
    });

    test('rejects empty YouTube searches', () {
      expect(router.route('search YouTube for'), isNull);
    });
  });

  group('Listening controls', () {
    test('routes stop, sleep, cancel, and repeat separately', () {
      expect(router.route('stop listening')?.type, LocalCommandType.stop);
      expect(router.route('go to sleep')?.type, LocalCommandType.sleep);
      expect(router.route('cancel')?.type, LocalCommandType.cancel);
      expect(router.route('repeat that')?.type, LocalCommandType.repeat);
    });
  });
}
