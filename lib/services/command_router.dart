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

    const openPrefixes = ['open ', 'launch '];
    for (final prefix in openPrefixes) {
      if (normalized.startsWith(prefix)) {
        final app = normalized.substring(prefix.length).trim();
        final package = _apps[app];
        if (package == null) return null;
        return LocalCommand(
          LocalCommandType.action,
          action: AgentAction(
            type: 'open_app',
            params: {'package': package},
          ),
          label: app,
        );
      }
    }
    return null;
  }
}
