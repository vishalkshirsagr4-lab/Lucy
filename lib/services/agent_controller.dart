import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';
import 'command_router.dart';
import 'local_model_service.dart';
import 'voice_service.dart';
import 'screen_capture_service.dart';

enum AgentState {
  idle,
  listening,
  capturing,
  analyzing,
  speaking,
  waitingConfirmation,
  executingAction,
}

class ConversationEntry {
  final String text;
  final bool isUser;
  final Uint8List? screenshotBytes;
  final DateTime timestamp;

  ConversationEntry({
    required this.text,
    required this.isUser,
    this.screenshotBytes,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class _UiSnapshot {
  final String? rawTree;
  final String? packageName;
  final List<Map<String, dynamic>> elements;
  final bool hasFocusedEditable;

  const _UiSnapshot({
    required this.rawTree,
    required this.packageName,
    required this.elements,
    required this.hasFocusedEditable,
  });

  String get signature => rawTree ?? '';
}

class _ActionExecutionResult {
  const _ActionExecutionResult(this.snapshot, this.succeeded);

  final _UiSnapshot? snapshot;
  final bool succeeded;
}

class AgentController extends ChangeNotifier with WidgetsBindingObserver {
  AgentController() {
    WidgetsBinding.instance.addObserver(this);
    _localModel.addListener(_onLocalModelChanged);
  }

  final VoiceService _voiceService = VoiceService();
  final ScreenCaptureManager _screenCapture = ScreenCaptureManager();
  final LocalCommandRouter _commandRouter = LocalCommandRouter();
  late final LocalModelService _localModel = LocalModelService(_screenCapture);
  late final AiService _aiService = AiService(_localModel);

  AgentState _state = AgentState.idle;
  AgentState get state => _state;

  final List<ConversationEntry> _conversation = [];
  List<ConversationEntry> get conversation => List.unmodifiable(_conversation);

  String _statusMessage =
      'Use a text command or start manual foreground listening.';
  String get statusMessage => _statusMessage;

  Uint8List? _lastScreenshotBytes;
  Uint8List? get lastScreenshotBytes => _lastScreenshotBytes;

  String? _currentTranscript = '';
  String? get currentTranscript => _currentTranscript;

  bool _isActive = false;
  bool get isActive => _isActive;

  int _listenRetryCount = 0;
  static const int _maxListenRetries = 3;

  static const int _maxStepsPerCommand = 12;
  static const Duration _maxTaskDuration = Duration(minutes: 2);
  static const Duration _uiPollInterval = Duration(milliseconds: 120);
  static const Duration _tapReadyTimeout = Duration(milliseconds: 900);
  static const Duration _typeReadyTimeout = Duration(milliseconds: 900);
  static const Duration _navigationReadyTimeout = Duration(milliseconds: 1200);
  static const Duration _openAppReadyTimeout = Duration(milliseconds: 2500);

  bool _cancelRequested = false;

  bool _isAskingForFurtherHelp = false;
  String? _lastAssistantResponse;
  String _streamingStatus = '';
  int _requestSequence = 0;
  bool _isVoiceReady = false;
  Timer? _followupTimeoutTimer;
  Duration _followupTimeout = const Duration(minutes: 2);
  static const String _historyPrefKey = 'lucy_conversation_history';
  static const int _maxHistoryEntries = 100;
  Future<void> _historyWrite = Future<void>.value();

  /// Language code of the most recent agent reply ("en" or "ja").
  /// Used to localize hardcoded follow-ups, cancel-word detection, TTS, and STT locale.
  String _currentLang = 'en';
  String get currentLang => _currentLang;

  static const String _langPrefKey = 'lucy_lang';
  static const Set<String> _supportedLangs = {'en', 'ja', 'ar'};

  /// Set the UI/voice language. Persists across restarts. Restarts the
  /// listener if currently active so STT picks up the new locale.
  Future<void> setLanguage(String lang) async {
    final normalized = lang.toLowerCase();
    if (!_supportedLangs.contains(normalized)) return;
    if (_currentLang == normalized) return;
    _currentLang = normalized;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_langPrefKey, normalized);
    if (_isActive && _state == AgentState.listening) {
      await _voiceService.stopListening();
      _startListening();
    }
  }

  Future<void> setSpeechRate(double rate) async {
    await _voiceService.setSpeechRate(rate);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('lucy_speech_rate', rate);
    notifyListeners();
  }

  Future<void> setFollowupTimeout(Duration timeout) async {
    if (timeout < const Duration(seconds: 15) ||
        timeout > const Duration(minutes: 10)) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'Must be between 15 seconds and 10 minutes',
      );
    }
    _followupTimeout = timeout;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lucy_followup_timeout_seconds', timeout.inSeconds);
    _followupTimeoutTimer?.cancel();
    _followupTimeoutTimer = null;
    if (_isActive && _isAskingForFurtherHelp) {
      _scheduleFollowupTimeout();
    }
    notifyListeners();
  }

