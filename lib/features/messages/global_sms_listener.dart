import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/services.dart';
import 'conversation_screen.dart';
import '../../core/l10n/app_locale.dart';

/// Слушает новые входящие SMS и показывает плашку поверх приложения.
/// FCM-токен регистрируется здесь же, чтобы сервер мог прислать push,
/// когда приложение свёрнуто.
class GlobalSmsListener extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  const GlobalSmsListener({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  @override
  State<GlobalSmsListener> createState() => _GlobalSmsListenerState();
}

class _GlobalSmsListenerState extends State<GlobalSmsListener> {
  StreamSubscription<List<SmsMessage>>? _subscription;
  final Set<String> _seenIds = {};
  final DateTime _startedAt = DateTime.now();
  SmsMessage? _banner;

  @override
  void initState() {
    super.initState();
    NotificationService.initialize();
    _subscription = SmsService.streamAll().listen(_onMessages);
  }

  void _onMessages(List<SmsMessage> messages) {
    SmsMessage? banner = _banner;
    if (banner != null) {
      SmsMessage? latest;
      for (final message in messages) {
        if (message.id == banner.id) {
          latest = message;
          break;
        }
      }
      if (latest == null || latest.read) {
        banner = null;
      }
    }

    for (final message in messages) {
      if (message.isOutbound) continue;
      if (_seenIds.contains(message.id)) continue;
      _seenIds.add(message.id);

      final created = message.createdAt;
      if (created != null && created.isBefore(_startedAt.subtract(const Duration(seconds: 10)))) {
        continue;
      }
      if (_isVisitConfirmReply(message)) continue;
      if (!message.read) {
        banner = message;
      }
    }

    if (banner != _banner && mounted) {
      setState(() => _banner = banner);
    }
  }

  bool _isVisitConfirmReply(SmsMessage message) {
    if (message.aiStatus == 'skipped_confirm') return true;
    if (message.mediaUrls.isNotEmpty || message.hasPendingMedia) return false;
    final compact = message.body
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[.!,]'), '');
    const confirmed = {
      '1',
      'yes',
      'да',
      'ok',
      'ок',
      'confirm',
      'подтверждаю',
    };
    const reschedule = {
      '2',
      'no',
      'нет',
      'reschedule',
      'перенос',
    };
    return confirmed.contains(compact) || reschedule.contains(compact);
  }

  void _openConversation(SmsMessage message) {
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    setState(() => _banner = null);
    SmsService.markConversationRead(
      message.isEmail ? '' : message.from,
      email: message.isEmail ? message.counterpartEmail : null,
      clientId: message.clientId,
    );
    ConversationScreen.open(
      navigator.context,
      phoneNumber: message.isEmail ? '' : message.from,
      email: message.isEmail ? message.counterpartEmail : null,
      clientId: message.clientId,
      initialChannel:
          message.isEmail ? ConversationChannel.email : ConversationChannel.sms,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_banner != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Material(
                color: Colors.transparent,
                child: GestureDetector(
                  onTap: () => _openConversation(_banner!),
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFCC520),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF1A1A1A), width: 1.4),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 16,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _banner!.isEmail ? Icons.email : Icons.sms,
                          color: const Color(0xFF1A1A1A),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${(_banner!.isEmail ? 'Новое письмо' : 'Новое SMS').tr} · ${_banner!.isEmail ? _banner!.counterpartEmail : _banner!.from}',
                                style: const TextStyle(
                                  color: Color(0xFF1A1A1A),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                _banner!.body.trim().isEmpty
                                    ? 'Фото или вложение'.tr
                                    : _banner!.body,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF333333),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFF1A1A1A)),
                          onPressed: () => setState(() => _banner = null),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
