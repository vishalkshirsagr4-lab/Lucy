import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screen_capture_service.dart';

enum LocalModelState {
  noModelSelected,
  selected,
  validating,
  loading,
  ready,
  generating,
  unloading,
  unsupportedModel,
  invalidModel,
  insufficientMemory,
  runtimeInitializationFailed,
  inferenceFailed,
}

/// Owns one GGUF model and its llama.cpp inference engine.
///
/// The Android document picker copies models to app-private storage using a
/// streamed native copy. This service only reads the header before loading;
/// it never reads the model weights into a Dart byte buffer.
class LocalModelService extends ChangeNotifier {
  LocalModelService(this._screenCapture);

  static const _pathKey = 'lucy_local_model_path';
  static const _nameKey = 'lucy_local_model_name';
  static const _sizeKey = 'lucy_local_model_size';
  static const _contextKey = 'lucy_local_model_context';

  final ScreenCaptureManager _screenCapture;
  LlamaEngine? _engine;
  String? _modelPath;
  String? _modelName;
  int? _modelBytes;
  LocalModelState _state = LocalModelState.noModelSelected;
  String? _lastError;
  String? _architecture;
  String? _ggufFileType;
  int _contextSize = 2048;
  int _maxTokens = 512;
  double _temperature = 0.2;
  int? _loadedContextSize;
  Duration? _loadDuration;
  Duration? _lastGenerationDuration;
  Duration? _timeToFirstToken;
  bool _operationInProgress = false;
  bool _cancelRequested = false;
  Completer<void>? _generationDone;

  LocalModelState get state => _state;
  String? get modelName => _modelName;
  int? get modelBytes => _modelBytes;
  int get contextSize => _contextSize;
  int get maxTokens => _maxTokens;
  double get temperature => _temperature;
  int? get loadedContextSize => _loadedContextSize;
  Duration? get loadDuration => _loadDuration;
  Duration? get lastGenerationDuration => _lastGenerationDuration;
  Duration? get timeToFirstToken => _timeToFirstToken;
  String? get lastError => _lastError;
  bool get isReady =>
      _engine != null &&
      (_state == LocalModelState.ready ||
          _state == LocalModelState.inferenceFailed);
  bool get isGenerating => _generationDone != null;
  bool get hasSelectedModel => _modelPath != null;

  String get statusLabel => switch (_state) {
    LocalModelState.noModelSelected => 'No model selected',
    LocalModelState.selected => 'Model selected',
    LocalModelState.validating => 'Validating model',
    LocalModelState.loading => 'Loading model',
    LocalModelState.ready => 'Model ready',
    LocalModelState.generating => 'Generating response',
    LocalModelState.unloading => 'Model unloading',
    LocalModelState.unsupportedModel => 'Unsupported model',
    LocalModelState.invalidModel => 'Invalid model',
    LocalModelState.insufficientMemory => 'Insufficient memory',
    LocalModelState.runtimeInitializationFailed =>
      'Runtime initialization failed',
    LocalModelState.inferenceFailed => 'Inference failed',
  };

  String get statusDetails {
    final details = <String>[];
    if (_modelName != null) details.add(_modelName!);
    if (_modelBytes != null) details.add(_formatBytes(_modelBytes!));
    if (_architecture != null) details.add('architecture $_architecture');
    if (_ggufFileType != null) details.add('GGUF file type $_ggufFileType');
    if (_loadedContextSize != null) {
      details.add('context $_loadedContextSize tokens');
    }
    if (_loadDuration != null) {
      details.add('loaded in ${_loadDuration!.inMilliseconds} ms');
    }
    if (_timeToFirstToken != null) {
      details.add('first token ${_timeToFirstToken!.inMilliseconds} ms');
    }
    if (_lastGenerationDuration != null) {
      details.add(
        'last response ${_lastGenerationDuration!.inMilliseconds} ms',
      );
    }
    if (_lastError != null) details.add(_lastError!);
    return details.isEmpty
        ? statusLabel
        : '${statusLabel}: ${details.join(' · ')}';
  }

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _contextSize = _validatedContextSize(
      prefs.getInt(_contextKey) ?? _contextSize,
    );
    final savedMaxTokens = prefs.getInt('lucy_local_model_max_tokens');
    if (savedMaxTokens != null && [128, 256, 512].contains(savedMaxTokens)) {
      _maxTokens = savedMaxTokens;
    }
    final savedTemperature = prefs.getDouble('lucy_local_model_temperature');
    if (savedTemperature != null &&
        savedTemperature >= 0.1 &&
        savedTemperature <= 1.0) {
      _temperature = savedTemperature;
    }
    final path = prefs.getString(_pathKey);
    if (path == null || path.isEmpty) return;

