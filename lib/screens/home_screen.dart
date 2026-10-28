import 'package:flutter/material.dart';
import '../services/agent_controller.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final AgentController controller;

  const HomeScreen({super.key, required this.controller});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _manualCommandController =
      TextEditingController();

  bool _isAccessibilityEnabled = false;
  bool _isCheckingAccessibility = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    widget.controller.addListener(_onControllerUpdate);
    _checkAccessibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAccessibility();
    }
  }

  Future<void> _checkAccessibility() async {
    if (mounted && !_isCheckingAccessibility) {
      setState(() => _isCheckingAccessibility = true);
    }

    final isEnabled = await widget.controller.screenCapture
        .isAccessibilityEnabled();

    if (mounted) {
      setState(() {
        _isAccessibilityEnabled = isEnabled;
        _isCheckingAccessibility = false;
      });
    }
  }

  void _onControllerUpdate() {
    setState(() {});
    if (widget.controller.isActive &&
        widget.controller.state == AgentState.listening) {
      _pulseController.repeat(reverse: true);
    } else {
      _pulseController.stop();
      _pulseController.reset();
    }

    // Scroll to bottom on new messages
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _scrollController.dispose();
    _apiKeyController.dispose();
    _manualCommandController.dispose();
    widget.controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isCheckingAccessibility) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.controller.isActive
                    ? Colors.greenAccent
                    : Colors.grey,
                boxShadow: widget.controller.isActive
                    ? [
                        BoxShadow(
                          color: Colors.greenAccent.withOpacity(0.5),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            const Text('Lucy'),
          ],
        ),
        backgroundColor: colorScheme.surface,
        elevation: 0,
        actions: [
          _buildLanguageToggle(),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(controller: widget.controller),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.key),
            tooltip: 'API Key',
            onPressed: () => _showApiKeyDialog(context),
          ),
          if (widget.controller.conversation.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear conversation',
              onPressed: () => widget.controller.clearConversation(),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBar(colorScheme),
          _buildCapabilitySummary(colorScheme),
          Expanded(
            child: widget.controller.conversation.isEmpty
                ? _buildEmptyState(colorScheme)
                : _buildConversationList(colorScheme),
          ),
          if (widget.controller.currentTranscript?.isNotEmpty == true)
            _buildTranscriptBar(colorScheme),
          _buildManualCommandInput(),
          _buildBottomBar(colorScheme),
        ],
      ),
    );
  }

  Widget _buildCapabilitySummary(ColorScheme colorScheme) {
    final controller = widget.controller;
    final statuses = <(String, String)>[
      (
        'AI',
        controller.aiService.isConfigured ? 'Gemini online' : 'No provider',
      ),
      ('Local AI', 'Unavailable'),
      (
        'Speech',
        controller.speechRecognitionReady ? 'Device recognizer' : 'Unavailable',
      ),
      ('Microphone', controller.microphoneStatus),
      ('Wake word', 'Unavailable'),
      ('Background', 'Manual only'),
      (
        'Internet',
        controller.aiService.isConfigured
            ? 'Required for Gemini'
            : 'Not measured',
      ),
      ('Accessibility', _isAccessibilityEnabled ? 'Enabled' : 'Not enabled'),
      (
        'Screen capture',
        controller.screenCapture.hasPermission ? 'Granted' : 'Not granted',
      ),
    ];

    return SizedBox(
      height: 130,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: statuses
                    .map(
                      (status) => Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text('${status.$1}: ${status.$2}'),
                        backgroundColor: colorScheme.surfaceContainerHighest,
                      ),
                    )
                    .toList(),
              ),
            ),
            if (!_isAccessibilityEnabled)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 4),
                child: TextButton.icon(
                  onPressed:
                      widget.controller.screenCapture.openAccessibilitySettings,
                  icon: const Icon(Icons.accessibility_new),
                  label: const Text('Enable accessibility for UI automation'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildManualCommandInput() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _manualCommandController,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submitManualCommand(),
              decoration: const InputDecoration(
                hintText: 'Type a command',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Send command',
            onPressed: _submitManualCommand,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }

  Future<void> _submitManualCommand() async {
    final command = _manualCommandController.text.trim();
    if (command.isEmpty) return;
    _manualCommandController.clear();
    await widget.controller.submitTextCommand(command);
  }

  Widget _buildStatusBar(ColorScheme colorScheme) {
    final stateIcon = _getStateIcon();
    final statusColor = _getStatusColor();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        border: Border(bottom: BorderSide(color: statusColor.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          Icon(stateIcon, size: 16, color: statusColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.controller.statusMessage,
              style: TextStyle(
                color: statusColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (!widget.controller.aiService.isConfigured)
            TextButton.icon(
              onPressed: () => _showApiKeyDialog(context),
              icon: Icon(Icons.warning_amber, size: 16, color: Colors.amber),
              label: Text(
                'Configure online AI',
                style: TextStyle(color: Colors.amber, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.visibility,
              size: 72,
              color: colorScheme.primary.withOpacity(0.4),
            ),
            const SizedBox(height: 16),
            Text(
              'Say a command while listening, or type one below.',
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationList(ColorScheme colorScheme) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: widget.controller.conversation.length,
      itemBuilder: (context, index) {
        final entry = widget.controller.conversation[index];
        return _buildConversationBubble(entry, colorScheme);
      },
    );
  }

  Widget _buildConversationBubble(
    ConversationEntry entry,
    ColorScheme colorScheme,
  ) {
    final isUser = entry.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser
              ? colorScheme.primary.withOpacity(0.2)
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: isUser
                ? const Radius.circular(16)
                : const Radius.circular(4),
            bottomRight: isUser
                ? const Radius.circular(4)
                : const Radius.circular(16),
          ),
          border: Border.all(
            color: isUser
                ? colorScheme.primary.withOpacity(0.3)
                : colorScheme.outline.withOpacity(0.1),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isUser ? Icons.person : Icons.smart_toy,
                  size: 14,
                  color: isUser ? colorScheme.primary : colorScheme.secondary,
                ),
                const SizedBox(width: 6),
                Text(
                  isUser ? 'You' : 'Lucy',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isUser ? colorScheme.primary : colorScheme.secondary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(
                    fontSize: 10,
                    color: colorScheme.onSurface.withOpacity(0.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Screenshot preview
            if (entry.screenshotBytes != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  entry.screenshotBytes!,
                  height: 120,
                  fit: BoxFit.cover,
                  errorBuilder: (_, error, stackTrace) => Container(
                    height: 60,
                    color: Colors.grey[800],
                    child: const Center(
                      child: Icon(Icons.broken_image, size: 24),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            SelectableText(
              entry.text,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurface,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTranscriptBar(ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.primary.withOpacity(0.05),
        border: Border(
          top: BorderSide(color: colorScheme.primary.withOpacity(0.2)),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.controller.currentTranscript ?? '',
              style: TextStyle(
                color: colorScheme.primary,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outline.withOpacity(0.1)),
        ),
      ),
      child: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Left area: Screenshot button
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: widget.controller.isActive
                    ? IconButton(
                        onPressed: _manualCapture,
                        icon: const Icon(Icons.camera_alt_outlined),
                        tooltip: 'Capture screen now',
                      )
                    : const SizedBox.shrink(),
              ),
            ),

            // Main mic button
            ScaleTransition(
              scale: widget.controller.state == AgentState.listening
                  ? _pulseAnimation
                  : const AlwaysStoppedAnimation(1.0),
              child: GestureDetector(
                onTap: () => widget.controller.toggleAgent(),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: widget.controller.isActive
                          ? [Colors.redAccent, Colors.red[700]!]
                          : [colorScheme.primary, colorScheme.tertiary],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color:
                            (widget.controller.isActive
                                    ? Colors.redAccent
                                    : colorScheme.primary)
                                .withOpacity(0.4),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(
                    widget.controller.isActive ? Icons.stop : Icons.mic,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
            ),

            // Right area: spacer for layout balance
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
      ),
    );
  }

  IconData _getStateIcon() {
    switch (widget.controller.state) {
      case AgentState.idle:
        return Icons.mic_off;
      case AgentState.listening:
        return Icons.mic;
      case AgentState.capturing:
        return Icons.camera;
      case AgentState.analyzing:
        return Icons.psychology;
      case AgentState.speaking:
        return Icons.volume_up;
      case AgentState.waitingConfirmation:
        return Icons.help_outline;
      case AgentState.executingAction:
        return Icons.flash_on;
    }
  }

  Color _getStatusColor() {
    switch (widget.controller.state) {
      case AgentState.idle:
        return Colors.grey;
      case AgentState.listening:
        return Colors.greenAccent;
      case AgentState.capturing:
        return Colors.amber;
      case AgentState.analyzing:
        return Colors.blue;
      case AgentState.speaking:
        return Colors.purple;
      case AgentState.waitingConfirmation:
        return Colors.orange;
      case AgentState.executingAction:
        return Colors.cyan;
    }
  }

  static const Map<String, String> _langBadges = {
    'en': 'EN',
    'ja': 'JA',
    'ar': 'AR',
  };

  Widget _buildLanguageToggle() {
    final current = widget.controller.currentLang;
    return PopupMenuButton<String>(
      tooltip: 'Input / reply language',
      initialValue: current,
      onSelected: (lang) => widget.controller.setLanguage(lang),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'en', child: Text('English')),
        PopupMenuItem(value: 'ja', child: Text('日本語')),
        PopupMenuItem(value: 'ar', child: Text('العربية')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, size: 18),
            const SizedBox(width: 4),
            Text(
              _langBadges[current] ?? 'EN',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  void _showApiKeyDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Gemini API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter a Gemini API key only if you want to send requests and screen content to Google Gemini. '
              'This is optional; deterministic local commands work without it. '
              'The key is kept in memory for this app session and is not saved. '
              'A local GGUF inference engine is not available in this build.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'AIza...',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.key),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final key = _apiKeyController.text.trim();
              if (key.isNotEmpty) {
                widget.controller.configureAi(key);
                _apiKeyController.clear();
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _manualCapture() async {
    final captured = await widget.controller.capturePreview();
    if (captured && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Screenshot captured')));
    }
  }
}
