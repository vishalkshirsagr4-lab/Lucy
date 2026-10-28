import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

class VoiceService {
  VoiceService({
    this.maxUtteranceDuration = const Duration(seconds: 60),
    this.endOfUtteranceSilence = const Duration(milliseconds: 1500),
  });

  final Duration maxUtteranceDuration;
  final Duration endOfUtteranceSilence;
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isSpeechInitialized = false;
  bool _isTtsInitialized = false;
  bool _isListening = false;
  bool _isSpeaking = false;
  bool _errorOccurred = false;
  String _currentTtsLanguage = 'en-US';
  int _recognitionSequence = 0;
  String? _recognitionId;
  Stopwatch? _recognitionTimer;

  static const Map<String, String> _langToTtsLocale = {
    'en': 'en-US',
    'ja': 'ja-JP',
    'ar': 'ar-SA',
  };

  // speech_to_text uses the same locale IDs as TTS on Android.
  static const Map<String, String> _langToSttLocale = {
    'en': 'en_US',
    'ja': 'ja_JP',
    'ar': 'ar_SA',
  };

  /// Resolve a short language code ("en"/"ja") to an STT locale ID.
  /// Returns null for unknown codes so STT falls back to its default.
  static String? sttLocaleFor(String? lang) =>
      _langToSttLocale[lang?.toLowerCase()];

  bool get isListening => _isListening;
  bool get isSpeaking => _isSpeaking;
  bool get speechRecognitionReady => _isSpeechInitialized;
  double _speechRate = 0.5;

  // Callbacks
  Function(String text, bool isFinal)? onResult;
  Function()? onListeningDone;
  Function(String error)? onError;

  Future<bool> initialize() async {
    if (_isSpeechInitialized) return true;

    try {
      _isSpeechInitialized = await _speech.initialize(
        onError: (error) {
          _isListening = false;
          _errorOccurred = true;
          debugPrint(
            'Lucy[${_recognitionId ?? "unknown"}] stage=speech_recognition_error code=${error.errorMsg}',
          );
          onError?.call(error.errorMsg);
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            _isListening = false;
            final elapsed = _recognitionTimer?.elapsedMilliseconds;
            if (elapsed != null) {
              debugPrint(
                'Lucy[${_recognitionId ?? "unknown"}] stage=speech_capture_end elapsed_ms=$elapsed status=$status',
              );
            }
            if (_errorOccurred) {
              _errorOccurred = false;
            } else {
              onListeningDone?.call();
            }
          }
        },
      );

      await _initializeTts();
      return _isSpeechInitialized;
    } catch (e) {
      onError?.call('Failed to initialize voice: $e');
      return false;
    }
  }

  Future<void> _initializeTts() async {
    if (_isTtsInitialized) return;
    await _tts.setLanguage('en-US');
    _currentTtsLanguage = 'en-US';
    await _tts.setSpeechRate(_speechRate);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
    });
    _tts.setErrorHandler((message) {
      _isSpeaking = false;
      onError?.call('Text-to-speech failed: $message');
    });
    _isTtsInitialized = true;
  }

  Future<void> setSpeechRate(double rate) async {
    if (rate < 0.1 || rate > 1.0) {
      throw ArgumentError.value(rate, 'rate', 'Must be between 0.1 and 1.0');
    }
    _speechRate = rate;
    if (_isTtsInitialized) {
      await _tts.setSpeechRate(rate);
    }
  }

  double get speechRate => _speechRate;

  Future<void> startListening({String? localeId}) async {
    if (!_isSpeechInitialized) {
      final initialized = await initialize();
      if (!initialized) {
        onError?.call('Speech recognition is unavailable on this device.');
        return;
      }
    }

    // Stop TTS if speaking
    if (_isSpeaking) {
      await stopSpeaking();
    }

    if (_isListening) return;

    // Cancel any lingering STT session to ensure a clean engine state
    await _speech.cancel();

    _recognitionId = 'stt-${++_recognitionSequence}';
    _recognitionTimer = Stopwatch()..start();
    debugPrint('Lucy[$_recognitionId] stage=speech_capture_start');
    _isListening = true;
    _errorOccurred = false;
    try {
      await _speech.listen(
        onResult: (result) {
          onResult?.call(result.recognizedWords, result.finalResult);
        },
        listenFor: maxUtteranceDuration,
        pauseFor: endOfUtteranceSilence,
        localeId: localeId,
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (error) {
      _isListening = false;
      _recognitionTimer = null;
      onError?.call('Could not start speech recognition: $error');
    }
  }

  Future<void> stopListening() async {
    if (_isListening) {
      await _speech.stop();
      _isListening = false;
    }
  }

  Future<void> speak(String text, {String? lang}) async {
    await _initializeTts();

    if (_isSpeaking) {
      await stopSpeaking();
    }

    // Stop listening while speaking
    if (_isListening) {
      await stopListening();
    }

    final targetLocale = _langToTtsLocale[lang?.toLowerCase()] ?? 'en-US';
    if (targetLocale != _currentTtsLanguage) {
      await _tts.setLanguage(targetLocale);
      _currentTtsLanguage = targetLocale;
    }

    _isSpeaking = true;
    await _tts.speak(text);
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
    _isSpeaking = false;
  }

  void dispose() {
    _speech.stop();
    _speech.cancel();
    _tts.stop();
  }
}
