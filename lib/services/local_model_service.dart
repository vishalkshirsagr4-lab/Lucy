import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalModelService extends ChangeNotifier {
  final LlamaController _llama = LlamaController();

  static const _savedModelKey = 'lucy_local_model_path';

  String? _modelPath;
  bool _loading = false;
  bool _generating = false;
  bool _disposed = false;
  String _status = 'Choose a GGUF model to begin.';
  String _lastResponse = '';

  String get status => _status;
  String get lastResponse => _lastResponse;
  String? get modelPath => _modelPath;
  bool get isLoading => _loading;
  bool get isGenerating => _generating;
  bool get isReady => _modelPath != null && !_loading;

  void _updateStatus(String value) {
    _status = value;
    if (!_disposed) notifyListeners();
  }

  Future<void> restoreSavedModelPath() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_savedModelKey);

    if (saved != null && await File(saved).exists()) {
      _modelPath = saved;
      _updateStatus('Model selected. Tap Load model to initialize it.');
    }
  }

  Future<void> chooseModel() async {
    if (_loading || _generating) return;

    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Choose Lucy GGUF model',
        type: FileType.custom,
        allowedExtensions: ['gguf'],
      );

      if (files.isEmpty) {
        _updateStatus('Model selection cancelled.');
        return;
      }

      final selected = files.first;
      final source = selected.xFile;

      _updateStatus('Copying ${selected.name} into Lucy storage...');

      final directory = await getApplicationSupportDirectory();
      final modelsDirectory = Directory('${directory.path}/models');
      await modelsDirectory.create(recursive: true);

      final destination = File('${modelsDirectory.path}/${selected.name}');
      final temporary = File('${destination.path}.copying');

      if (await temporary.exists()) {
        await temporary.delete();
      }

      final sink = temporary.openWrite();

      try {
        await for (final chunk in source.openRead()) {
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
      } catch (_) {
        await sink.close();
        if (await temporary.exists()) await temporary.delete();
        rethrow;
      }

      if (await destination.exists()) {
        await destination.delete();
      }
      await temporary.rename(destination.path);

      _modelPath = destination.path;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_savedModelKey, _modelPath!);

      _updateStatus(
        'Model copied: ${selected.name}. Tap Load model to initialize it.',
      );
    } catch (error) {
      _updateStatus('Could not copy model: $error');
    }
  }

  Future<bool> get isModelLoaded async {
    if (_loading || _disposed) return false;
    try {
      return await _llama.isModelLoaded();
    } catch (_) {
      return false;
    }
  }

  /// Answers ordinary questions locally without generating Android actions.
  Future<String> chat(String userMessage) async {
    if (_loading || _generating) {
      return 'Lucy is busy. Please wait a moment.';
    }

    if (!await isModelLoaded) {
      _updateStatus('Load your local GGUF model in Settings first.');
      return 'My offline AI is not loaded yet. Please load the model in Settings.';
    }

    _generating = true;
    _lastResponse = '';
    _updateStatus('Thinking offline...');

    try {
      final prompt =
          '''
You are Lucy, a concise offline assistant.
Answer only the user's latest question.
Use 1 to 3 short sentences unless the user asks for detail or steps.
For simple factual questions, give the direct answer only.
Do not repeat greetings, repeat sentences, add unrelated suggestions, or continue after answering.
Do not invent facts or claim to control the phone.
Reply in the same language as the user when possible.
Use plain text, not JSON or markdown headings.
If you do not know, say so briefly.

User: ${userMessage.trim()}
Lucy:
''';

      await for (final token in _llama.generate(
        prompt: prompt,
        maxTokens: 64,
        temperature: 0.2,
      )) {
        _lastResponse += token;
        if (!_disposed) notifyListeners();
      }

      final answer = _lastResponse.trim();
      _updateStatus('Offline response complete.');
      return answer.isEmpty
          ? 'I could not generate an answer. Please try again.'
          : answer;
    } catch (error) {
      _updateStatus('Offline chat failed: $error');
      return 'Offline response failed. Please try again.';
    } finally {
      _generating = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> loadModel() async {
    if (_loading || _generating) return;

    final path = _modelPath;
    if (path == null || !await File(path).exists()) {
      _updateStatus('Choose a valid GGUF model first.');
      return;
    }

    _loading = true;
    _updateStatus('Loading model. This may take a while...');

    try {
      await _llama.loadModel(
        modelPath: path,
        threads: 4,
        contextSize: 2048,
        gpuLayers: 0,
      );

      _updateStatus('Model loaded. Ready for an offline text test.');
    } catch (error) {
      _updateStatus('Model loading failed: $error');
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<String> testPrompt(String prompt) async {
    if (_loading || _generating) {
      return 'Lucy is busy. Please wait.';
    }

    if (!await _llama.isModelLoaded()) {
      _updateStatus('Load the model before testing it.');
      return 'No local model loaded.';
    }

    _generating = true;
    _lastResponse = '';
    _updateStatus('Generating response offline...');

    try {
      await for (final token in _llama.generate(
        prompt: prompt,
        maxTokens: 160,
        temperature: 0.7,
      )) {
        _lastResponse += token;
        if (!_disposed) notifyListeners();
      }

      _updateStatus('Offline response complete.');
      return _lastResponse;
    } catch (error) {
      _updateStatus('Generation failed: $error');
      return 'Local generation failed: $error';
    } finally {
      _generating = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _llama.dispose();
    super.dispose();
  }
}