  static const Map<String, String> _followUps = {
    'en': 'Do you need any further help?',
    'ja': '他に何かお手伝いできることはありますか？',
    'ar': 'هل تحتاج إلى أي مساعدة أخرى؟',
  };
  static const Map<String, String> _stoppingMessages = {
    'en': 'Alright, stopping the agent.',
    'ja': 'わかりました。エージェントを停止します。',
    'ar': 'حسنًا، سأوقف المساعد الآن.',
  };

  // Patterns that mean "no, I'm done" when replying to the follow-up prompt.
  static final RegExp _negativeEn = RegExp(
    r'^(no|nope|nah|stop|exit|nothing|not\b.*)$',
  );
  // Hiragana/katakana/kanji forms of "no", "stop", "that's enough", "done".
  static final RegExp _negativeJa = RegExp(
    r'(いいえ|いえ|けっこう|結構|もういい|もう大丈夫|大丈夫|終了|終わり|やめて|止めて|停止|いらない|不要|ない)',
  );
  // Arabic forms: "no", "stop", "enough", "done", "nothing".
  static final RegExp _negativeAr = RegExp(
    r'(لا|كلا|توقف|قف|اوقف|أوقف|اكتفي|يكفي|كفى|انتهى|انتهيت|خلاص|لا شيء|لا شكرا|لا شكرًا)',
  );

  AiService get aiService => _aiService;
  LocalModelService get localModel => _localModel;
  ScreenCaptureManager get screenCapture => _screenCapture;
  bool get speechRecognitionReady => _isVoiceReady;
  String get microphoneStatus => _voiceService.isListening
      ? 'Active in the current app session'
      : 'Not active; Android permission is requested when voice starts';
  double get speechRate => _voiceService.speechRate;
  Duration get followupTimeout => _followupTimeout;
  String get wakeWordStatus =>
      'Unavailable: no offline wake-word engine installed';
  String get backgroundListeningStatus =>
      'Unavailable: voice input is manual and stops outside the active app session';

  /// Whether a cancel has been requested by the user.
  bool get cancelRequested => _cancelRequested;

  /// Force-stop the current agent loop immediately.
  void requestCancel() {
    _cancelRequested = true;
    _aiService.cancelLocalGeneration();
    _voiceService.stopSpeaking();
    notifyListeners();
  }

  Future<bool> selectLocalModel() async => _localModel.selectModel();
  Future<void> loadLocalModel() => _localModel.loadModel();
  Future<void> unloadLocalModel() => _localModel.unloadModel();
  Future<void> setProviderMode(AiProviderMode mode) =>
      _aiService.setProviderMode(mode);
  Future<void> setCloudFallbackEnabled(bool enabled) =>
      _aiService.setCloudFallbackEnabled(enabled);
  Future<void> setAllowGeminiData(bool enabled) =>
      _aiService.setAllowGeminiData(enabled);

