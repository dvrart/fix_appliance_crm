import 'package:flutter/material.dart';

import '../../core/app_commands.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/ui_scale.dart';
import '../calls/calls_history_screen.dart';
import '../messages/messages_screen.dart';

/// Звонки и переписка (SMS + почта) в одной вкладке.
class CommsHubScreen extends StatefulWidget {
  const CommsHubScreen({super.key});

  @override
  State<CommsHubScreen> createState() => _CommsHubScreenState();
}

class _CommsHubScreenState extends State<CommsHubScreen> with UiSettingsAware {
  int _index = 0;
  late final PageController _page = PageController();

  @override
  void initState() {
    super.initState();
    AppCommands.commsTab.value = _index;
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  void _setIndex(int index) {
    AppCommands.commsTab.value = index;
    if (_index == index) return;
    setState(() => _index = index);
  }

  void _goTo(int index) {
    if (_index == index) return;
    _setIndex(index);
    AppFeedback.pleasant();
    _page.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _iconTab(int index, IconData icon, Color color) {
    final selected = _index == index;
    return Material(
      color: selected ? Colors.white.withValues(alpha: 0.18) : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _goTo(index),
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(
            icon,
            size: 30,
            color: selected ? color : color.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: false,
      child: Column(
        children: [
          ColoredBox(
            color: AppColors.primary,
            child: SizedBox(
              height: 56,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _iconTab(0, Icons.call, const Color(0xFF25D366)),
                  const SizedBox(width: 28),
                  _iconTab(1, Icons.sms, const Color(0xFFD500F9)),
                ],
              ),
            ),
          ),
          Expanded(
            child: ColoredBox(
              color: const Color(0xFFF5F5F5),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 1 || constraints.maxHeight < 1) {
                    return const SizedBox.expand();
                  }
                  return PageView(
                    controller: _page,
                    onPageChanged: (value) {
                      if (_index == value) return;
                      _setIndex(value);
                    },
                    children: const [
                      CallsHistoryScreen(embedded: true),
                      MessagesScreen(embedded: true),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
