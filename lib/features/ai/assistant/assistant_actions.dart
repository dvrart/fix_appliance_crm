import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/app_commands.dart';
import '../../../core/ui_scale.dart';
import '../../../models/job.dart';
import '../../../services/client_service.dart';
import '../../../services/job_service.dart';
import '../../../services/maps_service.dart';
import '../../calls/call_screen.dart';
import '../../clients/client_details_screen.dart';
import '../../jobs/job_details/job_details_screen.dart';
import '../../messages/conversation_screen.dart';
import '../../settings/pages/appearance_settings_page.dart';

class AssistantUiAction {
  final String type;
  final Map<String, dynamic> payload;
  final bool closeOverlay;

  const AssistantUiAction({
    required this.type,
    this.payload = const {},
    this.closeOverlay = false,
  });
}

/// Очередь действий Фикса: закрыть оверлей и реально открыть экран.
class AssistantActions {
  static final List<AssistantUiAction> _queue = [];

  static void enqueue(AssistantUiAction action) => _queue.add(action);

  static Future<void> flush({
    Future<void> Function()? closeOverlay,
  }) async {
    final items = List<AssistantUiAction>.from(_queue);
    _queue.clear();
    if (items.isEmpty) return;

    final needClose = items.any((item) => item.closeOverlay);
    if (needClose) {
      await closeOverlay?.call();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    for (final item in items) {
      try {
        await _run(item);
      } catch (e, st) {
        debugPrint('AssistantActions $e\n$st');
      }
    }
  }

  static Future<void> _run(AssistantUiAction action) async {
    await Future<void>.delayed(Duration.zero);
    final nav = rootNavigatorKey.currentState;
    final context = rootNavigatorKey.currentContext;
    if (nav == null || context == null || !context.mounted) return;
    final args = action.payload;

    switch (action.type) {
      case 'open_job':
        final jobId = (args['job_id'] as String?) ?? '';
        if (jobId.isEmpty) return;
        final job = await JobService.getById(jobId);
        if (job == null) return;
        nav.push(
          MaterialPageRoute(
            builder: (_) => JobDetailsScreen(
              jobId: job.id,
              clientId: job.clientId,
              jobData: job.toMap(),
            ),
          ),
        );
        return;
      case 'open_client':
        final clientId = (args['client_id'] as String?) ?? '';
        if (clientId.isEmpty) return;
        final client = await ClientService.getById(clientId);
        if (client == null) return;
        nav.push(
          MaterialPageRoute(
            builder: (_) => ClientDetailsScreen(
              clientId: client.id,
              clientData: client.toMap(),
            ),
          ),
        );
        return;
      case 'open_route':
        AppCommands.openTab(0);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        AppCommands.openCalendarMode('route');
        return;
      case 'navigate':
        final address = (args['address'] as String?) ?? '';
        if (address.trim().isEmpty) return;
        await MapsService.openNavigator(address);
        return;
      case 'call_client':
        final phone = (args['phone'] as String?) ?? '';
        if (phone.trim().isEmpty) return;
        unawaited(
          CallScreen.open(
            context,
            phoneNumber: phone,
            contactName: args['name'] as String?,
            jobId: args['job_id'] as String?,
          ),
        );
        return;
      case 'open_conversation':
        await ConversationScreen.open(
          nav.context,
          phoneNumber: (args['phone'] as String?) ?? '',
          email: args['email'] as String?,
          contactName: args['name'] as String?,
          clientId: args['client_id'] as String?,
        );
        return;
      case 'open_settings':
        nav.push(
          MaterialPageRoute(builder: (_) => const AppearanceSettingsPage()),
        );
        return;
      default:
        return;
    }
  }

  static void queueOpenJob(Job job) {
    enqueue(
      AssistantUiAction(
        type: 'open_job',
        payload: {'job_id': job.id},
      ),
    );
  }
}

class AssistantSettingsApply {
  static Future<Map<String, dynamic>> apply(Map<String, dynamic> args) async {
    final ui = AppUiSettings.instance;
    final changed = <String>[];
    final scale = args['scale'];
    if (scale is num) {
      await ui.setScale(scale.toDouble());
      changed.add('scale');
    }
    final theme = (args['theme'] as String?)?.trim().toLowerCase();
    if (theme != null && theme.isNotEmpty) {
      AppColorPreset? preset;
      for (final item in AppUiSettings.themePresets) {
        if (item.id == theme || item.label.toLowerCase().contains(theme)) {
          preset = item;
          break;
        }
      }
      if (preset != null) {
        await ui.applyThemePreset(preset);
        changed.add('theme');
      }
    }
    final font = args['font'] as String?;
    if (font != null) {
      final id = AppUiSettings.fonts.containsKey(font)
          ? font
          : AppUiSettings.fonts.entries
              .firstWhere(
                (e) => e.value.toLowerCase() == font.toLowerCase(),
                orElse: () => const MapEntry('', ''),
              )
              .key;
      await ui.setFontFamily(id);
      changed.add('font');
    }
    return {
      'ok': changed.isNotEmpty,
      'changed': changed,
    };
  }
}
