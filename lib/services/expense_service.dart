import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../core/api_keys.dart';
import '../core/app_commands.dart';
import '../core/constants.dart';
import '../models/expense.dart';
import 'firestore_service.dart';

class ExpenseParseException implements Exception {
  final String message;
  ExpenseParseException(this.message);
  @override
  String toString() => message;
}

class ExpenseService {
  static CollectionReference get _ref => FirestoreService.expensesRef;

  static Stream<List<Expense>> streamAll() {
    return _ref.snapshots().map((snap) {
      final items = snap.docs
          .map(
            (doc) => Expense.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            ),
          )
          .toList();
      items.sort((a, b) => b.date.compareTo(a.date));
      return items;
    });
  }

  static List<Expense> inPeriod(
    List<Expense> items,
    DateTime start,
    DateTime endExclusive,
  ) {
    return [
      for (final item in items)
        if (!DateTime(item.date.year, item.date.month, item.date.day)
                .isBefore(DateTime(start.year, start.month, start.day)) &&
            DateTime(item.date.year, item.date.month, item.date.day)
                .isBefore(endExclusive))
          item,
    ];
  }

  static Future<String> create(Expense expense) async {
    final doc = await _ref.add({
      ...expense.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return doc.id;
  }

  static Future<void> update(String id, Expense expense) {
    return _ref.doc(id).set(expense.toMap(), SetOptions(merge: true));
  }

  static Future<void> delete(String id) {
    AppCommands.reactAngry();
    return _ref.doc(id).delete();
  }

  static Future<XFile?> pickPhoto(ImageSource source) {
    return ImagePicker().pickImage(
      source: source,
      imageQuality: 72,
      maxWidth: 1600,
    );
  }

  static Future<({Uint8List bytes, String mime, String name})?> pickPdf() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return (
      bytes: bytes,
      mime: 'application/pdf',
      name: file.name,
    );
  }

  /// Photograph a receipt: upload, let Gemini classify, save the expense.
  static Future<Expense> addFromPhoto(XFile file) async {
    final bytes = await file.readAsBytes();
    final mime = (file.mimeType ?? 'image/jpeg').split(';').first;
    return addFromBytes(
      bytes: bytes,
      mime: mime.startsWith('image/') ? mime : 'image/jpeg',
      fileName: file.name,
    );
  }

  static Future<Expense> addFromBytes({
    required Uint8List bytes,
    required String mime,
    String fileName = '',
  }) async {
    if (bytes.isEmpty) {
      throw ExpenseParseException('Пустой файл');
    }
    if (bytes.length > 8 * 1024 * 1024) {
      throw ExpenseParseException('Файл слишком большой');
    }
    final isPdf = mime.toLowerCase().contains('pdf');
    final contentType = isPdf
        ? 'application/pdf'
        : (mime.startsWith('image/') ? mime : 'image/jpeg');
    final ext = isPdf
        ? 'pdf'
        : (contentType.contains('png')
            ? 'png'
            : contentType.contains('webp')
                ? 'webp'
                : 'jpg');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final storage = FirebaseStorage.instance
        .ref()
        .child('companies')
        .child(kCompanyId)
        .child('expenses')
        .child('$stamp.$ext');
    await storage.putData(bytes, SettableMetadata(contentType: contentType));
    final photoUrl = await storage.getDownloadURL();

    Map<String, dynamic> parsed = const {};
    try {
      parsed = await _parseReceipt(base64Encode(bytes), contentType);
    } catch (error) {
      debugPrint('ExpenseService parse: $error');
    }

    final category = ExpenseCategories.byId(
      (parsed['category'] ?? 'other').toString(),
    );
    var total = (parsed['total'] as num?)?.toDouble() ?? 0;
    var hst = (parsed['hst'] as num?)?.toDouble() ?? 0;
    var net = (parsed['amountExHst'] as num?)?.toDouble() ?? 0;
    if (total <= 0 && net > 0) total = net + hst;
    if (net <= 0 && total > 0) {
      if (hst <= 0) {
        hst = double.parse((total * 13 / 113).toStringAsFixed(2));
      }
      net = double.parse((total - hst).toStringAsFixed(2));
    }
    final dateRaw = (parsed['date'] ?? '').toString();
    final dateMatch = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(dateRaw);
    final date = dateMatch == null
        ? DateTime.now()
        : DateTime(
            int.parse(dateMatch.group(1)!),
            int.parse(dateMatch.group(2)!),
            int.parse(dateMatch.group(3)!),
          );
    final confidence = (parsed['confidence'] as num?)?.toDouble() ?? 0;
    final capital = parsed['capitalLikely'] == true && category.id == 'tools';

    final draft = Expense(
      id: '',
      vendor: (parsed['vendor'] ?? '').toString().trim(),
      date: date,
      amountExHst: net,
      hst: hst,
      total: total,
      category: category.id,
      gifi: category.gifi,
      note: [
        (parsed['note'] ?? parsed['label'] ?? '').toString().trim(),
        if (isPdf && fileName.trim().isNotEmpty) fileName.trim(),
      ].where((part) => part.isNotEmpty).join(' · '),
      photoUrl: photoUrl,
      fileMime: contentType,
      capitalAsset: capital,
      needsReview: confidence < 0.55 || net <= 0,
      confidence: confidence,
      createdAt: DateTime.now(),
    );
    final id = await create(draft);
    return draft.copyWith(id: id);
  }

  static Future<Map<String, dynamic>> _parseReceipt(
    String imageBase64,
    String mime,
  ) async {
    final response = await http
        .post(
          Uri.parse('$kFirebaseFunctionsUrl/parseExpenseReceipt'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'imageBase64': imageBase64,
            'mime': mime,
          }),
        )
        .timeout(const Duration(seconds: 90));
    final body = response.body.isNotEmpty
        ? json.decode(response.body) as Map<String, dynamic>
        : <String, dynamic>{};
    if (response.statusCode != 200 || body['success'] != true) {
      throw ExpenseParseException(
        (body['error'] ?? 'Не удалось прочитать чек').toString(),
      );
    }
    final data = body['expense'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }
}