    final file = File(path);
    if (!await file.exists()) {
      await prefs.remove(_pathKey);
      await prefs.remove(_nameKey);
      await prefs.remove(_sizeKey);
      _state = LocalModelState.noModelSelected;
      _lastError = 'The saved model file is missing. Select it again.';
    } else {
      _modelPath = path;
      _modelName = prefs.getString(_nameKey) ?? file.uri.pathSegments.last;
      _modelBytes = prefs.getInt(_sizeKey) ?? await file.length();
      _state = LocalModelState.selected;
    }
    notifyListeners();
  }

  Future<void> setContextSize(int value) async {
    _ensureIdle();
    _contextSize = _validatedContextSize(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_contextKey, _contextSize);
    notifyListeners();
  }

  Future<void> setMaxTokens(int value) async {
    _ensureIdle();
    if (![128, 256, 512].contains(value)) {
      throw ArgumentError.value(value, 'maxTokens', 'Use 128, 256, or 512.');
    }
    _maxTokens = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lucy_local_model_max_tokens', value);
    notifyListeners();
  }

  Future<void> setTemperature(double value) async {
    _ensureIdle();
    if (!value.isFinite || value < 0.1 || value > 1.0) {
      throw ArgumentError.value(
        value,
        'temperature',
        'Use a value from 0.1 to 1.0.',
      );
    }
    _temperature = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('lucy_local_model_temperature', value);
    notifyListeners();
  }

  Future<bool> selectModel() async {
    _ensureIdle();
    if (_engine != null) await unloadModel();
    _operationInProgress = true;
    _setState(LocalModelState.validating, clearError: true);
    try {
      final selected = await _screenCapture.selectLocalModel();
      if (selected == null) {
        _state = _modelPath == null
            ? LocalModelState.noModelSelected
            : LocalModelState.selected;
        notifyListeners();
        return false;
      }

      final path = selected['path'];
      final name = selected['name'];
      if (path is! String || path.isEmpty || name is! String || name.isEmpty) {
        throw const FormatException(
          'The document picker returned incomplete model information.',
        );
      }
      final file = File(path);
      if (!await file.exists()) {
        throw const FileSystemException(
          'The imported model file is inaccessible.',
        );
      }
      final size = await file.length();
      if (size < 4 || !name.toLowerCase().endsWith('.gguf')) {
        _state = LocalModelState.invalidModel;
        throw const FormatException('Choose a complete .gguf model file.');
      }
      final handle = await file.open();
      late final List<int> header;
      try {
        header = await handle.read(4);
      } finally {
        await handle.close();
      }
      if (!isGgufHeader(header)) {
        _state = LocalModelState.invalidModel;
        throw const FormatException(
          'The selected file does not have a GGUF header.',
        );
      }

      _modelPath = path;
      _modelName = name;
      _modelBytes = size;
      _lastError = null;
      _state = LocalModelState.selected;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pathKey, path);
      await prefs.setString(_nameKey, name);
      await prefs.setInt(_sizeKey, size);
      notifyListeners();
      return true;
    } on FormatException catch (error) {
      _lastError = error.message;
      if (_state != LocalModelState.invalidModel) {
        _state = LocalModelState.invalidModel;
      }
      notifyListeners();
      rethrow;
    } catch (error) {
      _lastError = _safeError(error);
      _state = LocalModelState.invalidModel;
      notifyListeners();
      rethrow;
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> loadModel() async {
    _ensureIdle();
    if (_modelPath == null) {
      throw StateError('Select a GGUF model before loading it.');
    }
    if (_engine != null) {
      _lastError = null;
      _state = LocalModelState.ready;
      notifyListeners();
      return;
    }

    _operationInProgress = true;
    _setState(LocalModelState.validating, clearError: true);
    LlamaEngine? loadedEngine;
    try {
      final file = File(_modelPath!);
      if (!await file.exists() || await file.length() < 4) {
        _state = LocalModelState.invalidModel;
        throw const FileSystemException(
          'The selected model file is missing or incomplete.',
        );
      }
      final handle = await file.open();
      late final List<int> header;
      try {
        header = await handle.read(4);
      } finally {
        await handle.close();
      }
      if (!isGgufHeader(header)) {
        _state = LocalModelState.invalidModel;
        throw const FormatException('The selected file is not a GGUF model.');
      }

      _setState(LocalModelState.loading);
      final stopwatch = Stopwatch()..start();
      loadedEngine = await LlamaEngine.load(
        LlamaModel(ModelSource.path(_modelPath!, format: ModelFormat.gguf)),
        params: LlamaCppModelParams(contextSize: _contextSize, gpuLayers: 0),
      );
      _loadDuration = stopwatch.elapsed;
      _loadedContextSize = await loadedEngine.getContextSize();
      final metadata = await loadedEngine.getMetadata();
      _architecture = metadata['general.architecture'];
      _ggufFileType = metadata['general.file_type'];
      _engine = loadedEngine;
      _lastError = null;
      _setState(LocalModelState.ready);
    } catch (error) {
      if (loadedEngine != null) {
        await loadedEngine.dispose();
      }
      final lower = error.toString().toLowerCase();
      _lastError = _safeError(error);
      if (_state == LocalModelState.invalidModel) {
        // Keep the file-validation diagnosis.
      } else if (lower.contains('out of memory') ||
          lower.contains('bad_alloc')) {
        _state = LocalModelState.insufficientMemory;
      } else if (lower.contains('unsupported') ||
          lower.contains('architecture')) {
        _state = LocalModelState.unsupportedModel;
      } else {
        _state = LocalModelState.runtimeInitializationFailed;
      }
      notifyListeners();
      rethrow;
    } finally {
      _operationInProgress = false;
    }
  }

  Future<String> generateAgentResponse(
    String systemPrompt,
    String userPrompt, {
    void Function(String token)? onToken,
    int? maxTokens,
  }) async {
    final engine = _engine;
    if (engine == null || !isReady) {
      throw StateError('No local model is ready.');
    }
    if (_generationDone != null) {
      throw StateError('A local generation is already running.');
    }

    final done = Completer<void>();
    _generationDone = done;
    _cancelRequested = false;
    _state = LocalModelState.generating;
    _lastError = null;
    notifyListeners();
    final stopwatch = Stopwatch()..start();
    _timeToFirstToken = null;
    final output = StringBuffer();
    var firstTokenSeen = false;
    try {
      await for (final chunk in engine.create(
        [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text: systemPrompt,
          ),
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: userPrompt),
        ],
        params: GenerationParams(
          maxTokens: maxTokens ?? _maxTokens,
          temp: _temperature,
          topP: 0.9,
        ),
      )) {
        if (_cancelRequested) break;
        final token = chunk.text;
        if (token.isNotEmpty) {
          if (!firstTokenSeen) {
            firstTokenSeen = true;
            _timeToFirstToken = stopwatch.elapsed;
          }
          output.write(token);
          onToken?.call(token);
        }
      }
      if (_cancelRequested) {
        throw const LocalGenerationCancelledException();
      }
      _lastGenerationDuration = stopwatch.elapsed;
      _state = LocalModelState.ready;
      notifyListeners();
      return output.toString();
    } catch (error) {
      _lastGenerationDuration = stopwatch.elapsed;
      if (_cancelRequested) {
        _state = LocalModelState.ready;
        notifyListeners();
        throw const LocalGenerationCancelledException();
      } else {
        _state = LocalModelState.inferenceFailed;
        _lastError = _safeError(error);
      }
      notifyListeners();
      rethrow;
    } finally {
      _generationDone = null;
      done.complete();
      if (_state == LocalModelState.inferenceFailed && _engine != null) {
        // Keep the initialized model available so the user can retry.
      } else if (_engine != null && _state == LocalModelState.generating) {
        _state = LocalModelState.ready;
        notifyListeners();
      }
    }
  }

  void cancelGeneration() {
    final engine = _engine;
    if (engine == null || _generationDone == null) return;
    _cancelRequested = true;
    engine.cancelGeneration();
  }

  Future<void> unloadModel() async {
    if (_operationInProgress) {
      throw StateError('A model operation is already in progress.');
    }
    _operationInProgress = true;
    try {
      final done = _generationDone;
      if (done != null) {
        cancelGeneration();
        await done.future.timeout(const Duration(seconds: 15));
      }
      if (_engine != null) {
        _setState(LocalModelState.unloading);
        final engine = _engine!;
        _engine = null;
        await engine.dispose();
      }
      _loadedContextSize = null;
      _state = _modelPath == null
          ? LocalModelState.noModelSelected
          : LocalModelState.selected;
      notifyListeners();
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> disposeEngine() async {
    cancelGeneration();
    final engine = _engine;
    _engine = null;
    if (engine != null) await engine.dispose();
    super.dispose();
  }

  void _ensureIdle() {
    if (_operationInProgress || _generationDone != null) {
      throw StateError('Wait for the current model operation to finish.');
    }
  }

  void _setState(LocalModelState state, {bool clearError = false}) {
    _state = state;
    if (clearError) _lastError = null;
    notifyListeners();
  }

  int _validatedContextSize(int value) {
    if (![1024, 2048, 4096].contains(value)) {
      throw ArgumentError.value(
        value,
        'contextSize',
        'Use 1024, 2048, or 4096.',
      );
    }
    return value;
  }

  static bool isGgufHeader(List<int> header) =>
      header.length >= 4 &&
      header[0] == 0x47 &&
      header[1] == 0x47 &&
      header[2] == 0x55 &&
      header[3] == 0x46;

  static String _safeError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 240 ? '${text.substring(0, 237)}...' : text;
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class LocalGenerationCancelledException implements Exception {
  const LocalGenerationCancelledException();

  @override
  String toString() => 'Local generation cancelled.';
}
