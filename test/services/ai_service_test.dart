import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/ai_service.dart';

void main() {
  Map<String, dynamic> responseWith(Object action) => {
    'actions': [action],
    'speak': 'Done.',
    'done': true,
    'lang': 'en',
  };

  test('parses a validated action response', () {
    final response = AiService.parseAgentResponse(
      jsonEncode(
        responseWith({'type': 'open_app', 'package': 'com.example.app'}),
      ),
    );

    expect(response.actions.single.type, 'open_app');
    expect(response.actions.single.params['package'], 'com.example.app');
  });

  test('parses supported press gestures and focused-field clearing', () {
    for (final action in [
      {'type': 'long_press', 'element': 2},
      {'type': 'double_tap', 'element': 4},
      {'type': 'clear'},
    ]) {
      final response = AiService.parseAgentResponse(
        jsonEncode(responseWith(action)),
      );
      expect(response.actions.single.type, action['type']);
    }
  });

  test('rejects unknown actions and unexpected action parameters', () {
    for (final action in [
      {'type': 'shell', 'command': 'not allowed'},
      {'type': 'back', 'extra': true},
      {'type': 'tap', 'x': 10, 'y': 10},
      {'type': 'type', 'text': ''},
      {'type': 'wait', 'ms': 10001},
    ]) {
      final response = AiService.parseAgentResponse(
        jsonEncode(responseWith(action)),
      );
      expect(response.actions, isEmpty);
      expect(response.speak, contains('could not validate'));
      expect(response.isValidated, isFalse);
    }
  });

  test('rejects multiple actions and out-of-screen swipe coordinates', () {
    final multipleActions = AiService.parseAgentResponse(
      jsonEncode({
        ...responseWith({'type': 'back'}),
        'actions': [
          {'type': 'back'},
          {'type': 'home'},
        ],
      }),
    );
    expect(multipleActions.actions, isEmpty);

    final swipe = AiService.parseAgentResponse(
      jsonEncode(
        responseWith({
          'type': 'swipe',
          'startX': 100,
          'startY': 100,
          'endX': 1000,
          'endY': 100,
        }),
      ),
      screenSize: {'width': 500, 'height': 800},
    );
    expect(swipe.actions, isEmpty);
  });
}
