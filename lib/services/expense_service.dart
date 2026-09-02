import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
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
import 'network_status_service.dart';
import 'auth_service.dart';

class ExpenseParseException implements Exception {
  final String message;
  ExpenseParseException(this.message);
  @override
  String toString() => message;
}

class PreparedExpense {
  final Expense draft;
  final Uint8List bytes;
  final String mime;
  final String fileName;
  final String fileHash;

  const PreparedExpense({
    required this.draft,
    required this.bytes,
    required this.mime,
    required this.fileName,
    required this.fileHash,
  });
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

  static Future<List<Expense>> fetchAll() async {
    final snap = await _ref.get();
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

  static String fileHashOf(Uint8List bytes) => sha256.convert(bytes).toString();

  static String normalizeVendor(String raw) {
    var text = raw.toLowerCase().trim().replaceAll('&', ' and ');
    text = text.replaceAll(RegExp(r'[^a-z0-9а-яё\s]'), ' ');
    text = text.replaceAll(
      RegExp(
        r'\b(inc|incorporated|ltd|limited|llc|corp|corporation|co|company|the)\b',
      ),
      ' ',
    );
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String normalizeReceiptNo(String raw) {
    return raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  static bool moneyClose(double a, double b) => (a - b).abs() <= 0.05;

  static bool amountsMatch(Expense a, Expense b) {
    if (a.total > 0 && b.total > 0) return moneyClose(a.total, b.total);
    if (a.amountExHst > 0 && b.amountExHst > 0) {
      return moneyClose(a.amountExHst, b.amountExHst);
    }
    return false;
  }

  static bool vendorsSimilar(String a, String b) {
    final left = normalizeVendor(a);
    final right = normalizeVendor(b);
    if (left.isEmpty || right.isEmpty) return true;
    if (left == right) return true;
    if (left.length >= 4 &&
        right.length >= 4 &&
        (left.contains(right) || right.contains(left))) {
      return true;
    }
    final firstLeft = left.split(' ').first;
    final firstRight = right.split(' ').first;
    return firstLeft.length >= 4 && firstLeft == firstRight;
  }

  static int _dayGap(DateTime a, DateTime b) {
    final left = DateTime(a.year, a.month, a.day);
    final right = DateTime(b.year, b.month, b.day);
    return left.difference(right).inDays.abs();
  }

  static bool isLikelyDuplicate(Expense a, Expense b) {
    if (a.fileHash.isNotEmpty && a.fileHash == b.fileHash) return true;
    final noA = normalizeReceiptNo(a.receiptNo);
    final noB = normalizeReceiptNo(b.receiptNo);
    if (noA.length >= 4 && noA == noB) {
      return vendorsSimilar(a.vendor, b.vendor) || amountsMatch(a, b);
    }
    if (!amountsMatch(a, b)) return false;
    if (_dayGap(a.date, b.date) > 1) return false;
    return vendorsSimilar(a.vendor, b.vendor);
  }

  static List<Expense> findDuplicates(
    Expense candidate,
    Iterable<Expense> items, {
    String? excludeId,
  }) {
    final skip = excludeId ?? candidate.id;
    return [
      for (final item in items)
        if (item.id != skip && isLikelyDuplicate(candidate, item)) item,
    ];
  }

  static List<Expense> findByFileHash(String hash, Iterable<Expense> items) {
    if (hash.isEmpty) return const [];
    return [for (final item in items) if (item.fileHash == hash) item];
  }

  static Future<String> create(Expense expense) async {
    final doc = _ref.doc();
    await settleWrite(
      doc.set({
        ...expense.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
      }),
    );
    return doc.id;
  }

  static Future<void> update(String id, Expense expense) {
    return settleWrite(
      _ref.doc(id).set(expense.toMap(), SetOptions(merge: true)),
    );
  }

  static Future<void> delete(String id) {
    AppCommands.reactAngry();
    return settleWrite(_ref.doc(id).delete());
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
    final prepared = await prepareFromBytes(
      bytes: bytes,
      mime: mime,
      fileName: fileName,
    );
    return commitPrepared(prepared);
  }

  static Future<PreparedExpense> prepareFromBytes({
    required Uint8List bytes,
    required String mime,
    String fileName = '',
    String? fileHash,
  }) async {
    if (bytes.isEmpty) {
      throw ExpenseParseException('Пустой файл');
    }
    if (bytes.length > 8 * 1024 * 1024) {
      throw ExpenseParseException('Файл слишком большой');
    }
    final hash = (fileHash == null || fileHash.isEmpty)
        ? fileHashOf(bytes)
        : fileHash;
    final isPdf = mime.toLowerCase().contains('pdf');
    final contentType = isPdf
        ? 'application/pdf'
        : (mime.startsWith('image/') ? mime : 'image/jpeg');

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
    final receiptNo = [
      (parsed['receiptNo'] ?? '').toString(),
      (parsed['invoiceNo'] ?? '').toString(),
    ].map((part) => part.trim()).firstWhere(
          (part) => part.isNotEmpty,
          orElse: () => '',
        );

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
      fileMime: contentType,
      fileHash: hash,
      receiptNo: receiptNo,
      capitalAsset: capital,
      needsReview: confidence < 0.55 || net <= 0,
      confidence: confidence,
      createdAt: DateTime.now(),
    );
    return PreparedExpense(
      draft: draft,
      bytes: bytes,
      mime: contentType,
      fileName: fileName,
      fileHash: hash,
    );
  }

  static Future<Expense> commitPrepared(PreparedExpense prepared) async {
    final isPdf = prepared.mime.toLowerCase().contains('pdf');
    final ext = isPdf
        ? 'pdf'
        : (prepared.mime.contains('png')
            ? 'png'
            : prepared.mime.contains('webp')
                ? 'webp'
                : 'jpg');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final storage = FirebaseStorage.instance
        .ref()
        .child('companies')
        .child(kCompanyId)
        .child('expenses')
        .child('$stamp.$ext');
    await storage.putData(
      prepared.bytes,
      SettableMetadata(contentType: prepared.mime),
    );
    final photoUrl = await storage.getDownloadURL();
    final draft = prepared.draft.copyWith(
      photoUrl: photoUrl,
      fileMime: prepared.mime,
      fileHash: prepared.fileHash,
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
          headers: await AuthService.headers(),
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
