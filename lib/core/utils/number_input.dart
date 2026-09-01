import 'package:flutter/widgets.dart';

/// Первый тап по числу, которое подставила программа.
///
/// Ноль стираем совсем, обычное число выделяем целиком — новая цифра ложится
/// поверх, и не приходится по одной стирать «45.00», чтобы вписать «60».
/// Вызывать только на первый тап: дальше поле должно вести себя как обычно,
/// иначе не получится поставить курсор в середину и поправить одну цифру.
void clearAutoNumber(TextEditingController controller) {
  final text = controller.text.trim();
  if (text.isEmpty) return;
  if ((double.tryParse(text) ?? 0) == 0) {
    controller.clear();
    return;
  }
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: controller.text.length,
  );
}
