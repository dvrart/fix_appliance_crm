import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../shared/widgets/confirm_action_sheet.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/l10n/app_locale.dart';
import '../../core/utils/number_input.dart';
import '../../core/utils/thumb_image.dart';
import '../../models/warehouse_item.dart';
import '../../services/ai_service.dart';
import '../../services/error_log_service.dart';
import '../../services/network_status_service.dart';
import '../../services/part_image_service.dart';
import '../../services/part_supersession_service.dart';
import '../../services/warehouse_service.dart';
import '../../shared/widgets/appliance_picture.dart';
import '../../shared/widgets/app_bar_save.dart';
import '../../shared/widgets/dirty_leave_scope.dart';
import '../jobs/job_details/widgets/full_screen_gallery.dart';

class WarehouseScreen extends StatefulWidget {
  const WarehouseScreen({super.key});

  @override
  State<WarehouseScreen> createState() => _WarehouseScreenState();
}

class _WarehouseScreenState extends State<WarehouseScreen> {
  final TextEditingController _searchController = TextEditingController();
  late final _itemsStream = WarehouseService.ref.snapshots();
  String _searchQuery = '';
  String _selectedCategory = 'Все';
  String _sortMethod = 'Сначала новые';

  final List<Map<String, String>> _categories = [
    {'name': 'Все', 'type': 'all'},
    {'name': 'Холодильник', 'type': 'fridge'},
    {'name': 'Стиральная машина', 'type': 'washer'},
    {'name': 'Сушилка', 'type': 'dryer'},
    {'name': 'Плита/Духовка', 'type': 'stove'},
    {'name': 'Посудомойка', 'type': 'dishwasher'},
    {'name': 'Универсальное', 'type': 'other'},
  ];

  @override
  void initState() {
    super.initState();
    ErrorLogService.markScreen('Склад');
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Категория по словам в названии. Работает мгновенно и без сети, поэтому
  /// пробуем её первой, а ИИ зовём только когда тут пусто.
  ///
  /// Порядок важен: в «dishwasher» сидит «wash», так что посудомойку проверяем
  /// раньше стиральной машины.
  static const _categoryWords = <String, List<String>>{
    'Посудомойка': ['dishwash', 'dish washer', 'посудомой', 'посудомоеч'],
    'Сушилка': ['dryer', 'drier', 'сушил', 'сушк', 'lint', 'вентиляц сушк'],
    'Стиральная машина': [
      'washer',
      'washing',
      'стиральн',
      'стирал',
      'agitator',
      'активатор',
    ],
    'Холодильник': [
      'fridge',
      'refriger',
      'freezer',
      'ice maker',
      'icemaker',
      'evaporator',
      'defrost',
      'холодильн',
      'морозил',
      'испарител',
      'льдогенерат',
    ],
    'Плита/Духовка': [
      'oven',
      'stove',
      'range',
      'cooktop',
      'burner',
      'igniter',
      'ignitor',
      'bake element',
      'broil',
      'плит',
      'духов',
      'конфорк',
      'варочн',
      'горелк',
    ],
  };

  static String? _guessCategoryFromText(String text) {
    final low = text.toLowerCase();
    if (low.trim().isEmpty) return null;
    for (final entry in _categoryWords.entries) {
      for (final word in entry.value) {
        if (low.contains(word)) return entry.key;
      }
    }
    return null;
  }

  /// Найти ту же деталь по номеру — и живую, и ту, что уже в корзине.
  /// Иначе «объединить» пишет количество в скрытую карточку, и в списке пусто.
  static Future<DocumentSnapshot?> _findSamePart(
    String part, {
    String? excludeId,
  }) async {
    final wanted = WarehouseItem.normalizePart(part);
    if (wanted.isEmpty) return null;

    final exact = part.trim().toUpperCase();
    QuerySnapshot? remote;
    try {
      remote = await WarehouseService.ref
          .where('partNumber', isEqualTo: exact)
          .get()
          .timeout(const Duration(seconds: 6));
    } catch (error) {
      debugPrint('Склад: поиск по парт-номеру не прошёл: $error');
    }

    QuerySnapshot? local;
    try {
      local = await WarehouseService.ref
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(seconds: 3));
    } catch (_) {}

    final seen = <String, DocumentSnapshot>{};
    void add(DocumentSnapshot doc) {
      if (excludeId != null && doc.id == excludeId) return;
      seen[doc.id] = doc;
    }

    if (remote != null) {
      for (final doc in remote.docs) {
        add(doc);
      }
    }
    if (local != null) {
      for (final doc in local.docs) {
        final data = doc.data() as Map<String, dynamic>? ?? {};
        if (WarehouseItem.normalizePart('${data['partNumber']}') == wanted) {
          add(doc);
        }
      }
    }
    if (seen.isEmpty) return null;

    final docs = seen.values.toList()
      ..sort((a, b) {
        final aTrash =
            (a.data() as Map<String, dynamic>?)?['deletedAt'] != null;
        final bTrash =
            (b.data() as Map<String, dynamic>?)?['deletedAt'] != null;
        if (aTrash == bTrash) return 0;
        return aTrash ? 1 : -1;
      });
    return docs.first;
  }

