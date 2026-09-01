import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../services/ai_service.dart';
import '../../../services/secretary_learn_service.dart';
import '../../../services/twilio_service.dart';
import '../widgets/settings_ui.dart';
import '../widgets/tappable_sentences.dart';

/// Разбор конкретного звонка: нажимаете фразу — она подсвечивается, пишете правку сами.
class SecretaryCallReviewPage extends StatefulWidget {
  final String callSid;
  final String fromNumber;
  final String transcript;
  final Map<String, dynamic>? extracted;
  final String initialQuote;

  const SecretaryCallReviewPage({
    super.key,
    required this.callSid,
    required this.fromNumber,
    required this.transcript,
    this.extracted,
    this.initialQuote = '',
  });

  static Future<void> open(
    BuildContext context, {
    CallRecord? call,
    String callSid = '',
    String fromNumber = '',
    String transcript = '',
    Map<String, dynamic>? extracted,
    String quote = '',
  }) async {
    var sid = callSid;
    var phone = fromNumber;
    var text = transcript;
    var data = extracted;
    if (call != null) {
      sid = call.id;
      phone = call.isIncoming ? call.fromNumber : call.toNumber;
      data = call.extractedData;
      if (text.trim().isEmpty) {
        text = await SecretaryLearnService.loadCallTranscript(call);
      }
    }
    if (!context.mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => SecretaryCallReviewPage(
          callSid: sid,
          fromNumber: phone,
          transcript: text.trim().isEmpty
              ? 'Нет расшифровки этого звонка. Опишите сами, что случилось.'
              : text,
          extracted: data,
          initialQuote: quote,
        ),
      ),
    );
  }

  @override
  State<SecretaryCallReviewPage> createState() => _SecretaryCallReviewPageState();
}

class _SecretaryCallReviewPageState extends State<SecretaryCallReviewPage> {
  late String _selected;
  final _happened = TextEditingController();
  final _clung = TextEditingController();
  final _problem = TextEditingController();
  final _next = TextEditingController();
  bool _busy = false;
  bool _aiBusy = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialQuote.trim();
    if (_selected.isNotEmpty) _clung.text = _selected;
    for (final controller in [_happened, _clung, _problem, _next]) {
      controller.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _happened.dispose();
    _clung.dispose();
    _problem.dispose();
    _next.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _selected.trim().isNotEmpty ||
      _happened.text.trim().isNotEmpty ||
      _clung.text.trim().isNotEmpty ||
      _problem.text.trim().isNotEmpty ||
      _next.text.trim().isNotEmpty;

  void _pick(String sentence) {
    setState(() => _selected = sentence);
    _clung.text = sentence;
    if (_problem.text.trim().isEmpty) {
      _problem.text = sentence;
    }
  }

  Future<void> _fillAi() async {
    if (_aiBusy) return;
    setState(() => _aiBusy = true);
    try {
      final report = await AiService.reviewSecretaryCall(
        conversation: widget.transcript,
        extracted: widget.extracted,
        ownerNote: _selected,
      );
      if (!mounted) return;
      _happened.text = report['whatHappenedRu'] ?? _happened.text;
      _clung.text =
          (report['clungToRu'] ?? '').trim().isNotEmpty
              ? report['clungToRu']!
              : _clung.text;
      _problem.text = report['problemRu'] ?? _problem.text;
      _next.text = report['suggestedFixRu'] ?? _next.text;
      if ((report['evidence'] ?? '').trim().isNotEmpty) {
        setState(() => _selected = report['evidence']!);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AiService.friendlyError(error)),
          backgroundColor: Colors.orange.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  Future<bool> _save() async {
    if (_next.text.trim().isEmpty && _problem.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Напишите, в чём ошибка — это уйдёт в папку ошибок, не в скрипт',
              'Write what went wrong — this goes to the error folder, not the script',
            ),
          ),
        ),
      );
      return false;
    }
    setState(() => _busy = true);
    try {
      await SecretaryLearnService.saveManualRule(
        whatHappened: _happened.text,
        clungTo: _clung.text.isNotEmpty ? _clung.text : _selected,
        problem: _problem.text,
        nextTime: _next.text,
        callSid: widget.callSid,
        fromNumber: widget.fromNumber,
      );
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Сохранено в «Ошибки секретаря». Скопируйте карточку и пришлите в чат — правку пишем на сервере.',
              'Saved under Secretary errors. Copy the card and send it in chat — we change her on the server.',
            ),
          ),
          backgroundColor: Colors.green,
        ),
      );
      return true;
    } catch (error) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AiService.friendlyError(error)),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Разбор звонка', 'Call review'),
      dirty: _dirty,
      onSave: () async {
        if (await _save() && mounted) Navigator.pop(context);
        return true;
      },
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          if (widget.fromNumber.isNotEmpty)
            Text(
              widget.fromNumber,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              '1. Нажмите фразу, где секретарь ошибся — она станет жёлтой.\n2. Внизу напишите, как надо было.\n3. Зелёная галочка кладёт это в «Ошибки секретаря». Оттуда копируете и присылаете в чат. Из приложения она правила не берёт.',
              '1. Tap the sentence where the secretary went wrong — it turns yellow.\n2. Write below how it should have been.\n3. The green check saves it under Secretary errors. Copy and send it in chat. The app does not change her rules.',
            ),
            style: const TextStyle(color: Colors.black54, height: 1.4),
          ),
          const SizedBox(height: 14),
          Text(
            context.tr('Текст звонка', 'Call text'),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          TappableSentences(
            text: widget.transcript,
            selected: _selected,
            onSelect: _pick,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _happened,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: context.tr(
                '1. Что случилось на звонке',
                '1. What happened on the call',
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _clung,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: context.tr(
                '2. На чём секретарь запутался',
                '2. What the secretary got stuck on',
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _problem,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: context.tr('3. В чём ошибка', '3. What the mistake was'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _next,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: context.tr(
                '4. Как надо в следующий раз',
                '4. How to act next time',
              ),
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: AppColors.accent.withValues(alpha: 0.12),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _aiBusy || _busy ? null : _fillAi,
            icon: _aiBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(
              _aiBusy
                  ? context.tr('ИИ заполняет…', 'AI is filling…')
                  : context.tr(
                      'Пусть ИИ заполнит отчёт (не обязательно)',
                      'Let AI fill the report (optional)',
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
