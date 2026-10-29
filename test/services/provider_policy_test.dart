import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_aware_ai/services/ai_service.dart';
import 'package:screen_aware_ai/services/local_model_service.dart';
import 'package:screen_aware_ai/services/screen_capture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('GGUF header validation rejects wrong and truncated files', () {
    expect(LocalModelService.isGgufHeader([0x47, 0x47, 0x55, 0x46]), isTrue);
    expect(LocalModelService.isGgufHeader([0x47, 0x47, 0x55]), isFalse);
    expect(LocalModelService.isGgufHeader([0, 0, 0, 0]), isFalse);
  });

  test(
    'Local Only never permits Gemini, even with fallback and consent',
    () async {
      final localModel = LocalModelService(ScreenCaptureManager());
      final ai = AiService(localModel);
      await ai.initialize();
      ai.configure('test-key');
      await ai.setCloudFallbackEnabled(true);
      await ai.setAllowGeminiData(true);
      await ai.setProviderMode(AiProviderMode.localOnly);

      expect(ai.mayUseGemini(localUnavailableOrFailed: true), isFalse);
      expect(ai.canInterpretRequests, isFalse);
    },
  );

  test(
    'Local First requires fallback, consent, and local unavailability',
    () async {
      final ai = AiService(LocalModelService(ScreenCaptureManager()));
      await ai.initialize();
      ai.configure('test-key');
      await ai.setProviderMode(AiProviderMode.localFirst);
      await ai.setAllowGeminiData(true);

      expect(ai.mayUseGemini(localUnavailableOrFailed: true), isFalse);
      await ai.setCloudFallbackEnabled(true);
      expect(ai.mayUseGemini(), isFalse);
      expect(ai.mayUseGemini(localUnavailableOrFailed: true), isTrue);

      await ai.setAllowGeminiData(false);
      expect(ai.mayUseGemini(localUnavailableOrFailed: true), isFalse);
    },
  );

  test('Cloud Preferred still requires explicit cloud-data consent', () async {
    final ai = AiService(LocalModelService(ScreenCaptureManager()));
    await ai.initialize();
    ai.configure('test-key');
    await ai.setProviderMode(AiProviderMode.cloudPreferred);

    expect(ai.mayUseGemini(), isFalse);
    await ai.setAllowGeminiData(true);
    expect(ai.mayUseGemini(), isTrue);
  });

  test('screenshots are captured only for a permitted cloud route', () async {
    final ai = AiService(LocalModelService(ScreenCaptureManager()));
    await ai.initialize();
    expect(ai.requiresScreenshot, isFalse);

    ai.configure('test-key');
    await ai.setProviderMode(AiProviderMode.cloudPreferred);
    expect(ai.requiresScreenshot, isFalse);
    await ai.setAllowGeminiData(true);
    expect(ai.requiresScreenshot, isTrue);

    await ai.setProviderMode(AiProviderMode.localOnly);
    expect(ai.requiresScreenshot, isFalse);
  });
}
