import 'package:flutter/widgets.dart';

/// Контроллеры полей окна живут, пока окно в дереве.
///
/// `await showDialog(...)` / `showModalBottomSheet` возвращаются в момент
/// `pop`, а окно ещё уезжает и перестраивается (прячется клавиатура). Поле,
/// уничтоженное сразу после `await`, в этот момент перестраивается с мёртвым
/// контроллером: в debug это красный экран «A TextEditingController was used
/// after being disposed» → `'_dependents.isEmpty'` (Отчёты, 24.10.2026).
///
/// Оберните то, что возвращает `builder` окна, и уберите `dispose()` после
/// `await`: контроллеры уничтожатся, когда окно действительно уйдёт.
/// Прочитать `text` сразу после `await` по-прежнему можно.
class DisposeOnClose extends StatefulWidget {
  final List<ChangeNotifier> disposables;
  final Widget child;

  const DisposeOnClose({
    super.key,
    required this.disposables,
    required this.child,
  });

  @override
  State<DisposeOnClose> createState() => _DisposeOnCloseState();
}

class _DisposeOnCloseState extends State<DisposeOnClose> {
  @override
  void dispose() {
    for (final item in widget.disposables) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
