import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/command_router.dart';

void main() {
  const router = LocalCommandRouter();

  test('routes exact navigation and app commands without substring matches', () {
    expect(router.route('Go back')?.action?.type, 'back');
    expect(
      router.route('OPEN YouTube!')?.action?.params['package'],
      'com.google.android.youtube',
    );
    expect(router.route('Please open YouTube'), isNull);
    expect(router.route('open an unknown application'), isNull);
  });

  test('routes listening controls distinctly', () {
    expect(router.route('stop listening')?.type, LocalCommandType.stop);
    expect(router.route('go to sleep')?.type, LocalCommandType.sleep);
    expect(router.route('cancel')?.type, LocalCommandType.cancel);
    expect(router.route('repeat that')?.type, LocalCommandType.repeat);
  });
}
