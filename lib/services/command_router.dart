import 'ai_service.dart';

enum LocalCommandType { action, stop, cancel, repeat, sleep }

class LocalCommand {
  const LocalCommand(this.type, {this.action, this.label});

  final LocalCommandType type;
  final AgentAction? action;
  final String? label;
}

class LocalCommandRouter {
  const LocalCommandRouter();

  static const Map<String, String> _apps = {
    'youtube': 'com.google.android.youtube',
    'settings': 'com.android.settings',
    'chrome': 'com.android.chrome',
    'gmail': 'com.google.android.gm',
    'maps': 'com.google.android.apps.maps',
    'camera': 'com.android.camera2',
    'calendar': 'com.google.android.calendar',
    'clock': 'com.google.android.deskclock',
    'calculator': 'com.google.android.calculator',
    'play store': 'com.android.vending',
    'photos': 'com.google.android.apps.photos',
    'whatsapp': 'com.whatsapp',
    'messages': 'com.google.android.apps.messaging',
    'phone': 'com.google.android.dialer',
    'files': 'com.google.android.apps.nbu.files',
    'contacts': 'com.google.android.contacts',
    'spotify': 'com.spotify.music',
    'instagram': 'com.instagram.android',
    'telegram': 'org.telegram.messenger',
  };

  LocalCommand? route(String command) {
    final normalized = command
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[.!?]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ');

    if (normalized.isEmpty) return null;

    switch (normalized) {
      case 'go back':
      case 'back':
        return LocalCommand(
          LocalCommandType.action,
          action: AgentAction(type: 'back'),
        );
      case 'go home':
      case 'home':
        return LocalCommand(
          LocalCommandType.action,
          action: AgentAction(type: 'home'),
        );
      case 'stop listening':
        return const LocalCommand(LocalCommandType.stop);
      case 'go to sleep':
      case 'sleep':
        return const LocalCommand(LocalCommandType.sleep);
      case 'cancel':
        return const LocalCommand(LocalCommandType.cancel);
      case 'repeat that':
      case 'repeat':
        return const LocalCommand(LocalCommandType.repeat);
    }

    // Recognize YouTube requests. Search launching is added separately.
    final searchForMatch = RegExp(
      r'^search youtube for\s+(.+)$',
    ).firstMatch(normalized);

    final searchMatch = RegExp(
      r'^search youtube\s+(.+)$',
    ).firstMatch(normalized);

    final playMatch = RegExp(
      r'^(?:play|open youtube and play)\s+(.+)$',
    ).firstMatch(normalized);

    final simpleSearchQuery = searchMatch?.group(1)?.trim();
    final query =
        (searchForMatch?.group(1) ??
                (simpleSearchQuery == 'for' ? null : simpleSearchQuery) ??
                playMatch?.group(1))
            ?.trim();

    if (query != null && query.isNotEmpty) {
      return LocalCommand(
        LocalCommandType.action,
        action: AgentAction(
          type: 'open_url',
          params: {
            'url': Uri.https('www.youtube.com', '/results', {
              'search_query': query,
            }).toString(),
          },
        ),
        label: 'YouTube search: $query',
      );
    }

    final openMatch = RegExp(
      r'^(?:please )?(?:open|launch|start)\s+(.+?)(?:\s+please)?$',
    ).firstMatch(normalized);

    if (openMatch != null) {
      var app = openMatch.group(1)!.trim();
      app = app.replaceFirst(RegExp(r'\s+(?:app|application)$'), '');

      final package = _apps[app];
      if (package != null) {
        return LocalCommand(
          LocalCommandType.action,
          action: AgentAction(type: 'open_app', params: {'package': package}),
          label: app,
        );
      }
    }

    return null;
  }
}
