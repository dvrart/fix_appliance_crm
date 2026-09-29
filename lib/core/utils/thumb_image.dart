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

/// Картинка для просмотра во весь экран.
///
/// Сырой `NetworkImage` / `FileImage` разжимает снимок в полном разрешении:
/// кадр с этого телефона — 4000×3000, то есть ~48 МБ битмапа на одно фото.
/// В `PageView` живут ещё и соседние страницы, поэтому пролистывание фото
/// заявки уносило приложение в OOM. Замер на телефоне мастера: приложение
/// держит ~313 МБ уже в покое, а свободной памяти в системе было 74 МБ —
/// трёх полноразмерных снимков хватало, чтобы Android его убил.
///
/// Декодируем под экран с запасом на зум. Шильдик с моделью читается, а
/// памяти уходит в 4–5 раз меньше.
ImageProvider fullImage(
  ImageProvider source, {
  required double logicalWidth,
  required double devicePixelRatio,
}) {
  final target = (logicalWidth * devicePixelRatio * _zoomHeadroom)
      .round()
      .clamp(_minFullWidth, _maxFullWidth);
  return ResizeImage(
    source,
    width: target,
    height: target,
    policy: ResizeImagePolicy.fit,
  );
}

/// Во сколько раз берём больше, чем показываем: запас на приближение.
const double _zoomHeadroom = 1.5;
const int _minFullWidth = 1080;
const int _maxFullWidth = 2000;
