import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../core/constants.dart';

class OutboundAttachment {
  final String name;
  final String mime;
  final Uint8List bytes;

  const OutboundAttachment({
    required this.name,
    required this.mime,
    required this.bytes,
  });

  bool get isImage => mime.toLowerCase().startsWith('image/');

  bool get isMmsSafe {
    if (bytes.length > 5 * 1024 * 1024) return false;
    final type = mime.toLowerCase();
    return type == 'image/jpeg' ||
        type == 'image/jpg' ||
        type == 'image/png' ||
        type == 'image/gif';
  }
}

class OutboundMediaService {
  static String _guessMime(String name, String? explicit) {
    if (explicit != null && explicit.contains('/')) return explicit;
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return 'application/octet-stream';
  }

  static Future<OutboundAttachment?> pickImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1920,
    );
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty) return null;
    return OutboundAttachment(
      name: picked.name,
      mime: _guessMime(picked.name, picked.mimeType),
      bytes: bytes,
    );
  }

  static Future<OutboundAttachment?> pickFile() async {
    final file = await FilePicker.pickFile();
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return OutboundAttachment(
      name: file.name,
      mime: _guessMime(file.name, null),
      bytes: bytes,
    );
  }

  static Future<String> upload(OutboundAttachment file) async {
    final safe = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final ref = FirebaseStorage.instance
        .ref()
        .child('companies')
        .child(kCompanyId)
        .child('outbound')
        .child('${DateTime.now().millisecondsSinceEpoch}_$safe');
    await ref.putData(file.bytes, SettableMetadata(contentType: file.mime));
    return ref.getDownloadURL();
  }
}
