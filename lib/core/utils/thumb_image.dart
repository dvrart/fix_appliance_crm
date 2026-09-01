import 'package:flutter/widgets.dart';

/// Картинка для миниатюры.
///
/// `NetworkImage` разжимает файл целиком, каким бы маленьким ни был квадратик
/// на экране: снимок 1600×1600 — это ~10 МБ в памяти. Список из тридцати
/// деталей с фото так съедал сотни мегабайт, и Android убивал приложение.
/// `ResizeImage` декодирует сразу под нужный размер.
ImageProvider thumbImage(String url, {int width = 200}) {
  return ResizeImage(
    NetworkImage(url),
    width: width,
    policy: ResizeImagePolicy.fit,
  );
}
