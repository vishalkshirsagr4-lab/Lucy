import 'package:flutter/material.dart';
import '../services/agent_controller.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final AgentController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Capabilities', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            _statusTile(
              context,
              'AI provider',
              controller.aiService.isConfigured
                  ? 'Gemini configured; commands and screen content may be sent online'
                  : 'No AI provider configured; supported exact local commands remain available',
              controller.aiService.isConfigured
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_off_outlined,
            ),
            _statusTile(
              context,
              'Local model',
              controller.aiService.localModelStatus,
              Icons.memory,
            ),
            _statusTile(
              context,
              'Speech recognition',
              controller.speechRecognitionReady
                  ? 'Device speech recognizer available; offline model and network behavior are not verified'
                  : 'Unavailable until the device speech recognizer is initialized',
              Icons.mic_none,
            ),
            _statusTile(
              context,
              'Microphone',
              controller.microphoneStatus,
              Icons.mic,
            ),
            _statusTile(
              context,
              'Wake-word detection',
              controller.wakeWordStatus,
              Icons.hearing_disabled,
            ),
            _statusTile(
              context,
              'Background listening',
              controller.backgroundListeningStatus,
              Icons.notifications_paused_outlined,
            ),
            const Divider(height: 32),
            Text('Voice', style: Theme.of(context).textTheme.titleLarge),
            ListTile(
              title: const Text('Speech language'),
              subtitle: const Text(
                'Affects device speech recognition and replies',
              ),
              trailing: DropdownButton<String>(
                value: controller.currentLang,
                onChanged: (value) {
                  if (value != null) controller.setLanguage(value);
                },
                items: const [
                  DropdownMenuItem(value: 'en', child: Text('English')),
                  DropdownMenuItem(value: 'ja', child: Text('Japanese')),
                  DropdownMenuItem(value: 'ar', child: Text('Arabic')),
                ],
              ),
            ),
            ListTile(
              title: const Text('Speech rate'),
              subtitle: Slider(
                value: controller.speechRate,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                label: controller.speechRate.toStringAsFixed(1),
                onChanged: controller.setSpeechRate,
              ),
            ),
            ListTile(
              title: const Text('Follow-up conversation timeout'),
              subtitle: const Text(
                'Stops the current listening session after this much inactivity',
              ),
              trailing: DropdownButton<int>(
                value: controller.followupTimeout.inSeconds,
                onChanged: (seconds) {
                  if (seconds != null) {
                    controller.setFollowupTimeout(Duration(seconds: seconds));
                  }
                },
                items: const [
                  DropdownMenuItem(value: 30, child: Text('30 sec')),
                  DropdownMenuItem(value: 60, child: Text('1 min')),
                  DropdownMenuItem(value: 120, child: Text('2 min')),
                  DropdownMenuItem(value: 300, child: Text('5 min')),
                  DropdownMenuItem(value: 600, child: Text('10 min')),
                ],
              ),
            ),
            const Divider(height: 32),
            Text(
              'Privacy and battery',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const ListTile(
              leading: Icon(Icons.privacy_tip_outlined),
              title: Text('Microphone and screen privacy'),
              subtitle: Text(
                'Voice listening is started from the app and is not an always-on service. '
                'Gemini requests include your command and, for screen-aware tasks, may include a screenshot and accessibility tree. '
                'Conversation text is kept on this device; raw microphone recordings are not stored by Lucy.',
              ),
            ),
            const ListTile(
              leading: Icon(Icons.battery_saver_outlined),
              title: Text('Battery use'),
              subtitle: Text(
                'Manual speech recognition runs only during an active listening session. '
                'Continuous low-power monitoring is unavailable because this build has no wake-word engine.',
              ),
            ),
            const ListTile(
              leading: Icon(Icons.view_in_ar_outlined),
              title: Text('3D avatar'),
              subtitle: Text(
                'VRM/VRMA assets are present, but this build does not include a compatible renderer. '
                'No static thumbnail is presented as an animated avatar.',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusTile(
    BuildContext context,
    String title,
    String status,
    IconData icon,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: Theme.of(context).colorScheme.secondary),
      title: Text(title),
      subtitle: Text(status),
    );
  }
}
