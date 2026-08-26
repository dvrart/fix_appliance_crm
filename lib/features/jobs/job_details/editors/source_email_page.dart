import 'package:flutter/material.dart';

import '../../../../core/constants.dart';
import '../../../../core/l10n/app_locale.dart';
import '../../../../services/sms_service.dart';
import '../../../messages/conversation_screen.dart';

Future<void> openSourceEmailSheet(
  BuildContext context, {
  required Map<String, dynamic> jobData,
  required String jobId,
  required String clientId,
  required String clientName,
  required String clientEmail,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) {
      return _SourceEmailSheet(
        jobData: jobData,
        jobId: jobId,
        clientId: clientId,
        clientName: clientName,
        clientEmail: clientEmail,
      );
    },
  );
}

class _SourceEmailSheet extends StatefulWidget {
  final Map<String, dynamic> jobData;
  final String jobId;
  final String clientId;
  final String clientName;
  final String clientEmail;

  const _SourceEmailSheet({
    required this.jobData,
    required this.jobId,
    required this.clientId,
    required this.clientName,
    required this.clientEmail,
  });

  @override
  State<_SourceEmailSheet> createState() => _SourceEmailSheetState();
}

class _SourceEmailSheetState extends State<_SourceEmailSheet> {
  SmsMessage? _message;
  bool _loading = true;

  String get _from =>
      (_message?.counterpartEmail.isNotEmpty == true
          ? _message!.counterpartEmail
          : (widget.jobData['sourceEmailFrom'] ?? widget.clientEmail).toString())
          .trim();

  String get _subject {
    final fromMsg = (_message?.subject ?? '').trim();
    if (fromMsg.isNotEmpty) return fromMsg;
    return (widget.jobData['sourceEmailSubject'] ?? '').toString().trim();
  }

  String get _body {
    final fromMsg = (_message?.displayBody ?? '').trim();
    if (fromMsg.isNotEmpty) return fromMsg;
    return (widget.jobData['sourceEmailPreview'] ?? '').toString().trim();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = (widget.jobData['sourceEmailId'] ?? '').toString();
    try {
      _message = await SmsService.getById(id);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _openLetter() {
    final email = _from.contains('@') ? _from : widget.clientEmail.trim();
    final nav = Navigator.of(context, rootNavigator: true);
    Navigator.pop(context);
    ConversationScreen.open(
      nav.context,
      email: email,
      contactName: widget.clientName,
      clientId: widget.clientId,
      jobId: widget.jobId,
      initialChannel: ConversationChannel.email,
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.82;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                context.tr('Письмо', 'Email'),
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                ),
              ),
              if (_from.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _from,
                  style: const TextStyle(color: Colors.black54),
                ),
              ],
              if (_subject.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _subject,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    height: 1.3,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(color: Color(0xFFFCC520)),
                      )
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(14),
                          child: Text(
                            _body.isEmpty
                                ? context.tr(
                                    'Нет текста письма',
                                    'No email text',
                                  )
                                : _body,
                            style: const TextStyle(height: 1.4, fontSize: 15),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _from.contains('@') || widget.clientEmail.contains('@')
                      ? _openLetter
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14557F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: Text(context.tr('Открыть письмо', 'Open the email')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