  Future<List<DocumentSnapshot>> _loadLiveStock({String? excludeId}) async {
    QuerySnapshot? snap;
    try {
      snap = await WarehouseService.ref
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
    if (snap == null || snap.docs.isEmpty) {
      try {
        snap = await WarehouseService.ref.get().timeout(
          const Duration(seconds: 6),
        );
      } catch (_) {
        return const [];
      }
    }
    return [
      for (final doc in snap.docs)
        if (excludeId == null || doc.id != excludeId)
          if ((doc.data() as Map<String, dynamic>?)?['deletedAt'] == null) doc,
    ];
  }

  /// Есть ли на полке другая карточка, которая заменяет [part].
  Future<(DocumentSnapshot, String)?> _matchStockSubstitute({
    required String part,
    required List<String> extraNumbers,
    String? excludeId,
  }) async {
    final wanted = WarehouseItem.normalizePart(part);
    if (wanted.isEmpty) return null;
    final extras = <String>{
      wanted,
      for (final n in extraNumbers) WarehouseItem.normalizePart(n),
      for (final n in WarehouseItem.localSupersessions(part))
        WarehouseItem.normalizePart(n),
    }..removeWhere((n) => n.isEmpty);

    final stock = await _loadLiveStock(excludeId: excludeId);
    DocumentSnapshot? best;
    var bestQty = -1;
    var why = '';
    for (final doc in stock) {
      final data = doc.data() as Map<String, dynamic>? ?? {};
      final item = WarehouseItem.fromMap(data, doc.id);
      final itemPart = WarehouseItem.normalizePart(item.partNumber);
      if (itemPart.isEmpty || itemPart == wanted) continue;
      final hit = extras.contains(itemPart) ||
          item.replaces(part) ||
          extraNumbers.any(item.replaces);
      if (!hit) continue;
      if (item.quantity <= bestQty) continue;
      best = doc;
      bestQty = item.quantity;
      why = item.replaces(part)
          ? 'ваша пометка'.tr
          : 'тот же номер под другим артикулом'.tr;
    }
    if (best == null) return null;
    return (best, why);
  }

  void _showItemDialog({DocumentSnapshot? document}) {
    final bool isEditing = document != null;
    final data = isEditing ? document.data() as Map<String, dynamic> : {};

    final nameController = TextEditingController(
      text: isEditing ? data['name'] : '',
    );
    final partNumController = TextEditingController(
      text: isEditing ? (data['partNumber'] ?? '') : '',
    );
    final modelController = TextEditingController(
      text: isEditing ? (data['modelNumber'] ?? '') : '',
    );
    final barcodeController = TextEditingController(
      text: isEditing ? (data['barcode'] ?? '') : '',
    );
    final priceController = TextEditingController(
      text: isEditing ? data['price'].toString() : '',
    );
    final quantityController = TextEditingController(
      text: isEditing ? data['quantity'].toString() : '1',
    );
    final otherController = TextEditingController(
      text: isEditing ? (data['other'] ?? '') : '',
    );
    final interchangeController = TextEditingController(
      text: isEditing
          ? WarehouseItem.parseInterchange(data['interchange']).join(', ')
          : '',
    );

    String itemCategory = isEditing
        ? (data['category'] ?? 'Универсальное')
        : 'Универсальное';
    String? localImageUrl = isEditing ? data['imageUrl'] : null;
    // Остальные свои снимки. Первым фото карточки остаётся [localImageUrl] —
    // его видно на плитке в списке.
    final extraPhotos = WarehouseItem.parsePhotos(
      isEditing ? data['photos'] : null,
    )..remove((localImageUrl ?? '').trim());
    bool isUploadingPhoto = false;
    bool isUsed = isEditing && data['isUsed'] == true;

    // Картинка детали из интернета. Стикер это не заменяет — фото стикера
    // остаётся своим полем, картинка живёт рядом.
    String? webImageUrl = isEditing ? data['webImageUrl'] : null;
    String webImageSource = isEditing ? '${data['webImageSource'] ?? ''}' : '';
    // Картинка, что лежит в записанной карточке. Найденную заново, но не
    // сохранённую, при закрытии окна убираем из Storage.
    final savedWebImage = '${isEditing ? data['webImageUrl'] ?? '' : ''}'.trim();
    // Что нашёл поиск в последний раз: его ссылку на магазин передаём в
    // «поискать другую», чтобы не принести ту же картинку.
    PartImageFind? webFound;
    bool saved = false;
    // Фото по умолчанию — выбирают долгим нажатием, оно стоит в списке склада.
    String coverUrl = '${isEditing ? data['coverUrl'] ?? '' : ''}'.trim();
    bool webSearching = false;
    String webAskedFor = '';
    final webSkip = <String>[];

    Timer? debounce;
    DocumentSnapshot? foundDuplicate;
    DocumentSnapshot? foundSubstitute;
    String substituteWhy = '';
    // Живой каталог сказал «это разные детали» для пары, которую склад
    // посчитал заменой. Карточку замены не показываем и не перелинковываем.
    bool substituteRefuted = false;
    // Какие пары уже опровергнуты в этом диалоге: «part|other».
    final refutedPairs = <String>{};
    bool isCheckingDuplicate = false;
    bool isAiThinking = false;
    bool interchangeTouched = isEditing &&
        interchangeController.text.trim().isNotEmpty;
    bool interchangeAuto = false;
    bool interchangeThinking = false;
    String interchangeAskedFor = '';

    // Число подставлено нами (или взято из карточки), человек его ещё не
    // правил: первый тап очищает поле, дальше оно ведёт себя как обычно.
    bool priceFresh = true;
    bool qtyFresh = true;

    // Категорию подбираем сами, пока FIX не выбрал её руками. У готовой
    // карточки категория уже есть — её не трогаем.
    bool categoryTouched = isEditing;
    bool categoryAuto = false;
    bool categoryThinking = false;
    String categoryAskedFor = '';
    Timer? categoryDebounce;
    bool formDirty = false;

    // Флаг: диалог закрыт — async-колбэки не должны вызывать setDialogState
    // на уже деактивированном StatefulBuilder (→ «inactive element» error).
    bool _gone = false;
    bool openSearchDone = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, _rawSetState) {
            // Безопасная замена: игнорирует вызов, если диалог уже закрыт.
            void setDialogState(VoidCallback fn) {
              if (!_gone && context.mounted) _rawSetState(fn);
            }
            void markDirty() {
              if (formDirty) return;
              setDialogState(() => formDirty = true);
            }
            Future<void> checkDuplicate(String part) async {
              if (!context.mounted) return;
              part = part.trim().toUpperCase();
              if (part.isEmpty) {
                setDialogState(() {
                  foundDuplicate = null;
                  foundSubstitute = null;
                  substituteWhy = '';
                  substituteRefuted = false;
                  refutedPairs.clear();
                });
                return;
              }
              setDialogState(() => isCheckingDuplicate = true);
              final match = await _findSamePart(
                part,
                excludeId: isEditing ? document.id : null,
              );
              if (!context.mounted) return;
              setDialogState(() {
                foundDuplicate = match;
                if (match != null) {
                  foundSubstitute = null;
                  substituteWhy = '';
                  substituteRefuted = false;
                }
                isCheckingDuplicate = false;
                if (match != null && !isEditing) {
                  final old =
                      match.data() as Map<String, dynamic>? ?? {};
                  final oldCategory = '${old['category'] ?? ''}';
                  // Категория уже заведённой карточки важнее догадки
                  // сканера и ИИ.
                  if (_categories.any((c) => c['name'] == oldCategory)) {
                    itemCategory = oldCategory;
                    categoryTouched = true;
                    categoryAuto = true;
                  }
                }
              });
            }

            void writeInterchange(Iterable<String> numbers, String skipPart) {
              final skip = WarehouseItem.normalizePart(skipPart);
              final next = <String>[];
              void add(String value) {
                final clean = value.trim().toUpperCase();
                if (clean.isEmpty) return;
                if (WarehouseItem.normalizePart(clean) == skip) return;
                if (next.contains(clean)) return;
                next.add(clean);
              }

              for (final item
                  in WarehouseItem.parseInterchange(interchangeController.text)) {
                add(item);
              }
              for (final item in numbers) {
                add(item);
              }
              if (next.isEmpty) return;
              interchangeController.text = next.join(', ');
              interchangeAuto = true;
            }

            /// Сверить пару «foundSubstitute заменяет part» с живым
            /// каталогом. «Разные детали» — прячем карточку замены: нельзя
            /// ни приписывать к ней количество, ни сшивать номера в обе
            /// карточки. Промолчал каталог — оставляем как было (подвал и
            /// офлайн важнее интернет-справки).
            Future<void> verifySubstitute(String part) async {
              final doc = foundSubstitute;
              if (doc == null || isEditing) return;
              final data = doc.data() as Map<String, dynamic>? ?? {};
              final other = '${data['partNumber'] ?? ''}'.trim();
              if (other.isEmpty) return;
              final key = '$part|${WarehouseItem.normalizePart(other)}';
              if (refutedPairs.contains(key)) {
                setDialogState(() {
                  foundSubstitute = null;
                  substituteWhy = '';
                  substituteRefuted = true;
                });
                return;
              }
              final verdict = await PartSupersessionService.check(part, other);
              if (!context.mounted) return;
              // За время запроса поле могли переписать или замену пересчитать.
              if (foundSubstitute?.id != doc.id) return;
              if (partNumController.text.trim().toUpperCase() != part) return;
              if (verdict == SupersessionVerdict.different) {
                refutedPairs.add(key);
                setDialogState(() {
                  foundSubstitute = null;
                  substituteWhy = '';
                  substituteRefuted = true;
                });
              } else if (verdict == SupersessionVerdict.replaces &&
                  substituteWhy.isNotEmpty &&
                  !substituteWhy.contains('каталог')) {
                setDialogState(() {
                  substituteWhy = '$substituteWhy · ${'проверено каталогом'.tr}';
                });
              }
            }

            Future<void> suggestReplacements() async {
              if (!context.mounted) return;
              final part = partNumController.text.trim().toUpperCase();
              if (part.length < 4) {
                setDialogState(() {
                  foundSubstitute = null;
                  substituteWhy = '';
                  substituteRefuted = false;
                  refutedPairs.clear();
                });
                return;
              }

              if (!interchangeTouched) {
                writeInterchange(WarehouseItem.localSupersessions(part), part);
                setDialogState(() {});
              }

              if (!isEditing && foundDuplicate == null) {
                final local = await _matchStockSubstitute(
                  part: part,
                  extraNumbers:
                      WarehouseItem.parseInterchange(interchangeController.text),
                  excludeId: isEditing ? document.id : null,
                );
                if (!context.mounted) return;
                setDialogState(() {
                  foundSubstitute = local?.$1;
                  substituteWhy = local?.$2 ?? '';
                  substituteRefuted = false;
                });
                await verifySubstitute(part);
              }

              if (interchangeTouched || part == interchangeAskedFor) return;
              interchangeAskedFor = part;
              setDialogState(() => interchangeThinking = true);

              final guessed = await AiService.guessInterchangeNumbers(
                partNumber: part,
                name: nameController.text.trim(),
                model: modelController.text.trim(),
              );
              if (!context.mounted) return;
              // В колонку «Заменяет номера» попадают только те догадки ИИ,
              // которые подтвердил живой каталог (или родной префикс):
              // голая догадка уже записывала туда чужие детали.
              final approved = await PartSupersessionService.verifiedOnly(
                part,
                guessed,
              );
              if (!context.mounted) return;
              if (!interchangeTouched &&
                  partNumController.text.trim().toUpperCase() == part) {
                writeInterchange(approved, part);
              }

              bool refuted(DocumentSnapshot doc) {
                final data = doc.data() as Map<String, dynamic>? ?? {};
                return refutedPairs.contains(
                  '$part|'
                  '${WarehouseItem.normalizePart('${data['partNumber']}')}',
                );
              }

              DocumentSnapshot? aiMatch;
              var aiWhy = '';
              if (!isEditing && foundDuplicate == null && foundSubstitute == null) {
                final local = await _matchStockSubstitute(
                  part: part,
                  extraNumbers:
                      WarehouseItem.parseInterchange(interchangeController.text),
                );
                if (local != null && !refuted(local.$1)) {
                  aiMatch = local.$1;
                  aiWhy = local.$2;
                } else {
                  final stock = await _loadLiveStock();
                  final pool = [...stock]..sort((a, b) {
                    final aq = int.tryParse(
                          '${(a.data() as Map<String, dynamic>?)?['quantity'] ?? 0}',
                        ) ??
                        0;
                    final bq = int.tryParse(
                          '${(b.data() as Map<String, dynamic>?)?['quantity'] ?? 0}',
                        ) ??
                        0;
                    return bq.compareTo(aq);
                  });
                  final maps = pool
                      .take(70)
                      .map((doc) {
                        final data =
                            doc.data() as Map<String, dynamic>? ?? {};
                        return {
                          'id': doc.id,
                          'partNumber': '${data['partNumber'] ?? ''}',
                          'name': '${data['name'] ?? ''}',
                          'modelNumber': '${data['modelNumber'] ?? ''}',
                        };
                      })
                      .where((row) => row['partNumber']!.trim().isNotEmpty)
                      .toList();
                  final result = await AiService.findInterchangeableParts(
                    wantedPart: part,
                    stock: maps,
                  );
                  if (result.isNotEmpty) {
                    final id = result.keys.first;
                    for (final doc in stock) {
                      if (doc.id != id || refuted(doc)) continue;
                      aiMatch = doc;
                      aiWhy = result[id]!.trim().isEmpty
                          ? 'подсказал ИИ'.tr
                          : result[id]!;
                      break;
                    }
                  }
                }

                // Любой кандидат на замену проверяем у живого каталога —
                // то, что FIX попросил: подставленный номер должен быть
                // реальной заменой, а не догадкой.
                if (aiMatch != null) {
                  final data = aiMatch.data() as Map<String, dynamic>? ?? {};
                  final other = '${data['partNumber'] ?? ''}'.trim();
                  SupersessionVerdict verdict = SupersessionVerdict.unknown;
                  if (other.isNotEmpty) {
                    verdict = await PartSupersessionService.check(part, other);
                  }
                  if (!context.mounted) return;
                  // Пока шёл запрос, поле могли переписать — чужой вердикт
                  // не применяем.
                  if (partNumController.text.trim().toUpperCase() != part) {
                    aiMatch = null;
                    aiWhy = '';
                  } else if (verdict == SupersessionVerdict.different) {
                    refutedPairs.add(
                      '$part|${WarehouseItem.normalizePart(other)}',
                    );
                    aiMatch = null;
                    aiWhy = '';
                    substituteRefuted = true;
                  } else if (verdict == SupersessionVerdict.replaces ||
                      verdict == SupersessionVerdict.same) {
                    if (aiWhy.isNotEmpty && !aiWhy.contains('каталог')) {
                      aiWhy = '$aiWhy · ${'проверено каталогом'.tr}';
                    }
                    if (!interchangeTouched && other.isNotEmpty) {
                      writeInterchange([other], part);
                    }
                  }
                }
              }

              if (!context.mounted) return;
              setDialogState(() {
                interchangeThinking = false;
                if (aiMatch != null && foundDuplicate == null) {
                  foundSubstitute = aiMatch;
                  substituteWhy = aiWhy;
                  substituteRefuted = false;
                }
              });
            }

            void setCategory(String next, {required bool auto}) {
              if (!_categories.any((c) => c['name'] == next)) return;
              if (next == itemCategory) return;
              setDialogState(() {
                itemCategory = next;
                categoryAuto = auto;
              });
            }

            /// Подобрать категорию: сперва по словам, потом — если ничего не
            /// понятно и есть артикул — спросить ИИ.
            void guessCategory() {
              if (categoryTouched) return;
              final local = _guessCategoryFromText(
                '${nameController.text} ${modelController.text} '
                '${otherController.text}',
              );
              if (local != null) {
                setCategory(local, auto: true);
                return;
              }

              final part = partNumController.text.trim().toUpperCase();
              if (part.length < 4) return;
              if (part == categoryAskedFor || categoryThinking) return;

              categoryDebounce?.cancel();
              categoryDebounce = Timer(
                const Duration(milliseconds: 900),
                () async {
                  if (categoryTouched) return;
                  if (partNumController.text.trim().toUpperCase() != part) {
                    return;
                  }
                  categoryAskedFor = part;
                  setDialogState(() => categoryThinking = true);
                  final guess = await AiService.guessPartCategory(
                    partNumber: part,
                    name: nameController.text.trim(),
                    model: modelController.text.trim(),
                    categories: _categories
                        .where((c) => c['name'] != 'Все')
                        .map((c) => c['name']!)
                        .toList(),
                  );
                  if (!context.mounted) return;
                  setDialogState(() => categoryThinking = false);
                  // Дубль мог найтись, пока ИИ думал — его категорию
                  // не переписываем.
                  if (categoryTouched) return;
                  if (guess != null) setCategory(guess, auto: true);
                },
              );
            }

            /// Залить готовый файл в Storage и поставить его фото детали.
            /// [quiet] — не ругаться, если не вышло (фото со сканера
            /// необязательное). [asExtra] — добавить ещё один снимок, не
            /// трогая первый.
            Future<void> uploadPhotoFile(
              File file, {
              bool quiet = false,
              bool asExtra = false,
            }) async {
              setDialogState(() => isUploadingPhoto = true);
              try {
                final fileName =
                    'part_${DateTime.now().millisecondsSinceEpoch}.jpg';
                final ref = FirebaseStorage.instance
                    .ref()
                    .child('warehouse')
                    .child(fileName);
                // Без сети Storage молча повторяет попытки минутами,
                // и кружок крутится вечно. Ждём недолго.
                await ref.putFile(file).timeout(const Duration(seconds: 25));
                final url = await ref
                    .getDownloadURL()
                    .timeout(const Duration(seconds: 15));
                setDialogState(() {
                  if (asExtra && (localImageUrl ?? '').trim().isNotEmpty) {
                    if (!extraPhotos.contains(url)) extraPhotos.add(url);
                  } else {
                    localImageUrl = url;
                  }
                  isUploadingPhoto = false;
                  formDirty = true;
                });
              } catch (e, stack) {
                ErrorLogService.record(e, stack, kind: 'фото детали');
                if (!context.mounted) return;
                setDialogState(() => isUploadingPhoto = false);
                if (quiet) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Фото не загрузилось — нет связи. Деталь сохранится без него.'
                          .tr,
                    ),
                    backgroundColor: Colors.orange.shade800,
                  ),
                );
              }
            }

            /// Попросить ИИ найти в интернете картинку этой детали.
            ///
            /// Сам поиск идёт на сервере (`findPartImage`): он выбирает снимок,
            /// показывает его Gemini и кладёт победителя в наш Storage. Что
            /// нашлось, сразу встаёт в фото карточки (значок глобуса); не
            /// подошло — долгое нажатие, «Убрать» или «Поискать другую».
            Future<void> findWebImage({bool again = false}) async {
              if (webSearching) return;
              final part = partNumController.text.trim().toUpperCase();
              final name = nameController.text.trim();
              if (part.length < 4 && name.length < 4) {
                if (again && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Впишите номер или название детали'.tr),
                      backgroundColor: Colors.orange.shade800,
                    ),
                  );
                }
                return;
              }
              final key = '$part|${name.toLowerCase()}';
              if (!again) {
                // Сами ищем один раз на набор полей и только когда картинки
                // ещё нет — иначе каждая буква тянет запрос.
                if (key == webAskedFor) return;
                if (webImageUrl != null) return;
              }
              webAskedFor = key;
              setDialogState(() => webSearching = true);

              final found = await PartImageService.find(
                partNumber: part,
                name: name,
                model: modelController.text.trim(),
                skip: webSkip,
              );
              if (_gone || !context.mounted) {
                // Окно закрыли, пока искали — файл никому не нужен.
                if (found != null) unawaited(PartImageService.discard(found.imageUrl));
                return;
              }
              setDialogState(() {
                webSearching = false;
                if (found == null) return;
                webFound = found;
                webImageUrl = found.imageUrl;
                webImageSource = found.sourceUrl.isNotEmpty
                    ? found.sourceUrl
                    : found.sourceHost;
                formDirty = true;
              });
              if (found == null && again) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Картинку не нашёл — сфотографируйте деталь сами'.tr,
                    ),
                    backgroundColor: Colors.orange.shade800,
                  ),
                );
              }
            }

            /// Убрать картинку из интернета (и, если надо, поискать другую).
            Future<void> dropWebImage({required bool searchAgain}) async {
              final old = (webImageUrl ?? '').trim();
              if (old.isEmpty) return;
              final found = webFound;
              if (found != null && found.imageUrl == old) {
                webSkip.add(
                  found.originalUrl.isEmpty ? found.imageUrl : found.originalUrl,
                );
              }
              setDialogState(() {
                webImageUrl = null;
                webImageSource = '';
                if (coverUrl == old) coverUrl = '';
                formDirty = true;
              });
              // Сохранённую картинку из Storage не стираем: карточка уже
              // записана, и ссылка может понадобиться. Новую — можно.
              if (old != savedWebImage) {
                unawaited(PartImageService.discard(old));
              }
              if (searchAgain) await findWebImage(again: true);
            }

            void onFieldChanged() {
              markDirty();
              guessCategory();
              if (debounce?.isActive ?? false) debounce!.cancel();
              debounce = Timer(const Duration(milliseconds: 600), () async {
                if (!isEditing) {
                  await checkDuplicate(partNumController.text);
                  await suggestReplacements();
                }
                // Картинку ищем сами — и для новой карточки, и для старой
                // без картинки из интернета.
                await findWebImage();
              });
            }

            /// «Сделать фото»: снимок с камеры уходит в фото карточки.
            Future<void> takePhoto() async {
              final pickedFile = await ImagePicker().pickImage(
                source: ImageSource.camera,
                maxWidth: 1600,
                maxHeight: 1600,
                imageQuality: 70,
              );
              if (pickedFile == null) return;
              await uploadPhotoFile(File(pickedFile.path), asExtra: true);
            }

            /// «Добавить фото»: из галереи, сразу несколько снимков.
            Future<void> pickPhotos() async {
              final files = await ImagePicker().pickMultiImage(
                maxWidth: 1600,
                maxHeight: 1600,
                imageQuality: 70,
              );
              for (final file in files) {
                if (_gone || !context.mounted) return;
                await uploadPhotoFile(File(file.path), asExtra: true);
              }
            }

            /// Что ИИ прочитал со стикера — в поля карточки. Возвращает
            /// false, если ИИ ничего не понял и надо звать офлайн-OCR.
            bool applyAiScan(PartStickerScan scan) {
              if (scan.isEmpty) return false;
              setDialogState(() {
                final name = scan.displayName;
                if (name != null) nameController.text = name;
                if (scan.partNumber != null) {
                  partNumController.text = scan.partNumber!;
                }
                if (scan.modelNumber != null) {
                  modelController.text = scan.modelNumber!;
                }
                if (scan.barcode != null) barcodeController.text = scan.barcode!;
                if (scan.purpose != null &&
                    otherController.text.trim().isEmpty) {
                  otherController.text = scan.purpose!;
                }
                if (!interchangeTouched && scan.interchange.isNotEmpty) {
                  writeInterchange(
                    scan.interchange,
                    partNumController.text,
                  );
                }
                formDirty = true;
              });
              if (scan.category != null && !categoryTouched) {
                setCategory(scan.category!, auto: true);
                // ИИ уже назвал технику — второй раз по артикулу не спрашиваем.
                categoryAskedFor = partNumController.text.trim().toUpperCase();
              } else {
                guessCategory();
              }
              return true;
            }

            /// «Сканировать и добавить»: ИИ читает этикетку и заполняет
            /// карточку, а сам снимок встаёт в фото детали.
            Future<void> scanSticker() async {
                                try {
                                  const source = ImageSource.camera;
                                  final picker = ImagePicker();
                                  // Полный кадр Samsung — это десятки мегабайт
                                  // в памяти. ML Kit на таком снимке валил всё
                                  // приложение. 1600 px хватает для этикетки.
                                  final pickedFile = await picker.pickImage(
                                    source: source,
                                    maxWidth: 1600,
                                    maxHeight: 1600,
                                    imageQuality: 90,
                                  );

                                  if (pickedFile != null) {
                                    setDialogState(() => isAiThinking = true);
                                    final file = File(pickedFile.path);

                                    // Сначала ИИ: он понимает, что за деталь,
                                    // для чего и к какой технике. OCR ниже —
                                    // запасной ход без сети.
                                    final aiScan = await AiService.readPartSticker(
                                      imageBytes: await file.readAsBytes(),
                                      categories: _categories
                                          .where((c) => c['name'] != 'Все')
                                          .map((c) => c['name']!)
                                          .toList(),
                                    );
                                    if (!context.mounted) return;
                                    if (aiScan != null && applyAiScan(aiScan)) {
                                      setDialogState(() => isAiThinking = false);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            aiScan.purpose ??
                                                'ИИ разобрал этикетку ✨'.tr,
                                          ),
                                          backgroundColor: Colors.green,
                                        ),
                                      );
                                      // Снимок годится и как фото детали —
                                      // грузим фоном, не держим кнопку.
                                      unawaited(
                                        uploadPhotoFile(
                                          file,
                                          quiet: true,
                                          asExtra: true,
                                        ),
                                      );
                                      await checkDuplicate(
                                        partNumController.text,
                                      );
                                      await suggestReplacements();
                                      await findWebImage();
                                      return;
                                    }

                                    final inputImage = InputImage.fromFilePath(
                                      pickedFile.path,
                                    );
                                    final textRecognizer = TextRecognizer(
                                      script: TextRecognitionScript.latin,
                                    );
                                    final RecognizedText recognizedText;
                                    try {
                                      recognizedText = await textRecognizer
                                          .processImage(inputImage)
                                          .timeout(const Duration(seconds: 25));
                                    } finally {
                                      // Не закрыть распознаватель = утечка в
                                      // нативной памяти и вылет на 2–3-м скане.
                                      await textRecognizer.close();
                                    }

                                    if (recognizedText.text.isNotEmpty) {
                                      // =======================================================
                                      // ОБНОВЛЕННЫЙ ОФФЛАЙН ПАРСЕР ДЛЯ APPLIANCE REPAIR
                                      // =======================================================
                                      String parsedName = '';
                                      String parsedPart = '';
                                      String parsedModel = '';
                                      String parsedBarcode = '';

                                      List<String> lines = recognizedText.text
                                          .split('\n');

                                      // Обновленная база парт-номеров (Whirlpool, Samsung, LG, GE, Frigidaire, Bosch, Midea и др.)
                                      final partRegex = RegExp(
                                        r'\b(W\d{8}|WPW\d{8}|W10\d{6}|WP\d+|DC\d{2}-\d{5}[A-Z]?|DA\d{2}-\d{5}[A-Z]?|DG\d{2}-\d{5}[A-Z]?|DE\d{2}-\d{5}[A-Z]?|DB\d{2}-\d{5}[A-Z]?|AP\d{6,7}|PS\d{6,7}|EAP\d{6,7}|WR\d{2}X\d{5}|WB\d{2}X\d{5}|WE\d{2}X\d{5}|WD\d{2}X\d{5}|WH\d{2}X\d{5}|530\d{7}|316\d{6}|240\d{6}|241\d{6}|242\d{6}|134\d{6}|137\d{6}|80\d{6}|A00\d{6}|EBR\d{8}|EAX\d{8}|EAY\d{8}|EBT\d{8}|EBU\d{8}|00\d{6}|120\d{5,6})\b',
                                      );

                                      // Регулярка для моделей техники (например WF45M5100AW/A5, RF263BEAESG, WRF535SWHZ00)
                                      final modelRegex = RegExp(
                                        r'\b([A-Z]{1,4}\d{2,5}[A-Z0-9]+(-[A-Z0-9]+)?(/[A-Z0-9]+)?)\b',
                                      );

                                      final barcodeRegex = RegExp(
                                        r'\b(\d{11,14}|X00[A-Z0-9]{7,9})\b',
                                      );
                                      final nameKeywords = RegExp(
                                        r'\b(DOOR|SWITCH|PUMP|MOTOR|VALVE|BOARD|HEATER|ELEMENT|THERMOSTAT|GASKET|SEAL|BELT|FILTER|KNOB|HANDLE|SENSOR|RELAY|ASSEMBLY|ASSY|SVU|ICE MAKER|DRAIN)\b',
                                      );

                                      for (String line in lines) {
                                        String upperLine = line
                                            .toUpperCase()
                                            .trim();

                                        // 1. Ищем Part Number
                                        if (upperLine.contains('PART:') ||
                                            upperLine.contains('P/N:') ||
                                            upperLine.contains('P/N')) {
                                          String possiblePart = upperLine
                                              .split(
                                                RegExp(
                                                  r'(PART:|P/N:|P/N|PART)',
                                                ),
                                              )
                                              .last
                                              .trim()
                                              .split(' ')
                                              .first;
                                          if (possiblePart.isNotEmpty)
                                            parsedPart = possiblePart;
                                        }
                                        if (parsedPart.isEmpty &&
                                            partRegex.hasMatch(upperLine)) {
                                          parsedPart = partRegex
                                              .firstMatch(upperLine)!
                                              .group(0)!;
                                        }

                                        // 2. Ищем Barcode
                                        if (barcodeRegex.hasMatch(upperLine) &&
                                            !partRegex.hasMatch(upperLine)) {
                                          parsedBarcode = barcodeRegex
                                              .firstMatch(upperLine)!
                                              .group(0)!;
                                        }

                                        // 3. Ищем Model Number
                                        if (upperLine.contains('MODEL:') ||
                                            upperLine.contains('MOD:') ||
                                            upperLine.contains('MOD ') ||
                                            upperLine.contains('FOR MODEL')) {
                                          String possibleModel = upperLine
                                              .split(
                                                RegExp(
                                                  r'(MODEL:|MOD:|MOD |\bFOR MODEL\b)',
                                                ),
                                              )
                                              .last
                                              .trim()
                                              .split(' ')
                                              .first;
                                          if (possibleModel.isNotEmpty &&
                                              possibleModel.length > 4)
                                            parsedModel = possibleModel;
                                        }

                                        // Если явного слова MODEL нет, ищем по специфической структуре номера модели
                                        if (parsedModel.isEmpty &&
                                            modelRegex.hasMatch(upperLine)) {
                                          String match = modelRegex
                                              .firstMatch(upperLine)!
                                              .group(0)!;
                                          // Убеждаемся, что это не короткое случайное слово, не штрихкод и не парт-номер
                                          if (match.length > 6 &&
                                              !partRegex.hasMatch(match) &&
                                              !barcodeRegex.hasMatch(match)) {
                                            parsedModel = match;
                                          }
                                        }

                                        // 4. Ищем Название
                                        if (nameKeywords.hasMatch(upperLine) &&
                                            parsedName.isEmpty) {
                                          String cleanName = line
                                              .replaceAll(partRegex, '')
                                              .replaceAll(modelRegex, '')
                                              .replaceAll(
                                                RegExp(
                                                  r'(Part:|P/N:|Model:|Mod:|Barcode:)',
                                                  caseSensitive: false,
                                                ),
                                                '',
                                              )
                                              .trim();
                                          if (cleanName.length > 3)
                                            parsedName = cleanName;
                                        }
                                      }

                                      // Если имя не нашли по ключевым словам, берем первую адекватную строку
                                      if (parsedName.isEmpty) {
                                        for (String l in lines) {
                                          if (l.trim().length > 5 &&
                                              !barcodeRegex.hasMatch(l) &&
                                              !partRegex.hasMatch(l) &&
                                              !modelRegex.hasMatch(
                                                l.toUpperCase(),
                                              ) &&
                                              !l.toUpperCase().contains(
                                                'PART',
                                              )) {
                                            parsedName = l.trim();
                                            break;
                                          }
                                        }
                                      }

                                      // Убираем возможный мусор, оставляя буквы, цифры, дефисы и слэши
                                      parsedPart = parsedPart.replaceAll(
                                        RegExp(r'[^A-Z0-9-]'),
                                        '',
                                      );
                                      parsedModel = parsedModel.replaceAll(
                                        RegExp(r'[^A-Z0-9-/]'),
                                        '',
                                      );

                                      setDialogState(() {
                                        if (parsedName.isNotEmpty)
                                          nameController.text = parsedName;
                                        if (parsedPart.isNotEmpty)
                                          partNumController.text = parsedPart;
                                        if (parsedModel.isNotEmpty)
                                          modelController.text = parsedModel;
                                        if (parsedBarcode.isNotEmpty)
                                          barcodeController.text =
                                              parsedBarcode;
                                        formDirty = true;
                                      });

                                      // Снимаем блокировку до похода в базу:
                                      // иначе «Сохранить» остаётся серым, пока
                                      // ищется дубль, и кнопка кажется мёртвой.
                                      setDialogState(() => isAiThinking = false);
                                      guessCategory();
                                      unawaited(
                                        uploadPhotoFile(
                                          file,
                                          quiet: true,
                                          asExtra: true,
                                        ),
                                      );

                                      if (context.mounted)
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Этикетка успешно отсканирована! ✨'.tr,
                                            ),
                                            backgroundColor: Colors.green,
                                          ),
                                        );

                                      await checkDuplicate(
                                        partNumController.text,
                                      );
                                      await suggestReplacements();
                                      await findWebImage();
                                    } else {
                                      if (context.mounted)
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Текст не найден на фото'.tr,
                                            ),
                                          ),
                                        );
                                    }
                                    setDialogState(() => isAiThinking = false);
                                  }
                                } catch (e, stack) {
                                  ErrorLogService.record(
                                    e,
                                    stack,
                                    kind: 'сканер этикетки',
                                  );
                                  setDialogState(() => isAiThinking = false);
                                  if (context.mounted)
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('${'Ошибка сканера'.tr}: $e'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                }

            }

            /// Все снимки карточки в том порядке, что видит FIX: первым —
            /// фото по умолчанию.
            List<String> currentGallery() => WarehouseItem.galleryOf(
              coverUrl: coverUrl,
              imageUrl: localImageUrl,
              webImageUrl: webImageUrl,
              photos: extraPhotos,
            );

            /// Долгое нажатие на снимок: сделать его фото по умолчанию
            /// (оно в списке склада), поискать другую картинку из интернета
            /// или убрать снимок.
            Future<void> photoMenu(String url) async {
              final isWeb = url == (webImageUrl ?? '').trim();
              final gallery = currentGallery();
              final isCover = gallery.isNotEmpty && gallery.first == url;
              final action = await showModalBottomSheet<String>(
                context: context,
                useRootNavigator: true,
                builder: (sheet) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isCover)
                        ListTile(
                          leading: const Icon(
                            Icons.star_rounded,
                            color: Color(0xFFFCC520),
                          ),
                          title: Text('Сделать фото по умолчанию'.tr),
                          subtitle: Text('Его видно в списке склада'.tr),
                          onTap: () => Navigator.pop(sheet, 'cover'),
                        ),
                      if (isWeb)
                        ListTile(
                          leading: const Icon(
                            Icons.image_search,
                            color: Color(0xFF14557F),
                          ),
                          title: Text('Поискать другую картинку'.tr),
                          onTap: () => Navigator.pop(sheet, 'again'),
                        ),
                      ListTile(
                        leading: const Icon(
                          Icons.delete_outline,
                          color: Colors.redAccent,
                        ),
                        title: Text('Убрать фото'.tr),
                        onTap: () => Navigator.pop(sheet, 'remove'),
                      ),
                    ],
                  ),
                ),
              );
              switch (action) {
                case 'cover':
                  setDialogState(() {
                    coverUrl = url;
                    formDirty = true;
                  });
                case 'again':
                  await dropWebImage(searchAgain: true);
                case 'remove':
                  if (isWeb) {
                    await dropWebImage(searchAgain: false);
                    return;
                  }
                  setDialogState(() {
                    if (url == (localImageUrl ?? '').trim()) {
                      // Убрали первое своё фото — на его место встаёт
                      // следующее, иначе снимки «теряются».
                      localImageUrl =
                          extraPhotos.isEmpty ? null : extraPhotos.removeAt(0);
                    } else {
                      extraPhotos.remove(url);
                    }
                    if (coverUrl == url) coverUrl = '';
                    formDirty = true;
                  });
              }
            }

            /// Одна кнопка «+»: снизу квадрат «Сканировать и добавить»,
            /// справа от него «Добавить фото» и «Сделать фото».
            Future<void> openAddSheet() async {
              final action = await showModalBottomSheet<String>(
                context: context,
                useRootNavigator: true,
                backgroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                ),
                builder: (sheet) => SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: SizedBox(
                      height: 196,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _addChoice(
                              icon: Icons.document_scanner_outlined,
                              label: 'Сканировать и добавить'.tr,
                              hint: 'ИИ заполнит номер и название'.tr,
                              color: Colors.green.shade600,
                              big: true,
                              onTap: () => Navigator.pop(sheet, 'scan'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: _addChoice(
                                    icon: Icons.photo_library_outlined,
                                    label: 'Добавить фото'.tr,
                                    color: const Color(0xFF14557F),
                                    onTap: () => Navigator.pop(sheet, 'gallery'),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: _addChoice(
                                    icon: Icons.photo_camera,
                                    label: 'Сделать фото'.tr,
                                    color: const Color(0xFF14557F),
                                    onTap: () => Navigator.pop(sheet, 'camera'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
              if (!context.mounted) return;
              switch (action) {
                case 'scan':
                  await scanSticker();
                case 'gallery':
                  await pickPhotos();
                case 'camera':
                  await takePhoto();
              }
            }

            Future<bool> saveItem({bool merge = false, bool pop = true}) async {
              final name = nameController.text.trim();
              final partNumber =
                  partNumController.text.trim().toUpperCase();
              final modelNumber =
                  modelController.text.trim().toUpperCase();
              final barcode = barcodeController.text.trim();
              final price = double.tryParse(priceController.text) ?? 0.0;
              final quantity = int.tryParse(quantityController.text) ?? 0;
              final other = otherController.text.trim();

              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Впишите название детали'.tr),
                    backgroundColor: Colors.red,
                  ),
                );
                return false;
              }

              final saveData = <String, dynamic>{
                'name': name,
                'category': itemCategory,
                'partNumber': partNumber,
                'modelNumber': modelNumber,
                'barcode': barcode,
                'price': price,
                'other': other,
                'isUsed': isUsed,
                'interchange': WarehouseItem.parseInterchange(
                  interchangeController.text,
                ),
                'imageUrl': localImageUrl,
                'photos': List<String>.from(extraPhotos),
                'webImageUrl': webImageUrl,
                'webImageSource': webImageSource,
                'coverUrl': coverUrl,
                'updatedAt': FieldValue.serverTimestamp(),
              };

              try {
                if (isEditing) {
                  saveData['quantity'] = quantity;
                  await settleWrite(document.reference.update(saveData));
                } else if (merge &&
                    (foundDuplicate != null || foundSubstitute != null)) {
                  final existing = foundDuplicate ?? foundSubstitute!;
                  final exact = foundDuplicate != null;
                  final old =
                      existing.data() as Map<String, dynamic>? ?? {};
                  final oldImage = '${old['imageUrl'] ?? ''}'.trim();
                  final newImage = (localImageUrl ?? '').trim();
                  final oldWeb = '${old['webImageUrl'] ?? ''}'.trim();
                  final newWeb = (webImageUrl ?? '').trim();
                  // Новая карточка часто без фото — не затираем старое.
                  if (newImage.isEmpty) saveData.remove('imageUrl');
                  if (coverUrl.isEmpty) saveData.remove('coverUrl');
                  if (newWeb.isEmpty) {
                    saveData.remove('webImageUrl');
                    saveData.remove('webImageSource');
                  }
                  final mergedInter = WarehouseItem.parseInterchange([
                    ...WarehouseItem.parseInterchange(old['interchange']),
                    ...WarehouseItem.parseInterchange(
                      interchangeController.text,
                    ),
                    if (!exact) partNumber,
                  ]);
                  // Снимки обеих карточек складываются. Старое первое фото
                  // не теряем: на плитку встаёт новое, старое уходит в
                  // галерею.
                  final mergedPhotos = WarehouseItem.parsePhotos([
                    ...WarehouseItem.parsePhotos(old['photos']),
                    ...extraPhotos,
                    if (newImage.isNotEmpty &&
                        oldImage.isNotEmpty &&
                        oldImage != newImage)
                      oldImage,
                  ])..remove(newImage.isEmpty ? oldImage : newImage);
                  if (exact) {
                    await settleWrite(
                      existing.reference.set({
                        ...saveData,
                        'interchange': mergedInter,
                        'photos': mergedPhotos,
                        // Инкремент, а не oldQty + quantity: снимок дубля
                        // мог устареть, пока владелец заполнял карточку.
                        'quantity': FieldValue.increment(quantity),
                        if (newImage.isEmpty && oldImage.isNotEmpty)
                          'imageUrl': oldImage,
                        if (newWeb.isEmpty && oldWeb.isNotEmpty)
                          'webImageUrl': oldWeb,
                        'createdAt':
                            old['createdAt'] ?? FieldValue.serverTimestamp(),
                        'deletedAt': FieldValue.delete(),
                      }, SetOptions(merge: true)),
                    );
                  } else {
                    // Замена: номер на карточке не меняем, только
                    // количество, фото если новое, и список замен.
                    await settleWrite(
                      existing.reference.set({
                        'quantity': FieldValue.increment(quantity),
                        'interchange': mergedInter,
                        'photos': mergedPhotos,
                        if (newImage.isNotEmpty) 'imageUrl': newImage,
                        if (coverUrl.isNotEmpty) 'coverUrl': coverUrl,
                        if (newWeb.isNotEmpty) ...{
                          'webImageUrl': newWeb,
                          'webImageSource': webImageSource,
                        },
                        'createdAt':
                            old['createdAt'] ?? FieldValue.serverTimestamp(),
                        'deletedAt': FieldValue.delete(),
                        'updatedAt': FieldValue.serverTimestamp(),
                      }, SetOptions(merge: true)),
                    );
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          old['deletedAt'] != null
                              ? 'Вернул из корзины и объединил'.tr
                              : exact
                                  ? 'Карточки объединены'.tr
                                  : 'Добавил к замене на складе'.tr,
                        ),
                        backgroundColor: const Color(0xFF14557F),
                      ),
                    );
                  }
                } else {
                  if (foundSubstitute != null) {
                    final old = foundSubstitute!.data()
                            as Map<String, dynamic>? ??
                        {};
                    final subPart = '${old['partNumber'] ?? ''}'.trim();
                    saveData['interchange'] = WarehouseItem.parseInterchange([
                      ...WarehouseItem.parseInterchange(
                        interchangeController.text,
                      ),
                      if (subPart.isNotEmpty) subPart,
                    ]);
                  }
                  saveData['quantity'] = quantity;
                  saveData['createdAt'] = FieldValue.serverTimestamp();
                  await settleWrite(
                    WarehouseService.ref.doc().set(saveData),
                  );
                  if (foundSubstitute != null) {
                    final existing = foundSubstitute!;
                    final old =
                        existing.data() as Map<String, dynamic>? ?? {};
                    final next = WarehouseItem.parseInterchange([
                      ...WarehouseItem.parseInterchange(old['interchange']),
                      partNumber,
                    ]);
                    await settleWrite(
                      existing.reference.set(
                        {'interchange': next},
                        SetOptions(merge: true),
                      ),
                    );
                  }
                }
              } catch (error, stack) {
                ErrorLogService.record(error, stack, kind: 'склад сохранить');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Не удалось сохранить деталь'.tr),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
                return false;
              }

              saved = true;
              if (!context.mounted) return false;
              // После записи открываем «Все», иначе новая категория
              // прячет карточку за другим фильтром.
              setState(() => _selectedCategory = 'Все');
              if (pop) Navigator.pop(context);
              return true;
            }

            // Старая карточка совсем без снимков: один раз при открытии
            // пробуем найти картинку в интернете — кнопки «Найти фото» нет.
            if (!openSearchDone) {
              openSearchDone = true;
              if (isEditing && currentGallery().isEmpty) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => findWebImage(),
                );
              }
            }

            return DirtyLeaveScope(
              dirty: formDirty,
              onSave: () => saveItem(pop: false),
              onDispose: () {
                _gone = true;
                debounce?.cancel();
                categoryDebounce?.cancel();
                nameController.dispose();
                partNumController.dispose();
                modelController.dispose();
                barcodeController.dispose();
                priceController.dispose();
                quantityController.dispose();
                otherController.dispose();
                interchangeController.dispose();
              },
              child: Scaffold(
                backgroundColor: Colors.grey.shade100,
                appBar: AppBar(
                  title: Text(
                    isEditing ? 'Редактировать'.tr : 'Новая деталь'.tr,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  backgroundColor: const Color(0xFF14557F),
                  foregroundColor: Colors.white,
                  automaticallyImplyLeading: false,
                ),
                body: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isEditing &&
                        (foundDuplicate != null || foundSubstitute != null))
                      _duplicateCompare(
                        existing: (foundDuplicate ?? foundSubstitute)!,
                        draftName: nameController.text.trim(),
                        draftPart: partNumController.text.trim(),
                        draftModel: modelController.text.trim(),
                        draftCategory: itemCategory,
                        draftPrice:
                            double.tryParse(priceController.text) ?? 0,
                        draftQty:
                            int.tryParse(quantityController.text) ?? 0,
                        draftUsed: isUsed,
                        draftImage: currentGallery().firstOrNull,
                        isSubstitute: foundDuplicate == null,
                        why: substituteWhy,
                      ),

                    if (!isEditing &&
                        substituteRefuted &&
                        foundDuplicate == null &&
                        foundSubstitute == null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFDEBEC),
                          border: Border.all(color: Colors.red.shade200),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 18,
                              color: Colors.red.shade700,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Каталог показывает эту деталь отдельно — '
                                'такую же на полке не подставляю.'.tr,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.red.shade900,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    if (isCheckingDuplicate && !isEditing)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: LinearProgressIndicator(
                          color: Color(0xFFFCC520),
                          minHeight: 2,
                        ),
                      ),

                    _buildCompactTextField(
                      controller: nameController,
                      label: 'Название запчасти'.tr,
                      maxLines: 2,
                      onChanged: (_) {
                        markDirty();
                        guessCategory();
                      },
                    ),
                    const SizedBox(height: 8),

                    DropdownButtonFormField<String>(
                      value: _categories.any((c) => c['name'] == itemCategory)
                          ? itemCategory
                          : 'Универсальное',
                      isDense: true,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Категория'.tr,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      items: _categories.where((c) => c['name'] != 'Все').map((
                        categoryData,
                      ) {
                        return DropdownMenuItem<String>(
                          value: categoryData['name'],
                          child: Row(
                            children: [
                              AppliancePicture(
                                type: categoryData['type'] ?? 'other',
                                size: 28,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  trAny(categoryData['name'] ?? ''),
                                  style: const TextStyle(fontSize: 14),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val == null) return;
                        setDialogState(() {
                          itemCategory = val;
                          // Выбрали руками — больше не подставляем своё.
                          categoryTouched = true;
                          categoryAuto = false;
                          formDirty = true;
                        });
                      },
                    ),
                    if (categoryThinking || categoryAuto)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, left: 4),
                        child: Row(
                          children: [
                            Icon(
                              categoryThinking
                                  ? Icons.hourglass_empty
                                  : Icons.auto_awesome,
                              size: 13,
                              color: Colors.black45,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              categoryThinking
                                  ? 'Определяю категорию…'.tr
                                  : 'Выбрано автоматически — можно поменять'.tr,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Colors.black45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),

                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: _buildCompactTextField(
                            controller: partNumController,
                            label: 'Part Number',
                            onChanged: (_) => onFieldChanged(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 3,
                          child: _buildCompactTextField(
                            controller: modelController,
                            label: 'Модель (Model)'.tr,
                            onChanged: (_) {
                              markDirty();
                              guessCategory();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    Row(
                      children: [
                        Expanded(
                          child: _buildCompactTextField(
                            controller: priceController,
                            label: 'Цена (\$)'.tr,
                            isNumber: true,
                            onTap: () {
                              if (!priceFresh) return;
                              priceFresh = false;
                              clearAutoNumber(priceController);
                            },
                            onChanged: (_) {
                              priceFresh = false;
                              markDirty();
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildCompactTextField(
                            controller: quantityController,
                            label: 'Кол-во'.tr,
                            isNumber: true,
                            onTap: () {
                              if (!qtyFresh) return;
                              qtyFresh = false;
                              clearAutoNumber(quantityController);
                            },
                            onChanged: (_) {
                              qtyFresh = false;
                              markDirty();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    _conditionSwitch(
                      isUsed: isUsed,
                      onChanged: (value) => setDialogState(() {
                        isUsed = value;
                        formDirty = true;
                      }),
                    ),
                    const SizedBox(height: 8),

                    _buildCompactTextField(
                      controller: interchangeController,
                      label: 'Заменяет номера (через запятую)'.tr,
                      maxLines: 1,
                      onChanged: (_) {
                        interchangeTouched = true;
                        interchangeAuto = false;
                        markDirty();
                      },
                    ),
                    if (interchangeThinking || interchangeAuto)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, left: 4),
                        child: Row(
                          children: [
                            Icon(
                              interchangeThinking
                                  ? Icons.hourglass_empty
                                  : Icons.auto_awesome,
                              size: 13,
                              color: Colors.black45,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              interchangeThinking
                                  ? 'ИИ ищет замены…'.tr
                                  : 'ИИ подставил номера замен'.tr,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Colors.black45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),

                    _buildCompactTextField(
                      controller: otherController,
                      label: 'Заметки'.tr,
                      maxLines: 1,
                      onChanged: (_) => markDirty(),
                    ),
                    const SizedBox(height: 16),

                    if (webSearching) _webSearchingRow(),
                    // Все снимки — свои и найденные в интернете — над «+».
                    _photoStrip(
                      urls: currentGallery(),
                      webUrl: (webImageUrl ?? '').trim(),
                      coverUrl: coverUrl,
                      onOpen: _openPhotos,
                      onLongPress: photoMenu,
                    ),
                    const SizedBox(height: 10),
                    _addPhotoButton(
                      busy: isUploadingPhoto || isAiThinking,
                      label: isAiThinking
                          ? 'ИИ читает…'.tr
                          : isUploadingPhoto
                              ? 'Загружаю фото…'.tr
                              : null,
                      onTap: openAddSheet,
                    ),
                  ],
                ),
                ),
                bottomNavigationBar: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isEditing &&
                        (foundDuplicate != null || foundSubstitute != null))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: isAiThinking
                                    ? null
                                    : () => saveItem(merge: false),
                                child: Text('Оставить две'.tr),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: isAiThinking
                                    ? null
                                    : () => saveItem(merge: true),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF008F3B),
                                  foregroundColor: Colors.white,
                                ),
                                child: Text('Объединить'.tr),
                              ),
                            ),
                          ],
                        ),
                      ),
                    BottomConfirmButton(
                      dirty: formDirty,
                      onPressed:
                          isAiThinking ? null : () => saveItem(),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      // Диалог закрыт — блокируем все async setDialogState до отмены таймеров.
      _gone = true;
      // Отложенный поиск дубля не должен стрелять по закрытому окну.
      debounce?.cancel();
      categoryDebounce?.cancel();
      // Найденная картинка уже лежит в Storage. Карточку не сохранили —
      // убираем за собой.
      final pending = (webImageUrl ?? '').trim();
      if (!saved && pending.isNotEmpty && pending != savedWebImage) {
        unawaited(PartImageService.discard(pending));
      }
    });
  }

  /// Две карточки рядом: что уже лежит и что человек сейчас вводит.
  Widget _duplicateCompare({
    required DocumentSnapshot existing,
    required String draftName,
    required String draftPart,
    required String draftModel,
    required String draftCategory,
    required double draftPrice,
    required int draftQty,
    required bool draftUsed,
    String? draftImage,
    bool isSubstitute = false,
    String why = '',
  }) {
    final old = existing.data() as Map<String, dynamic>? ?? {};
    final inTrash = old['deletedAt'] != null;
    final title = isSubstitute
        ? 'Этой детали нет — есть замена'.tr
        : inTrash
            ? 'Такой номер уже есть — в корзине'.tr
            : 'Такой номер уже есть на складе'.tr;
    final subtitle = isSubstitute
        ? (why.isEmpty
            ? 'Можно прибавить количество к той карточке или оставить две.'.tr
            : '${'Можно прибавить количество к той карточке или оставить две.'.tr} ($why)')
        : 'Сверьте карточки. Объединить — одна деталь. Оставить две — обе.'.tr;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E6),
        border: Border.all(color: Colors.orange.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: Colors.orange.shade900,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 11.5, color: Colors.black54),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _miniPartCard(
                  title: inTrash ? 'В корзине'.tr : 'На складе'.tr,
                  name: '${old['name'] ?? ''}',
                  part: '${old['partNumber'] ?? ''}',
                  model: '${old['modelNumber'] ?? ''}',
                  category: '${old['category'] ?? ''}',
                  price: double.tryParse('${old['price'] ?? 0}') ?? 0,
                  qty: int.tryParse('${old['quantity'] ?? 0}') ?? 0,
                  used: old['isUsed'] == true,
                  imageUrl: '${old['webImageUrl'] ?? ''}'.trim().isNotEmpty
                      ? '${old['webImageUrl']}'
                      : old['imageUrl']?.toString(),
                  color: const Color(0xFF14557F),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _miniPartCard(
                  title: 'Вы вводите'.tr,
                  name: draftName,
                  part: draftPart,
                  model: draftModel,
                  category: draftCategory,
                  price: draftPrice,
                  qty: draftQty,
                  used: draftUsed,
                  imageUrl: draftImage,
                  color: const Color(0xFF008F3B),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniPartCard({
    required String title,
    required String name,
    required String part,
    required String model,
    required String category,
    required double price,
    required int qty,
    required bool used,
    String? imageUrl,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 6),
          if (imageUrl != null && imageUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image(
                image: thumbImage(imageUrl, width: 240),
                height: 56,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          if (imageUrl != null && imageUrl.isNotEmpty)
            const SizedBox(height: 6),
          Text(
            name.isEmpty ? '—' : name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
          if (part.isNotEmpty)
            Text(
              part,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          if (model.isNotEmpty)
            Text(
              model,
              style: const TextStyle(fontSize: 10, color: Colors.black45),
            ),
          if (category.isNotEmpty)
            Text(
              trAny(category),
              style: const TextStyle(fontSize: 10, color: Colors.black45),
            ),
          Text(
            '\$${price.toStringAsFixed(2)} · $qty ${'шт'.tr}'
            '${used ? ' · ${'Б/у'.tr}' : ''}',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  /// Новая / б/у. Две половинки одной кнопки — видно, что выбрано.
  Widget _conditionSwitch({
    required bool isUsed,
    required ValueChanged<bool> onChanged,
  }) {
    Widget half(String label, IconData icon, bool selected, bool value) {
      final color = value ? Colors.orange.shade700 : Colors.green.shade600;
      return Expanded(
        child: Material(
          color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
          child: InkWell(
            onTap: () => onChanged(value),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: selected ? color : Colors.black38,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                      color: selected ? color : Colors.black54,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade400),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          half('Новая'.tr, Icons.auto_awesome, !isUsed, false),
          Container(width: 1, height: 40, color: Colors.grey.shade300),
          half('Б/у'.tr, Icons.history, isUsed, true),
        ],
      ),
    );
  }

  /// Открыть снимки на весь экран. Тот же просмотрщик, что в заявках:
  /// свайп между фото и зум пальцами.
  void _openPhotos(List<String> urls, int index) {
    if (urls.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenGallery(
          images: [
            for (final url in urls) <String, dynamic>{'url': url},
          ],
          initialIndex: index,
        ),
      ),
    );
  }
  /// Полоса снимков карточки: тап — посмотреть, долгий тап — сделать фото
  /// по умолчанию или убрать. Первым идёт фото по умолчанию (звёздочка),
  /// картинка из интернета помечена глобусом.
  Widget _photoStrip({
    required List<String> urls,
    required String webUrl,
    required String coverUrl,
    required void Function(List<String> urls, int index) onOpen,
    required void Function(String url) onLongPress,
  }) {
    Widget badge(IconData icon, Color color) => Container(
      margin: const EdgeInsets.all(3),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Icon(icon, size: 13, color: color),
    );

    Widget thumb(int index) {
      final url = urls[index];
      final isCover = coverUrl.isNotEmpty && url == coverUrl;
      return GestureDetector(
        onTap: () => onOpen(urls, index),
        onLongPress: () {
          HapticFeedback.mediumImpact();
          onLongPress(url);
        },
        child: Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isCover ? const Color(0xFFFCC520) : Colors.grey.shade400,
              width: isCover ? 2.4 : 1,
            ),
            image: DecorationImage(
              image: thumbImage(url, width: 252),
              fit: BoxFit.cover,
            ),
          ),
          child: Stack(
            children: [
              if (isCover)
                Positioned(
                  left: 0,
                  top: 0,
                  child: badge(Icons.star_rounded, const Color(0xFFFCC520)),
                ),
              if (url == webUrl && webUrl.isNotEmpty)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: badge(Icons.public, Colors.white),
                ),
            ],
          ),
        ),
      );
    }

    if (urls.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${'Фотографии детали'.tr} · ${urls.length}',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 84,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: urls.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, index) => thumb(index),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Тап — посмотреть, долгий тап — фото по умолчанию или убрать'.tr,
          style: const TextStyle(fontSize: 11, color: Colors.black38),
        ),
      ],
    );
  }

  /// Единственная кнопка добавления: «+». Что именно добавить — в окне снизу.
  Widget _addPhotoButton({
    required bool busy,
    required String? label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 56,
      child: Material(
        color: const Color(0xFFFCC520),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: busy ? null : onTap,
          child: Center(
            child: busy
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.black87,
                        ),
                      ),
                      if (label != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          label,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ],
                  )
                : const Icon(Icons.add, size: 34, color: Colors.black87),
          ),
        ),
      ),
    );
  }

  /// Плитка в окне «+»: большая — сканер, две поменьше — фото.
  Widget _addChoice({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    String? hint,
    bool big = false,
  }) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: big ? 48 : 28, color: Colors.white),
              SizedBox(height: big ? 10 : 4),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(
                  fontSize: big ? 16 : 14,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              if (hint != null) ...[
                const SizedBox(height: 4),
                Text(
                  hint,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 11.5, color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Пока ИИ ищет картинку детали в интернете.
  Widget _webSearchingRow() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        border: Border.all(
          color: const Color(0xFF14557F).withValues(alpha: 0.35),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Color(0xFF14557F),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'ИИ ищет фото детали в интернете…'.tr,
              style: const TextStyle(
                fontSize: 12.5,
                color: Color(0xFF14557F),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactTextField({
    required TextEditingController controller,
    required String label,
    bool isNumber = false,
    int maxLines = 1,
    Function(String)? onChanged,
    VoidCallback? onTap,
  }) {
    return TextField(
      controller: controller,
      keyboardType: isNumber
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      maxLines: maxLines,
      minLines: 1,
      textCapitalization: TextCapitalization.sentences,
      style: const TextStyle(fontSize: 14),
      onChanged: onChanged,
      onTap: onTap,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// Кнопки «+ / −» в списке. Инкремент, а не `currentQty + change`: число в
  /// снимке может быть устаревшим, и два быстрых нажатия теряли одно. Плюс
  /// `settleWrite` — без сети сырой `update()` не завершался и кнопка висела.
  Future<void> _updateQuantity(
    DocumentReference ref,
    int currentQty,
    int change,
  ) async {
    if (change == 0) return;
    // Минусом ниже нуля вручную не уводим: это жест «ошибся», а не учёт.
    if (change < 0 && currentQty + change < 0) return;
    await settleWrite(
      ref.update({
        'quantity': FieldValue.increment(change),
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  Future<void> _deleteItem(DocumentReference ref) async {
    final confirm = await showConfirmCancelSheet(
      context,
      title: 'Удалить?'.tr,
      confirmLabel: 'Удалить'.tr,
    );
    if (confirm) await WarehouseService.delete(ref.id);
  }

  Widget _categoryPhoto(String category, {double size = 24, bool onDark = false}) {
    return AppliancePicture(
      type: _categoryType(category),
      size: size,
      onDark: onDark,
    );
  }

  String _categoryType(String category) {
    switch (category) {
      case 'Холодильник':
        return 'fridge';
      case 'Стиральная машина':
        return 'washer';
      case 'Сушилка':
        return 'dryer';
      case 'Плита/Духовка':
        return 'stove';
      case 'Посудомойка':
        return 'dishwasher';
      default:
        return 'other';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(
          'Склад'.tr,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        elevation: 0,
      ),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _categories.length,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemBuilder: (context, index) {
                        final catData = _categories[index];
                        final String categoryName = catData['name'] ?? 'Все';
                        final isSelected = _selectedCategory == categoryName;

                        return Tooltip(
                          message: trAny(categoryName),
                          child: GestureDetector(
                          onTap: () =>
                              setState(() => _selectedCategory = categoryName),
                          child: Container(
                            width: 44,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF14557F)
                                  : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF14557F)
                                    : Colors.grey.shade300,
                              ),
                            ),
                            padding: const EdgeInsets.all(4),
                            child: categoryName == 'Все'
                                ? Icon(
                                    Icons.apps,
                                    size: 22,
                                    color: isSelected
                                        ? Colors.white
                                        : const Color(0xFF14557F),
                                  )
                                : Image.asset(
                                    AppliancePicture.assetOf(
                                      catData['type'] ?? 'other',
                                    ),
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.medium,
                                  ),
                          ),
                        ),
                      );
                      },
                    ),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.only(right: 12, left: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: PopupMenuButton<String>(
                    icon: const Icon(Icons.sort, color: Color(0xFF14557F)),
                    tooltip: 'Сортировка'.tr,
                    onSelected: (newValue) =>
                        setState(() => _sortMethod = newValue),
                    itemBuilder: (context) =>
                        ['Сначала новые', 'Сначала старые', 'По алфавиту'].map((
                          String value,
                        ) {
                          return PopupMenuItem<String>(
                            value: value,
                            child: Text(
                              trAny(value),
                              style: TextStyle(
                                fontWeight: _sortMethod == value
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          );
                        }).toList(),
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _itemsStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting)
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFCC520)),
                  );
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty)
                  return Center(
                    child: Text(
                      'Склад пуст.'.tr,
                      style: TextStyle(color: Colors.grey),
                    ),
                  );

                List<DocumentSnapshot> docs = snapshot.data!.docs.where((doc) {
                  final raw = doc.data();
                  if (raw is! Map) return false;
                  final data = Map<String, dynamic>.from(raw);
                  final name = (data['name'] ?? '').toString().toUpperCase();
                  final partNumber = (data['partNumber'] ?? '')
                      .toString()
                      .toUpperCase();
                  final modelNumber = (data['modelNumber'] ?? '')
                      .toString()
                      .toUpperCase();
                  final barcode = (data['barcode'] ?? '')
                      .toString()
                      .toUpperCase();
                  final category = data['category'] ?? 'Универсальное';
                  if (data['deletedAt'] != null) return false;

                  bool matchesCategory =
                      _selectedCategory == 'Все' ||
                      category == _selectedCategory;
                  // Ищем и по номерам, которые деталь заменяет, — иначе
                  // взаимозаменяемую деталь по её номеру не найти.
                  final wanted = WarehouseItem.normalizePart(_searchQuery);
                  final replaces =
                      wanted.length >= 3 &&
                      WarehouseItem.parseInterchange(
                        data['interchange'],
                      ).any((n) => WarehouseItem.normalizePart(n) == wanted);

                  bool matchesSearch =
                      name.contains(_searchQuery) ||
                      partNumber.contains(_searchQuery) ||
                      modelNumber.contains(_searchQuery) ||
                      barcode.contains(_searchQuery) ||
                      replaces;

                  return matchesCategory && matchesSearch;
                }).toList();

                docs.sort((a, b) {
                  final dataA = a.data() as Map<String, dynamic>;
                  final dataB = b.data() as Map<String, dynamic>;

                  if (_sortMethod == 'Сначала новые' ||
                      _sortMethod == 'Сначала старые') {
                    final tA = dataA['createdAt'] as Timestamp?;
                    final tB = dataB['createdAt'] as Timestamp?;
                    if (tA == null && tB == null) return 0;
                    if (tA == null) return -1;
                    if (tB == null) return 1;
                    return _sortMethod == 'Сначала новые'
                        ? tB.compareTo(tA)
                        : tA.compareTo(tB);
                  } else {
                    return (dataA['name'] ?? '')
                        .toString()
                        .toLowerCase()
                        .compareTo(
                          (dataB['name'] ?? '').toString().toLowerCase(),
                        );
                  }
                });

                if (docs.isEmpty)
                  return Center(
                    child: Text(
                      'Ничего не найдено'.tr,
                      style: TextStyle(color: Colors.grey),
                    ),
                  );

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;

                    final String name = '${data['name'] ?? ''}';
                    final String partNumber = data['partNumber'] ?? '';
                    final String modelNumber = data['modelNumber'] ?? '';
                    // Все снимки карточки: по нажатию на плитку их листают
                    // на весь экран, не открывая редактор. Первым идёт фото
                    // по умолчанию, без него — каталожная картинка: на ней
                    // видно деталь, а на стикере — только буквы.
                    final photos = WarehouseItem.galleryOf(
                      coverUrl: '${data['coverUrl'] ?? ''}',
                      imageUrl: '${data['imageUrl'] ?? ''}',
                      webImageUrl: '${data['webImageUrl'] ?? ''}',
                      photos: WarehouseItem.parsePhotos(data['photos']),
                    );
                    final String imageUrl = photos.isEmpty ? '' : photos.first;
                    final String category = data['category'] ?? 'Универсальное';
                    final double price =
                        double.tryParse(data['price'].toString()) ?? 0.0;
                    final int quantity =
                        int.tryParse(data['quantity'].toString()) ?? 0;

                    // Минус — недостача: деталь поставили, а на складе её не
                    // числилось. Показываем красным, как и ноль, а не жёлтым.
                    Color statusColor = quantity <= 0
                        ? Colors.red
                        : (quantity <= 2 ? Colors.orange : Colors.green);

                    return Card(
                      elevation: 1,
                      margin: const EdgeInsets.only(bottom: 6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: statusColor.withOpacity(0.4),
                          width: 1.5,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        // Раньше карточка открывалась только двойным тапом —
                        // об этом невозможно догадаться.
                        onTap: () => _showItemDialog(document: doc),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8.0,
                            vertical: 6.0,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              GestureDetector(
                                onTap: photos.isEmpty
                                    ? () => _showItemDialog(document: doc)
                                    : () => _openPhotos(photos, 0),
                                child: Stack(
                                  children: [
                                    Container(
                                      height: 48,
                                      width: 48,
                                      margin: const EdgeInsets.only(right: 10),
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: Colors.grey.shade200,
                                        ),
                                        image: imageUrl.isNotEmpty
                                            ? DecorationImage(
                                                image: thumbImage(
                                                  imageUrl,
                                                  width: 144,
                                                ),
                                                fit: BoxFit.cover,
                                              )
                                            : null,
                                      ),
                                      child: imageUrl.isEmpty
                                          ? _categoryPhoto(category, size: 48)
                                          : null,
                                    ),
                                    if (photos.length > 1)
                                      Positioned(
                                        right: 12,
                                        bottom: 2,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black54,
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            '${photos.length}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${'Название'.tr}: $name',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (partNumber.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        'Part: $partNumber',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade700,
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                    if (modelNumber.isNotEmpty) ...[
                                      Text(
                                        'Model: $modelNumber',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 2),
                                    Row(
                                      children: [
                                        Text(
                                          '\$${price.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF14557F),
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                        if (data['isUsed'] == true) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 1,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.orange.shade50,
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                              border: Border.all(
                                                color: Colors.orange.shade300,
                                              ),
                                            ),
                                            child: Text(
                                              'Б/у'.tr,
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.orange.shade800,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),

                              Row(
                                children: [
                                  Container(
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade50,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: Colors.grey.shade200,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        InkWell(
                                          onTap: () => _updateQuantity(
                                            doc.reference,
                                            quantity,
                                            -1,
                                          ),
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                            child: Icon(
                                              Icons.remove,
                                              color: Colors.red,
                                              size: 18,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          constraints: const BoxConstraints(
                                            minWidth: 20,
                                          ),
                                          alignment: Alignment.center,
                                          child: Text(
                                            '$quantity',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                        InkWell(
                                          onTap: () => _updateQuantity(
                                            doc.reference,
                                            quantity,
                                            1,
                                          ),
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                            child: Icon(
                                              Icons.add,
                                              color: Colors.green,
                                              size: 18,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                      size: 22,
                                    ),
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.all(4),
                                    onPressed: () => _deleteItem(doc.reference),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Поиск и «+» внизу — под большим пальцем.
          Container(
            color: const Color(0xFF14557F),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onChanged: (value) =>
                          setState(() => _searchQuery = value.toUpperCase()),
                      decoration: InputDecoration(
                        hintText: 'Поиск (Название или Номер)...'.tr,
                        prefixIcon: const Icon(Icons.search, color: Colors.grey),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(
                                  Icons.clear,
                                  color: Colors.grey,
                                  size: 20,
                                ),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 50,
                    height: 50,
                    child: FloatingActionButton(
                      heroTag: 'warehouse-add',
                      elevation: 2,
                      onPressed: () => _showItemDialog(),
                      backgroundColor: const Color(0xFFFCC520),
                      child: const Icon(Icons.add, color: Colors.black, size: 28),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
