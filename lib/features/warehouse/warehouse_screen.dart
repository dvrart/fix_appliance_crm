import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/warehouse_service.dart';

class WarehouseScreen extends StatefulWidget {
  const WarehouseScreen({super.key});

  @override
  State<WarehouseScreen> createState() => _WarehouseScreenState();
}

class _WarehouseScreenState extends State<WarehouseScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedCategory = 'Все';
  String _sortMethod = 'Сначала новые';

  final List<Map<String, dynamic>> _categories = [
    {'name': 'Все', 'icon': Icons.apps},
    {'name': 'Холодильник', 'icon': Icons.kitchen},
    {'name': 'Стиральная машина', 'icon': Icons.local_laundry_service},
    {'name': 'Сушилка', 'icon': Icons.heat_pump},
    {'name': 'Плита/Духовка', 'icon': Icons.countertops},
    {'name': 'Посудомойка', 'icon': Icons.local_dining},
    {'name': 'Универсальное', 'icon': Icons.build},
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

    String itemCategory = isEditing
        ? (data['category'] ?? 'Универсальное')
        : 'Универсальное';
    String? localImageUrl = isEditing ? data['imageUrl'] : null;
    bool isUploadingPhoto = false;

    Timer? _debounce;
    DocumentSnapshot? foundDuplicate;
    bool isCheckingDuplicate = false;
    bool isAiThinking = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> checkDuplicate(String part) async {
              part = part.trim().toUpperCase();
              if (part.isEmpty) {
                setDialogState(() => foundDuplicate = null);
                return;
              }
              setDialogState(() => isCheckingDuplicate = true);
              DocumentSnapshot? match;

              final q = await WarehouseService.ref
                  .where('partNumber', isEqualTo: part)
                  .limit(1)
                  .get();
              if (q.docs.isNotEmpty) match = q.docs.first;

              if (!context.mounted) return;

              setDialogState(() {
                foundDuplicate = match;
                isCheckingDuplicate = false;

                if (match != null && !isEditing) {
                  final matchData = match.data() as Map<String, dynamic>? ?? {};
                  if (nameController.text.isEmpty)
                    nameController.text = matchData['name'] ?? '';
                  if (modelController.text.isEmpty)
                    modelController.text = matchData['modelNumber'] ?? '';
                  if (priceController.text.isEmpty ||
                      priceController.text == '0.0')
                    priceController.text =
                        matchData['price']?.toString() ?? '0.0';
                  if (matchData['category'] != null &&
                      _categories.any(
                        (c) => c['name'] == matchData['category'],
                      ))
                    itemCategory = matchData['category'];
                  if (matchData['imageUrl'] != null)
                    localImageUrl = matchData['imageUrl'];
                }
              });
            }

            void onFieldChanged() {
              if (isEditing) return;
              if (_debounce?.isActive ?? false) _debounce!.cancel();
              _debounce = Timer(const Duration(milliseconds: 600), () {
                checkDuplicate(partNumController.text);
              });
            }

            int duplicateQty = 0;
            if (foundDuplicate != null) {
              final dupData =
                  foundDuplicate!.data() as Map<String, dynamic>? ?? {};
              duplicateQty =
                  int.tryParse(dupData['quantity']?.toString() ?? '0') ?? 0;
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              title: Text(
                isEditing ? 'Редактировать'.tr : 'Новая деталь'.tr,
                style: const TextStyle(
                  color: Color(0xFF14557F),
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
                textAlign: TextAlign.center,
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (foundDuplicate != null && !isEditing)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          border: Border.all(color: Colors.orange.shade300),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: Colors.orange.shade700,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${'На складе уже есть эта деталь'.tr} ($duplicateQty ${'шт'.tr}).',
                                style: TextStyle(
                                  color: Colors.orange.shade900,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
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

                    GestureDetector(
                      onTap: () async {
                        final picker = ImagePicker();
                        final pickedFile = await picker.pickImage(
                          source: ImageSource.camera,
                          imageQuality: 70,
                        );
                        if (pickedFile != null) {
                          setDialogState(() => isUploadingPhoto = true);
                          try {
                            File file = File(pickedFile.path);
                            String fileName =
                                'part_${DateTime.now().millisecondsSinceEpoch}.jpg';
                            final ref = FirebaseStorage.instance
                                .ref()
                                .child('warehouse')
                                .child(fileName);
                            await ref.putFile(file);
                            final url = await ref.getDownloadURL();
                            setDialogState(() {
                              localImageUrl = url;
                              isUploadingPhoto = false;
                            });
                          } catch (e) {
                            setDialogState(() => isUploadingPhoto = false);
                          }
                        }
                      },
                      child: Container(
                        height: 90,
                        width: 90,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade300),
                          image: localImageUrl != null
                              ? DecorationImage(
                                  image: NetworkImage(localImageUrl!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: localImageUrl == null
                            ? (isUploadingPhoto
                                  ? const Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFFFCC520),
                                      ),
                                    )
                                  : Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.add_a_photo,
                                          color: Colors.grey,
                                          size: 28,
                                        ),
                                        SizedBox(height: 4),
                                        Text(
                                          'Фото'.tr,
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ],
                                    ))
                            : null,
                      ),
                    ),

                    _buildCompactTextField(
                      controller: nameController,
                      label: 'Название запчасти'.tr,
                      maxLines: 2,
                    ),
                    const SizedBox(height: 8),

                    DropdownButtonFormField<String>(
                      value: _categories.any((c) => c['name'] == itemCategory)
                          ? itemCategory
                          : 'Универсальное',
                      isDense: true,
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
                          child: Text(
                            trAny(categoryData['name']),
                            style: const TextStyle(fontSize: 14),
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null)
                          setDialogState(() => itemCategory = val);
                      },
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
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    _buildCompactTextField(
                      controller: barcodeController,
                      label: 'Штрихкод (UPC/FNSKU)'.tr,
                    ),
                    const SizedBox(height: 8),

                    Row(
                      children: [
                        Expanded(
                          child: _buildCompactTextField(
                            controller: priceController,
                            label: 'Цена (\$)'.tr,
                            isNumber: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildCompactTextField(
                            controller: quantityController,
                            label: 'Кол-во'.tr,
                            isNumber: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    _buildCompactTextField(
                      controller: otherController,
                      label: 'Заметки'.tr,
                      maxLines: 1,
                    ),
                    const SizedBox(height: 16),

                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        icon: isAiThinking
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.document_scanner, size: 20),
                        label: Text(
                          isAiThinking
                              ? 'СКАНИРОВАНИЕ...'.tr
                              : 'УМНЫЙ СКАНЕР ЭТИКЕТКИ'.tr,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green.shade600,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: 0,
                        ),
                        onPressed: isAiThinking
                            ? null
                            : () async {
                                try {
                                  final picker = ImagePicker();
                                  final pickedFile = await picker.pickImage(
                                    source: ImageSource.camera,
                                    imageQuality: 100,
                                  );

                                  if (pickedFile != null) {
                                    setDialogState(() => isAiThinking = true);

                                    final inputImage = InputImage.fromFilePath(
                                      pickedFile.path,
                                    );
                                    final textRecognizer = TextRecognizer(
                                      script: TextRecognitionScript.latin,
                                    );
                                    final RecognizedText recognizedText =
                                        await textRecognizer.processImage(
                                          inputImage,
                                        );
                                    await textRecognizer.close();

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
                                      });

                                      await checkDuplicate(
                                        partNumController.text,
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
                                } catch (e) {
                                  setDialogState(() => isAiThinking = false);
                                  if (context.mounted)
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('${'Ошибка сканера'.tr}: $e'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                }
                              },
                      ),
                    ),
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Отмена'.tr,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton(
                  onPressed: isAiThinking
                      ? null
                      : () async {
                          final name = nameController.text.trim();
                          final partNumber = partNumController.text
                              .trim()
                              .toUpperCase();
                          final modelNumber = modelController.text
                              .trim()
                              .toUpperCase();
                          final barcode = barcodeController.text.trim();
                          final price =
                              double.tryParse(priceController.text) ?? 0.0;
                          final quantity =
                              int.tryParse(quantityController.text) ?? 0;
                          final other = otherController.text.trim();

                          if (name.isEmpty) return;

                          final saveData = {
                            'name': name,
                            'category': itemCategory,
                            'partNumber': partNumber,
                            'modelNumber': modelNumber,
                            'barcode': barcode,
                            'price': price,
                            'other': other,
                            'imageUrl': localImageUrl,
                            'updatedAt': FieldValue.serverTimestamp(),
                          };

                          if (isEditing) {
                            saveData['quantity'] = quantity;
                            await document.reference.update(saveData);
                            if (context.mounted) Navigator.pop(context);
                          } else {
                            QuerySnapshot? existingDocs;
                            if (partNumber.isNotEmpty) {
                              existingDocs = await WarehouseService.ref
                                  .where('partNumber', isEqualTo: partNumber)
                                  .get();
                            }

                            if (existingDocs != null &&
                                existingDocs.docs.isNotEmpty) {
                              if (!context.mounted) return;
                              final bool? choice = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  title: Text(
                                    'Найдено совпадение'.tr,
                                    style: TextStyle(
                                      color: Color(0xFF14557F),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  content: Text(
                                    '${'Запчасть с номером'.tr} $partNumber ${'уже есть на складе. Что вы хотите сделать?'.tr}',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, null),
                                      child: Text(
                                        'Отмена'.tr,
                                        style: TextStyle(color: Colors.grey),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: Text('Создать новую'.tr),
                                    ),
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.green,
                                      ),
                                      child: Text(
                                        'Обновить старую'.tr,
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ),
                                  ],
                                ),
                              );

                              if (choice == null)
                                return;
                              else if (choice == true) {
                                final existingDoc = existingDocs.docs.first;
                                await existingDoc.reference.update({
                                  'quantity': FieldValue.increment(quantity),
                                  'updatedAt': FieldValue.serverTimestamp(),
                                  'price': price,
                                });
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Количество добавлено к старой! 📦'.tr,
                                      ),
                                      backgroundColor: Colors.blue,
                                    ),
                                  );
                                  Navigator.pop(context);
                                }
                              } else {
                                saveData['quantity'] = quantity;
                                saveData['createdAt'] =
                                    FieldValue.serverTimestamp();
                                await WarehouseService.ref.add(saveData);
                                if (context.mounted) Navigator.pop(context);
                              }
                            } else {
                              saveData['quantity'] = quantity;
                              saveData['createdAt'] =
                                  FieldValue.serverTimestamp();
                              await WarehouseService.ref.add(saveData);
                              if (context.mounted) Navigator.pop(context);
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFCC520),
                    foregroundColor: Colors.black,
                  ),
                  child: Text('Сохранить'.tr),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildCompactTextField({
    required TextEditingController controller,
    required String label,
    bool isNumber = false,
    int maxLines = 1,
    Function(String)? onChanged,
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

  Future<void> _updateQuantity(
    DocumentReference ref,
    int currentQty,
    int change,
  ) async {
    final newQty = currentQty + change;
    if (newQty < 0) return;
    await ref.update({'quantity': newQty});
  }

  Future<void> _deleteItem(DocumentReference ref) async {
    final bool confirm =
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Удалить?'.tr),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Отмена'.tr),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: Text(
                  'Удалить'.tr,
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ) ??
        false;
    if (confirm) await ref.delete();
  }

  IconData _getCategoryIcon(String category) {
    switch (category) {
      case 'Холодильник':
        return Icons.kitchen;
      case 'Стиральная машина':
        return Icons.local_laundry_service;
      case 'Сушилка':
        return Icons.heat_pump;
      case 'Плита/Духовка':
        return Icons.countertops;
      case 'Посудомойка':
        return Icons.local_dining;
      case 'Универсальное':
        return Icons.build;
      default:
        return Icons.category;
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
        elevation: 0,
      ),
      body: Column(
        children: [
          Container(
            color: const Color(0xFF14557F),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _searchController,
              onChanged: (value) =>
                  setState(() => _searchQuery = value.toUpperCase()),
              decoration: InputDecoration(
                hintText: 'Поиск (Название или Номер)...'.tr,
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
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
                        final String categoryName = catData['name'];
                        final IconData categoryIcon = catData['icon'];
                        final isSelected = _selectedCategory == categoryName;

                        return GestureDetector(
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
                            child: Icon(
                              categoryIcon,
                              size: 24,
                              color: isSelected
                                  ? Colors.white
                                  : Colors.grey.shade600,
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
              stream: WarehouseService.ref.snapshots(),
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
                  final data = doc.data() as Map<String, dynamic>;
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

                  bool matchesCategory =
                      _selectedCategory == 'Все' ||
                      category == _selectedCategory;
                  bool matchesSearch =
                      name.contains(_searchQuery) ||
                      partNumber.contains(_searchQuery) ||
                      modelNumber.contains(_searchQuery) ||
                      barcode.contains(_searchQuery);

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

                    final String name = data['name'];
                    final String partNumber = data['partNumber'] ?? '';
                    final String modelNumber = data['modelNumber'] ?? '';
                    final String imageUrl = data['imageUrl'] ?? '';
                    final String category = data['category'] ?? 'Универсальное';
                    final double price =
                        double.tryParse(data['price'].toString()) ?? 0.0;
                    final int quantity =
                        int.tryParse(data['quantity'].toString()) ?? 0;

                    Color statusColor = quantity == 0
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
                        onDoubleTap: () => _showItemDialog(document: doc),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8.0,
                            vertical: 6.0,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
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
                                          image: NetworkImage(imageUrl),
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                ),
                                child: imageUrl.isEmpty
                                    ? Icon(
                                        _getCategoryIcon(category),
                                        color: const Color(0xFF14557F),
                                        size: 24,
                                      )
                                    : null,
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
                                    Text(
                                      '\$${price.toStringAsFixed(2)}',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: Color(0xFF14557F),
                                        fontWeight: FontWeight.w900,
                                      ),
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
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showItemDialog(),
        backgroundColor: const Color(0xFFFCC520),
        child: const Icon(Icons.add, color: Colors.black, size: 28),
      ),
    );
  }
}
