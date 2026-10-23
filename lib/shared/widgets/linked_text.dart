import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../features/calls/call_screen.dart';
import '../../features/messages/conversation_screen.dart';

/// Что нашли в тексте: ссылка, почта или номер телефона.
enum TextLinkKind { url, email, phone }

/// Кусок текста, по которому можно нажать.
class TextLink {
  final TextLinkKind kind;
  final String text;
  final int start;
  final int end;

  const TextLink({
    required this.kind,
    required this.text,
    required this.start,
    required this.end,
  });
}

/// Телефон здесь североамериканский (мастерская в Торонто) плюс любой номер
/// с «+» в начале. Нарочно не ловим «любые 8 цифр подряд»: иначе датой
/// «2026-09-20» или номером заявки можно было бы «позвонить».
final RegExp _linkRe = RegExp(
  r'(?<url>(?:https?://|www\.)[^\s<>"]+)'
  r'|(?<email>[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)'
  r'|(?<phone>(?:\+?1[\s.\-]?)?(?:\(\d{3}\)|\d{3})[\s.\-]?\d{3}[\s.\-]?\d{4}'
  r'|\+\d{8,15})',
);

/// Точка или скобка в конце предложения в ссылку не входят.
String _trimTail(String value) {
  var text = value;
  while (text.isNotEmpty) {
    final last = text[text.length - 1];
    if (last == ')' && text.contains('(')) break;
    if (!'.,;:!?»"\'()]}>'.contains(last)) break;
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/// Ссылки, адреса почты и телефоны в тексте — по порядку появления.
List<TextLink> parseTextLinks(String text) {
  final links = <TextLink>[];
  for (final match in _linkRe.allMatches(text)) {
    final url = match.namedGroup('url');
    final email = match.namedGroup('email');
    final phone = match.namedGroup('phone');
    final kind = url != null
        ? TextLinkKind.url
        : email != null
            ? TextLinkKind.email
            : TextLinkKind.phone;
    final raw = url ?? email ?? phone ?? '';
    final value = _trimTail(raw);
    if (value.isEmpty) continue;
    links.add(
      TextLink(
        kind: kind,
        text: value,
        start: match.start,
        end: match.start + value.length,
      ),
    );
  }
  return links;
}

/// Текст сообщения или расшифровки: ссылки, почта и телефоны нажимаются,
/// а двойное касание выделяет слово — дальше его тянут за ползунки и жмут
/// «Копировать».
///
/// Выделение даёт [SelectionArea]. Она перехватывает **долгое** нажатие, и
/// там, где экран сам ловит долгое нажатие (выделение сообщений в переписке),
/// его нужно оборачивать в [QuickLongPress], иначе оно просто не сработает.
///
/// Если виджет уже стоит внутри чужой [SelectionArea], своей он не делает:
/// вложенные области выделения дерутся за одни и те же жесты.
class LinkedText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  /// Выключает и ссылки, и выделение — текст становится обычным. Нужно там,
  /// где нажатия забирает экран: например в переписке, когда идёт выделение
  /// сообщений галочками.
  final bool interactive;

  const LinkedText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.interactive = true,
  });

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  List<TextLink> _links = const [];
  final List<TapGestureRecognizer> _taps = [];

  @override
  void initState() {
    super.initState();
    _rebuildLinks();
  }

  @override
  void didUpdateWidget(covariant LinkedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.interactive != widget.interactive) {
      _rebuildLinks();
    }
  }

  @override
  void dispose() {
    _disposeTaps();
    super.dispose();
  }

  void _disposeTaps() {
    for (final tap in _taps) {
      tap.dispose();
    }
    _taps.clear();
  }

  void _rebuildLinks() {
    _disposeTaps();
    _links = widget.interactive ? parseTextLinks(widget.text) : const [];
    for (final link in _links) {
      _taps.add(TapGestureRecognizer()..onTap = () => _openMenu(link));
    }
  }

  Future<void> _openMenu(TextLink link) async {
    final action = await showLinkActionsSheet(context, link);
    if (action == null || !mounted) return;
    switch (action) {
      case LinkAction.open:
        await _openUrl(link.text);
      case LinkAction.email:
        await ConversationScreen.open(
          context,
          email: link.text,
          initialChannel: ConversationChannel.email,
          rootNavigator: true,
        );
      case LinkAction.call:
        await CallScreen.open(context, phoneNumber: link.text);
      case LinkAction.sms:
        await ConversationScreen.open(
          context,
          phoneNumber: link.text,
          rootNavigator: true,
        );
      case LinkAction.copy:
        if (mounted) await AppFeedback.copy(context, link.text);
    }
  }

  Future<void> _openUrl(String value) async {
    final raw = value.startsWith('www.') ? 'https://$value' : value;
    final uri = Uri.tryParse(raw);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
    }
    if (!opened && mounted) {
      AppFeedback.toast(
        context,
        context.tr('Не удалось открыть ссылку', 'Could not open the link'),
      );
    }
  }

  TextStyle _linkStyle(TextStyle? base) {
    final color = base?.color ?? const Color(0xFF1A1A1A);
    // На синем пузыре текст белый — там подчёркиваем тем же цветом, иначе
    // ссылка «проваливается». На белом фоне ссылка синяя, как привычно.
    final light = color.computeLuminance() > 0.5;
    return TextStyle(
      color: light ? color : const Color(0xFF1565C0),
      decoration: TextDecoration.underline,
      decorationColor: light ? color : const Color(0xFF1565C0),
      fontWeight: FontWeight.w700,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.interactive) {
      return Text(widget.text, style: widget.style, textAlign: widget.textAlign);
    }

    final Widget text;
    if (_links.isEmpty) {
      text = Text(widget.text, style: widget.style, textAlign: widget.textAlign);
    } else {
      final linkStyle = _linkStyle(
        widget.style ?? DefaultTextStyle.of(context).style,
      );
      final spans = <InlineSpan>[];
      var cursor = 0;
      for (var i = 0; i < _links.length; i++) {
        final link = _links[i];
        if (link.start > cursor) {
          spans.add(TextSpan(text: widget.text.substring(cursor, link.start)));
        }
        spans.add(
          TextSpan(
            text: link.text,
            style: linkStyle,
            recognizer: _taps[i],
          ),
        );
        cursor = link.end;
      }
      if (cursor < widget.text.length) {
        spans.add(TextSpan(text: widget.text.substring(cursor)));
      }
      text = Text.rich(
        TextSpan(children: spans),
        style: widget.style,
        textAlign: widget.textAlign,
      );
    }

    // Уже внутри чужой области выделения — своей не заводим.
    if (SelectionContainer.maybeOf(context) != null) return text;
    return SelectionArea(child: text);
  }
}