  void _onLocalModelChanged() => notifyListeners();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cancelForBackground();
    }
  }

  @override
  void didHaveMemoryPressure() => _cancelForBackground();

  void _cancelForBackground() {
    if (_isActive) requestCancel();
    unawaited(_voiceService.stopListening());
    if (_localModel.state == LocalModelState.ready ||
        _localModel.state == LocalModelState.generating ||
        _localModel.state == LocalModelState.inferenceFailed) {
      unawaited(_localModel.unloadModel().catchError((_) {}));
    }
  }

  Future<void> initialize() async {
    await _aiService.initialize();
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString(_langPrefKey);
    if (savedLang != null && _supportedLangs.contains(savedLang)) {
      _currentLang = savedLang;
    }

    final savedSpeechRate = prefs.getDouble('lucy_speech_rate');
    if (savedSpeechRate != null &&
        savedSpeechRate >= 0.1 &&
        savedSpeechRate <= 1.0) {
      await _voiceService.setSpeechRate(savedSpeechRate);
    }
    final savedTimeoutSeconds = prefs.getInt('lucy_followup_timeout_seconds');
    if (savedTimeoutSeconds != null &&
        savedTimeoutSeconds >= 15 &&
        savedTimeoutSeconds <= 600) {
      _followupTimeout = Duration(seconds: savedTimeoutSeconds);
    }
    final savedHistory = prefs.getStringList(_historyPrefKey) ?? const [];
    for (final item in savedHistory.take(_maxHistoryEntries)) {
      try {
        final entry = jsonDecode(item) as Map<String, dynamic>;
        final text = entry['text'];
        final isUser = entry['isUser'];
        final timestamp = entry['timestamp'];
        if (text is String && isUser is bool && timestamp is String) {
          _conversation.add(
            ConversationEntry(
              text: text,
              isUser: isUser,
              timestamp: DateTime.tryParse(timestamp),
            ),
          );
        }
      } on FormatException catch (error) {
        debugPrint('Ignoring malformed saved conversation entry: $error');
      } catch (error) {
        debugPrint('Could not restore a saved conversation entry: $error');
      }
    }
    notifyListeners();

    // Wire native stop notification action → requestCancel
    _screenCapture.onForceStop = () {
      if (_isActive) {
        requestCancel();
      }
    };

    _voiceService.onResult = (text, isFinal) {
      _currentTranscript = text;
      if (isFinal && text.isNotEmpty) {
        _handleUserInput(text);
      }
      notifyListeners();
    };

    _voiceService.onListeningDone = () {
      if (_state == AgentState.listening &&
          _currentTranscript?.isEmpty == true) {
        if (_isActive) {
          _listenRetryCount++;
          if (_listenRetryCount > _maxListenRetries) {
            print(
              'Listening retry limit reached ($_maxListenRetries). Stopping.',
            );
            _listenRetryCount = 0;
            _statusMessage = 'Listening timed out. Tap to restart.';
            _setState(AgentState.idle);
            _isActive = false;
            notifyListeners();
            return;
          }
          Future.delayed(const Duration(seconds: 2), () {
            if (_isActive && _state == AgentState.listening) {
              _startListening();
            }
          });
        }
      } else {
        _listenRetryCount = 0;
      }
    };

    _voiceService.onError = (error) {
      debugPrint('Voice error: $error');
      if (_isActive && _state == AgentState.listening) {
        if (error == 'error_busy' || error == 'error_client') {
          _statusMessage =
              'Speech recognition is busy or unavailable. Tap the microphone to retry.';
          _isActive = false;
          _setState(AgentState.idle);
          notifyListeners();
          return;
        }
        _listenRetryCount++;
        if (_listenRetryCount > _maxListenRetries) {
          _isActive = false;
          _statusMessage = 'Speech recognition failed: $error';
          _setState(AgentState.idle);
          notifyListeners();
          return;
        }
        Future.delayed(Duration(seconds: _listenRetryCount), () {
          if (_isActive && _state == AgentState.listening) _startListening();
        });
      }
    };
  }

  void configureAi(String apiKey) {
    _aiService.configure(apiKey);
    notifyListeners();
  }

  Future<void> toggleAgent() async {
    if (_isActive) {
      await stopAgent();
    } else {
      await startAgent();
    }
  }

  Future<void> startAgent() async {
    if (_isActive) return;
    _isActive = true;
    _addConversation(
      'Manual voice listening started. Lucy does not listen for a wake phrase in the background.',
      false,
    );
    _statusMessage =
        'Manual listening is active in Lucy. Tap the button to stop.';
    _isAskingForFurtherHelp = false;
    notifyListeners();

    _isVoiceReady = await _voiceService.initialize();
    final prefs = await SharedPreferences.getInstance();
    final savedSpeechRate = prefs.getDouble('lucy_speech_rate');
    if (savedSpeechRate != null &&
        savedSpeechRate >= 0.1 &&
        savedSpeechRate <= 1.0) {
      await _voiceService.setSpeechRate(savedSpeechRate);
    }
    if (!_isVoiceReady) {
      _isActive = false;
      _statusMessage =
          'Speech recognition is unavailable. Check Android microphone permission and speech services.';
      _setState(AgentState.idle);
      return;
    }

    // Check if accessibility service is enabled
    final hasAccessibility = await _screenCapture.isAccessibilityEnabled();
    if (!hasAccessibility) {
      _addConversation(
        '⚠️ Accessibility service is not enabled. UI actions (tap, type, swipe) are unavailable. '
        'Enable Lucy in Android Settings → Accessibility.',
        false,
      );
    }

    _listenRetryCount = 0;
    _startListening();
  }

  Future<void> stopAgent({String? statusMessage}) async {
    _isActive = false;
    // Keep cancellation set until the in-flight loop observes it. Clearing it
    // here could let a pending model response execute one more action.
    _cancelRequested = true;
    _followupTimeoutTimer?.cancel();
    _followupTimeoutTimer = null;
    await _voiceService.stopListening();
    await _voiceService.stopSpeaking();
    _setState(AgentState.idle);
    _statusMessage =
        statusMessage ??
        'Lucy is stopped. Use text commands or start manual listening.';
    _addConversation('Agent stopped.', false);
    notifyListeners();
  }

  Future<void> _startListening() async {
    if (!_isActive) return;
    if (_isAskingForFurtherHelp) {
      _scheduleFollowupTimeout();
    }
    _setState(AgentState.listening);
    _statusMessage =
        "🎤 I'm listening in the foreground. Wake-word detection is unavailable.";
    _currentTranscript = '';
    notifyListeners();

    await _voiceService.startListening(
      localeId: VoiceService.sttLocaleFor(_currentLang),
    );
  }

  /// Main handler: user says something → agent loop begins.
  Future<void> _handleUserInput(String text, {bool voiceInput = true}) async {
    if (!_isActive ||
        (voiceInput && _state != AgentState.listening) ||
        (!voiceInput &&
            _state != AgentState.idle &&
            _state != AgentState.listening)) {
      return;
    }

    _followupTimeoutTimer?.cancel();
    _followupTimeoutTimer = null;
    _setState(AgentState.analyzing);
    if (voiceInput) {
      await _voiceService.stopListening();
    }
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';
    final requestTimer = Stopwatch()..start();
    debugPrint('Lucy[$requestId] stage=command_received');

    _addConversation(text, true);
    _currentTranscript = '';

    final routedCommand = _commandRouter.route(text);
    if (routedCommand != null) {
      await _handleLocalCommand(routedCommand, requestId);
      debugPrint(
        'Lucy[$requestId] stage=total elapsed_ms=${requestTimer.elapsedMilliseconds}',
      );
      if (voiceInput && _isActive) _startListening();
      return;
    }

    if (!_aiService.canInterpretRequests) {
      final message =
          'No selected AI provider can handle this request. Supported exact local commands still work. '
          'Load a GGUF model for offline interpretation, or enable Gemini and cloud data consent in Settings.';
      _addConversation(message, false);
      _isAskingForFurtherHelp = true;
      _statusMessage = _aiService.localModelStatus;
      await _speakAndWait(message);
      debugPrint(
        'Lucy[$requestId] stage=total elapsed_ms=${requestTimer.elapsedMilliseconds}',
      );
      if (voiceInput && _isActive) _startListening();
      return;
    }

    if (_isAskingForFurtherHelp) {
      _isAskingForFurtherHelp = false;
      final trimmed = text.trim();
      final textLowerAscii = trimmed.toLowerCase().replaceAll(
        RegExp(r'[^\w\s]'),
        '',
      );
      final isNegative =
          _negativeEn.hasMatch(textLowerAscii) ||
          _negativeJa.hasMatch(trimmed) ||
          _negativeAr.hasMatch(trimmed);
      if (isNegative) {
        _setState(AgentState.speaking);
        final stopMsg =
            _stoppingMessages[_currentLang] ?? _stoppingMessages['en']!;
        _addConversation(stopMsg, false);
        await _voiceService.speak(stopMsg, lang: _currentLang);

        await Future.delayed(const Duration(milliseconds: 500));
        while (_voiceService.isSpeaking) {
          await Future.delayed(const Duration(milliseconds: 200));
        }

        await stopAgent();
        return;
      }
    }

    await _runAgentLoop(text, requestId: requestId);
    debugPrint(
      'Lucy[$requestId] stage=total elapsed_ms=${requestTimer.elapsedMilliseconds}',
    );

    // Resume listening after the loop completes
    if (voiceInput && _isActive) {
      _startListening();
    }
  }

  Future<void> submitTextCommand(String text) async {
    final command = text.trim();
    if (command.isEmpty ||
        (_state != AgentState.idle && _state != AgentState.listening)) {
      return;
    }
    final resumeVoice = _isActive && _state == AgentState.listening;
    if (resumeVoice) {
      await _voiceService.stopListening();
    } else {
      _isActive = true;
    }
    await _handleUserInput(command, voiceInput: false);
    if (_isActive && resumeVoice) {
      _startListening();
    } else if (_isActive) {
      _isActive = false;
      _setState(AgentState.idle);
      _statusMessage = 'Manual command complete. Voice activation is off.';
      notifyListeners();
    }
  }

  void _scheduleFollowupTimeout() {
    if (_followupTimeoutTimer != null) return;
    _followupTimeoutTimer = Timer(_followupTimeout, () {
      _followupTimeoutTimer = null;
      if (_isActive && _isAskingForFurtherHelp) {
        unawaited(
          stopAgent(
            statusMessage: 'Conversation timed out; microphone stopped.',
          ),
        );
      }
    });
  }

  /// The core agent loop: capture → analyze → act → repeat.
  Future<void> _runAgentLoop(String userMessage, {String? requestId}) async {
    _cancelRequested = false;
    int step = 0;
    String currentMessage = userMessage;
    bool taskCompleted = false;
    final taskTimer = Stopwatch()..start();

    // Show persistent stop notification while Lucy is active
    await _screenCapture.showStopOverlay();

    // Fetch screen size once for the whole loop
    final screenSize = await _screenCapture.getScreenSize();

    while (step < _maxStepsPerCommand &&
        taskTimer.elapsed < _maxTaskDuration &&
        _isActive &&
        !_cancelRequested) {
      step++;

      // 1. Capture screenshot (with retries for reliability after app switches)
      _setState(AgentState.capturing);
      _statusMessage = '📸 Observing screen... (step $step)';
      notifyListeners();

      final screenshotFuture = _aiService.requiresScreenshot
          ? _captureScreenWithRetry()
          : Future<Uint8List?>.value(null);
      final uiSnapshotFuture = _fetchUiSnapshot();
      final screenshotTimer = Stopwatch()..start();
      final uiTimer = Stopwatch()..start();

      final screenshotBytes = await screenshotFuture;
      debugPrint(
        'Lucy[$requestId] stage=screen_observation elapsed_ms=${screenshotTimer.elapsedMilliseconds}',
      );
      if (screenshotBytes != null) {
        _lastScreenshotBytes = screenshotBytes;
      }

      if (_cancelRequested) break;

      // 1b. Fetch UI tree from accessibility service (runs in parallel-ready)
      final uiSnapshot = await uiSnapshotFuture;
      debugPrint(
        'Lucy[$requestId] stage=ui_snapshot elapsed_ms=${uiTimer.elapsedMilliseconds}',
      );
      final uiTree = uiSnapshot?.rawTree;

      if (_cancelRequested) break;

      // 2. Send to AI (with screenshot + UI tree)
      _setState(AgentState.analyzing);
      _statusMessage = '🤖 Thinking... (step $step)';
      notifyListeners();

      final inferenceTimer = Stopwatch()..start();
      final agentResponse = await _aiService.agentChat(
        currentMessage,
        imageBytes: screenshotBytes,
        screenSize: screenSize,
        uiTree: uiTree,
        onToken: (_) {
          if (_streamingStatus.isEmpty) {
            _streamingStatus = 'Local output received';
            _statusMessage = 'Generating local response…';
            notifyListeners();
          }
        },
      );
      _streamingStatus = '';
      debugPrint(
        'Lucy[$requestId] stage=ai_inference elapsed_ms=${inferenceTimer.elapsedMilliseconds}',
      );

      if (_cancelRequested) break;

      // Update the current language from the AI's tag (falls back to previous).
      if (_supportedLangs.contains(agentResponse.lang) &&
          agentResponse.lang != _currentLang) {
        _currentLang = agentResponse.lang;
        // Persist so next launch + STT locale match what the user actually spoke.
        unawaited(
          SharedPreferences.getInstance().then(
            (prefs) => prefs.setString(_langPrefKey, _currentLang),
          ),
        );
      }

      String speakText = agentResponse.speak;
      if (_cancelRequested) break;

      // 3. Execute actions
      var actionsSucceeded = true;
      if (agentResponse.actions.isNotEmpty) {
        _setState(AgentState.executingAction);
        _statusMessage = '⚡ Executing actions... (step $step)';
        notifyListeners();

        var latestSnapshot = uiSnapshot;
        for (final action in agentResponse.actions) {
          if (_cancelRequested) break;
          final actionTimer = Stopwatch()..start();
          final result = await _executeAction(action, latestSnapshot);
          latestSnapshot = result.snapshot;
          actionsSucceeded = actionsSucceeded && result.succeeded;
          debugPrint(
            'Lucy[$requestId] stage=action_${action.type} elapsed_ms=${actionTimer.elapsedMilliseconds}',
          );
        }
      }

      if (_cancelRequested) break;

      if (!actionsSucceeded) {
        speakText =
            'I could not confirm that the requested Android action succeeded.';
        _isAskingForFurtherHelp = true;
      } else if (agentResponse.done) {
        if (speakText.isNotEmpty &&
            !speakText.endsWith(' ') &&
            !speakText.endsWith('\n')) {
          speakText += ' ';
        }
        speakText += _followUps[_currentLang] ?? _followUps['en']!;
        _isAskingForFurtherHelp = true;
      } else {
        _isAskingForFurtherHelp = false;
      }

      String displayText = speakText;
      if (agentResponse.actions.isNotEmpty) {
        final actionSummary = agentResponse.actions
            .map(
              (a) => '⚡ ${a.type}${a.params.isNotEmpty ? ': ${a.params}' : ''}',
            )
            .join('\n');
        displayText = displayText.isEmpty
            ? actionSummary
            : '$displayText\n\n$actionSummary';
      }
      if (displayText.trim().isNotEmpty) {
        _addConversation(displayText, false, screenshotBytes: screenshotBytes);
      }

      // 4. Speak the response (only speak if done or has something to say)
      if (speakText.isNotEmpty) {
        _lastAssistantResponse = speakText;
        _setState(AgentState.speaking);
        _statusMessage = '🔊 Speaking...';
        notifyListeners();

        final ttsText = _trimForTts(speakText);
        final speechTimer = Stopwatch()..start();
        await _voiceService.speak(ttsText, lang: _currentLang);
        debugPrint(
          'Lucy[$requestId] stage=tts_start elapsed_ms=${speechTimer.elapsedMilliseconds}',
        );

        // Wait for TTS to finish
        await Future.delayed(const Duration(milliseconds: 500));
        while (_voiceService.isSpeaking && !_cancelRequested) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      if (_cancelRequested) break;

      // 5. Check if done
      if (agentResponse.done || !actionsSucceeded) {
        taskCompleted = true;
        break;
      }

      // Not done → continue the loop with a follow-up message
      currentMessage =
          'I have executed the actions. Here is the updated screen. Continue with the task.';
      // If screenshot capture might fail next iteration, the AI will still
      // receive the message but without an image. The retry logic in
      // _captureScreenWithRetry handles this by making multiple attempts.
    }

    if (!_cancelRequested &&
        !taskCompleted &&
        (step >= _maxStepsPerCommand ||
            taskTimer.elapsed >= _maxTaskDuration)) {
      _isAskingForFurtherHelp = true;
      _addConversation(
        'Stopped at Lucy’s task limit (${_maxStepsPerCommand} steps or 2 minutes). Review the current screen before continuing.',
        false,
      );
    }

    // Always hide the stop notification when the loop ends
    await _screenCapture.hideStopOverlay();

    // Handle cancellation
    if (_cancelRequested) {
      _cancelRequested = false;
      _addConversation('🛑 Stopped by user.', false);
      return;
    }

    if (step >= _maxStepsPerCommand) {
      _addConversation(
        '⚠️ Reached maximum steps ($_maxStepsPerCommand). Stopping.',
        false,
      );
    }
  }

  Future<void> _handleLocalCommand(
    LocalCommand command,
    String requestId,
  ) async {
    switch (command.type) {
      case LocalCommandType.stop:
      case LocalCommandType.sleep:
        final response = command.type == LocalCommandType.sleep
            ? 'Okay, going to sleep.'
            : 'Okay, stopping voice listening.';
        _addConversation(response, false);
        await _speakAndWait(response);
        await stopAgent();
        return;
      case LocalCommandType.cancel:
        _cancelRequested = true;
        const response = 'Cancelled.';
        _addConversation(response, false);
        await _speakAndWait(response);
        return;
      case LocalCommandType.repeat:
        final previous = _lastAssistantResponse;
        if (previous == null) {
          const response = 'There is nothing to repeat yet.';
          _addConversation(response, false);
          await _speakAndWait(response);
          return;
        }
        await _speakAndWait(previous);
        return;
      case LocalCommandType.action:
        final action = command.action!;
        _setState(AgentState.executingAction);
        _statusMessage = 'Executing local command...';
        notifyListeners();
        final timer = Stopwatch()..start();
        bool success;
        switch (action.type) {
          case 'open_app':
            success = await _screenCapture.openApp(
              action.params['package'] as String,
            );
            break;
          case 'back':
            success = await _screenCapture.pressBack();
            break;
          case 'home':
            success = await _screenCapture.pressHome();
            break;
          default:
            success = false;
            break;
        }
        debugPrint(
          'Lucy[$requestId] stage=fast_action_${action.type} elapsed_ms=${timer.elapsedMilliseconds} success=$success',
        );
        final response = success
            ? switch (action.type) {
                'open_app' => 'Opened ${command.label ?? 'the app'}.',
                'back' => 'Went back.',
                'home' => 'Went to the home screen.',
                _ => 'Command completed.',
              }
            : 'I could not complete that command. Check that the required Android permissions are enabled.';
        _addConversation(response, false);
        _isAskingForFurtherHelp = true;
        await _speakAndWait(response);
        return;
    }
  }

  Future<void> _speakAndWait(String text) async {
    _lastAssistantResponse = text;
    _setState(AgentState.speaking);
    await _voiceService.speak(text, lang: _currentLang);
    while (_voiceService.isSpeaking && _isActive) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Capture the screen with retry logic.
  /// After navigating to another app, the first capture attempt may return null
  /// because the VirtualDisplay hasn't rendered a fresh frame yet. Retrying
  /// with increasing delays ensures we eventually get a valid screenshot.
  Future<Uint8List?> _captureScreenWithRetry({int maxRetries = 3}) async {
    for (int i = 0; i < maxRetries; i++) {
      try {
        final bytes = await _screenCapture.captureScreen();
        if (bytes != null) return bytes;
      } catch (e) {
        print('Screenshot capture attempt ${i + 1} failed: $e');
      }
      if (i < maxRetries - 1) {
        // Increasing delay between retries: 200ms, 400ms
        await Future.delayed(Duration(milliseconds: 200 * (i + 1)));
      }
    }
    print('All $maxRetries screenshot capture attempts failed');
    return null;
  }

  /// Resolve element ID from the UI tree to (cx, cy) coordinates.
  /// Returns null if the element is not found.
  Map<String, double>? _resolveElementCoordinates(
    int elementId,
    List<Map<String, dynamic>> uiElements,
  ) {
    final element = _findElementById(elementId, uiElements);
    if (element != null) {
      final bounds = element['bounds'] as Map<String, dynamic>?;
      if (bounds != null) {
        return {
          'x': (bounds['cx'] as num).toDouble(),
          'y': (bounds['cy'] as num).toDouble(),
        };
      }
    }
    return null;
  }

  Map<String, dynamic>? _findElementById(
    int elementId,
    List<Map<String, dynamic>> uiElements,
  ) {
    for (final element in uiElements) {
      if (element['id'] == elementId) {
        return element;
      }
    }
    return null;
  }

  Future<_UiSnapshot?> _fetchUiSnapshot() async {
    try {
      final uiTree = await _screenCapture.getUITree();
      if (uiTree == null || uiTree.isEmpty) {
        return null;
      }

      final parsed = jsonDecode(uiTree) as Map<String, dynamic>;
      final elementsJson = parsed['elements'] as List<dynamic>? ?? const [];
      final elements = elementsJson
          .whereType<Map>()
          .map((element) => Map<String, dynamic>.from(element))
          .toList(growable: false);

      final hasFocusedEditable = elements.any(
        (element) => element['editable'] == true && element['focused'] == true,
      );

      return _UiSnapshot(
        rawTree: uiTree,
        packageName: parsed['package'] as String?,
        elements: elements,
        hasFocusedEditable: hasFocusedEditable,
      );
    } catch (e) {
      return null;
    }
  }

  bool _didPackageChange(_UiSnapshot? before, _UiSnapshot? after) {
    if (before?.packageName == null || after?.packageName == null) {
      return false;
    }
    return before!.packageName != after!.packageName;
  }

  bool _didTreeSignatureChange(_UiSnapshot? before, _UiSnapshot? after) {
    final beforeSignature = before?.signature;
    final afterSignature = after?.signature;
    if (beforeSignature == null || afterSignature == null) {
      return false;
    }
    return beforeSignature != afterSignature;
  }

  bool _tapTargetsEditableField(
    AgentAction action,
    _UiSnapshot? beforeSnapshot,
  ) {
    final elementId = action.params['element'] as num?;
    if (elementId == null || beforeSnapshot == null) {
      return false;
    }

    final element = _findElementById(
      elementId.toInt(),
      beforeSnapshot.elements,
    );
    if (element == null) {
      return false;
    }

    return element['editable'] == true ||
        element['focusable'] == true ||
        (element['type']?.toString().contains('EditText') ?? false);
  }

  bool _isConsequentialControl(Map<String, dynamic>? element) {
    if (element == null) return false;
    final label = '${element['text'] ?? ''} ${element['desc'] ?? ''}'
        .toLowerCase()
        .trim();
    if (label.isEmpty) return false;
    return RegExp(
      r'\b(send|post|publish|buy|purchase|pay|transfer|delete|remove|submit|place order)\b',
    ).hasMatch(label);
  }

  Duration _readinessTimeoutForAction(AgentAction action) {
    switch (action.type) {
      case 'open_app':
        return _openAppReadyTimeout;
      case 'tap':
      case 'long_press':
      case 'double_tap':
        return _tapReadyTimeout;
      case 'type':
        return _typeReadyTimeout;
      case 'swipe':
      case 'back':
      case 'home':
        return _navigationReadyTimeout;
      case 'wait':
        final ms = (action.params['ms'] as num?)?.toInt() ?? 1000;
        return Duration(milliseconds: ms.clamp(0, 10000));
      default:
        return Duration.zero;
    }
  }

  bool _isActionReady(
    AgentAction action,
    _UiSnapshot? beforeSnapshot,
    _UiSnapshot? currentSnapshot,
  ) {
    if (currentSnapshot == null) {
      return false;
    }

    if (beforeSnapshot == null) {
      return true;
    }

    final packageChanged = _didPackageChange(beforeSnapshot, currentSnapshot);
    final treeChanged = _didTreeSignatureChange(
      beforeSnapshot,
      currentSnapshot,
    );

    switch (action.type) {
      case 'open_app':
        final targetPackage = action.params['package'] as String?;
        if (targetPackage != null &&
            targetPackage.isNotEmpty &&
            currentSnapshot.packageName == targetPackage) {
          return true;
        }
        return packageChanged || treeChanged;
      case 'tap':
      case 'long_press':
      case 'double_tap':
        final expectsFocusedInput = _tapTargetsEditableField(
          action,
          beforeSnapshot,
        );
        if (expectsFocusedInput && currentSnapshot.hasFocusedEditable) {
          return true;
        }
        return packageChanged || treeChanged;
      case 'type':
      case 'swipe':
      case 'back':
      case 'home':
      case 'wait':
        return packageChanged || treeChanged;
      default:
        return true;
    }
  }

  Future<_UiSnapshot?> _waitForActionReadiness(
    AgentAction action,
    _UiSnapshot? beforeSnapshot,
  ) async {
    final timeout = _readinessTimeoutForAction(action);
    if (timeout == Duration.zero) {
      return beforeSnapshot;
    }

    final canObserveUi = await _screenCapture.isAccessibilityEnabled();
    if (!canObserveUi) {
      return beforeSnapshot;
    }

    _UiSnapshot? latestSnapshot = beforeSnapshot;
    final deadline = DateTime.now().add(timeout);

    while (!_cancelRequested) {
      final currentSnapshot = await _fetchUiSnapshot();
      if (currentSnapshot != null) {
        latestSnapshot = currentSnapshot;
      }

      if (_isActionReady(action, beforeSnapshot, currentSnapshot)) {
        return currentSnapshot;
      }

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        break;
      }

      await Future.delayed(
        remaining < _uiPollInterval ? remaining : _uiPollInterval,
      );
    }

    return latestSnapshot;
  }

  /// Execute a single agent action.
  Future<_ActionExecutionResult> _executeAction(
    AgentAction action,
    _UiSnapshot? beforeSnapshot,
  ) async {
    // Actions that require the accessibility service
    const accessibilityActions = {
      'tap',
      'long_press',
      'double_tap',
      'type',
      'clear',
      'swipe',
      'back',
      'home',
    };

    if (accessibilityActions.contains(action.type)) {
      final hasAccessibility = await _screenCapture.isAccessibilityEnabled();
      if (!hasAccessibility) {
        _addConversation(
          '⚠️ Cannot execute "${action.type}" — accessibility service not enabled. '
          'Please enable it in Settings → Accessibility → Lucy.',
          false,
        );
        return _ActionExecutionResult(beforeSnapshot, false);
      }
    }

    var succeeded = false;
    try {
      switch (action.type) {
        case 'open_app':
          final package = action.params['package'] as String? ?? '';
          if (package.isNotEmpty) {
            succeeded = await _screenCapture.openApp(package);
          }
          break;

        case 'tap':
        case 'long_press':
        case 'double_tap':
          final elementId = action.params['element'] as num?;
          final target = elementId == null || beforeSnapshot == null
              ? null
              : _findElementById(elementId.toInt(), beforeSnapshot.elements);
          if (_isConsequentialControl(target)) {
            _addConversation(
              'Stopped before activating "${target?['text'] ?? target?['desc']}". Confirm and complete this consequential action yourself, then tell Lucy to continue.',
              false,
            );
            return _ActionExecutionResult(beforeSnapshot, false);
          }
          final coords = elementId == null
              ? null
              : _resolveElementCoordinates(
                  elementId.toInt(),
                  beforeSnapshot?.elements ?? const [],
                );
          if (coords != null) {
            final x = coords['x']!;
            final y = coords['y']!;
            succeeded = switch (action.type) {
              'long_press' => await _screenCapture.performLongPress(x, y),
              'double_tap' => await _screenCapture.performDoubleTap(x, y),
              _ => await _screenCapture.performTap(x, y),
            };
          }
          break;

        case 'type':
          final text = action.params['text'] as String? ?? '';
          if (text.isNotEmpty) {
            succeeded = await _screenCapture.performType(text);
          }
          break;

        case 'clear':
          succeeded = await _screenCapture.performType('');
          break;

        case 'swipe':
          final startX = (action.params['startX'] as num?)?.toDouble() ?? 0;
          final startY = (action.params['startY'] as num?)?.toDouble() ?? 0;
          final endX = (action.params['endX'] as num?)?.toDouble() ?? 0;
          final endY = (action.params['endY'] as num?)?.toDouble() ?? 0;
          succeeded = await _screenCapture.performSwipe(
            startX,
            startY,
            endX,
            endY,
          );
          break;

        case 'back':
          succeeded = await _screenCapture.pressBack();
          break;

        case 'home':
          succeeded = await _screenCapture.pressHome();
          break;

        case 'wait':
          succeeded = true;
          break;

        default:
          print('Unknown action type: ${action.type}');
      }
    } catch (e) {
      print('Error executing action ${action.type}: $e');
    }

    final snapshot = succeeded
        ? await _waitForActionReadiness(action, beforeSnapshot)
        : beforeSnapshot;
    return _ActionExecutionResult(snapshot, succeeded);
  }

  String _trimForTts(String text) {
    // Remove action/emoji markers for cleaner TTS
    String cleaned = text;
    cleaned = cleaned.replaceAll(RegExp(r'⚡.*?\n'), '');
    cleaned = cleaned.trim();
    if (cleaned.length > 300) {
      return '${cleaned.substring(0, 297)}...';
    }
    return cleaned;
  }

  void _setState(AgentState newState) {
    _state = newState;
    notifyListeners();
  }

  Future<bool> capturePreview() async {
    final screenshotBytes = await _captureScreenWithRetry();
    if (screenshotBytes == null) {
      return false;
    }

    _lastScreenshotBytes = screenshotBytes;
    notifyListeners();
    return true;
  }

  void _addConversation(
    String text,
    bool isUser, {
    Uint8List? screenshotBytes,
  }) {
    _conversation.add(
      ConversationEntry(
        text: text,
        isUser: isUser,
        screenshotBytes: screenshotBytes,
      ),
    );
    if (_conversation.length > _maxHistoryEntries) {
      _conversation.removeRange(0, _conversation.length - _maxHistoryEntries);
    }
    _historyWrite = _historyWrite.then((_) => _persistConversation());
    unawaited(_historyWrite);
    notifyListeners();
  }

  Future<void> _persistConversation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = _conversation
          .map(
            (entry) => jsonEncode({
              'text': entry.text,
              'isUser': entry.isUser,
              'timestamp': entry.timestamp.toIso8601String(),
            }),
          )
          .toList(growable: false);
      await prefs.setStringList(_historyPrefKey, entries);
    } catch (error) {
      debugPrint('Could not save conversation history: $error');
    }
  }

  void clearConversation() {
    _conversation.clear();
    _lastScreenshotBytes = null;
    _isAskingForFurtherHelp = false;
    _aiService.resetChat();
    _historyWrite = _historyWrite.then((_) => _persistConversation());
    unawaited(_historyWrite);
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _followupTimeoutTimer?.cancel();
    _voiceService.dispose();
    _localModel.removeListener(_onLocalModelChanged);
    unawaited(_localModel.disposeEngine());
    super.dispose();
  }
}