/// Что можно сделать с нажатой ссылкой.
enum LinkAction { open, email, call, sms, copy }

/// Меню по нажатию на ссылку: сразу в браузер не уводим, чтобы случайный
/// палец не открывал чужие сайты, и даём скопировать.
Future<LinkAction?> showLinkActionsSheet(
  BuildContext context,
  TextLink link,
) {
  AppFeedback.pleasant();
  return showModalBottomSheet<LinkAction>(
    context: context,
    useRootNavigator: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) {
      Widget item(IconData icon, String label, LinkAction action) {
        return ListTile(
          leading: Icon(icon, color: AppColors.primaryOnCard),
          title: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          onTap: () => Navigator.pop(sheetContext, action),
        );
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                link.text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primaryOnCard,
                ),
              ),
            ),
            if (link.kind == TextLinkKind.url)
              item(
                Icons.open_in_new,
                sheetContext.tr('Открыть ссылку', 'Open the link'),
                LinkAction.open,
              ),
            if (link.kind == TextLinkKind.email)
              item(
                Icons.alternate_email,
                sheetContext.tr('Написать письмо', 'Write an email'),
                LinkAction.email,
              ),
            if (link.kind == TextLinkKind.phone) ...[
              item(
                Icons.call,
                sheetContext.tr('Позвонить', 'Call'),
                LinkAction.call,
              ),
              item(
                Icons.sms_outlined,
                sheetContext.tr('Написать SMS', 'Send a text'),
                LinkAction.sms,
              ),
            ],
            item(
              Icons.copy,
              sheetContext.tr('Скопировать', 'Copy'),
              LinkAction.copy,
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// Долгое нажатие с укороченным порогом.
///
/// Обычный [GestureDetector] проигрывает [SelectionArea]: у них одинаковый
/// порог в 500 мс, а в споре жестов первой побеждает та, что внутри. Поэтому
/// выделение сообщений галочками по долгому нажатию просто переставало
/// работать. Здесь порог короче, и экран снова забирает жест себе.
class QuickLongPress extends StatelessWidget {
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;
  final Widget child;

  const QuickLongPress({
    super.key,
    this.onLongPress,
    this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.deferToChild,
      gestures: <Type, GestureRecognizerFactory>{
        if (onLongPress != null)
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
              duration: const Duration(milliseconds: 350),
              debugOwner: this,
            ),
            (instance) => instance.onLongPress = onLongPress,
          ),
        if (onTap != null)
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer(debugOwner: this),
            (instance) => instance.onTap = onTap,
          ),
      },
      child: child,
    );
  }
}
