import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:signature/signature.dart';

import '../../core/l10n/app_locale.dart';

class ClientSignatureSheet {
  static Future<Uint8List?> capture(BuildContext context) async {
    final controller = SignatureController(
      penStrokeWidth: 2.2,
      penColor: Colors.black,
    );
    try {
      return await showModalBottomSheet<Uint8List>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        enableDrag: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (sheetContext) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Подпись клиента'.tr,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Расписка на PDF счёта'.tr,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: Color(0xFF3D3D3D),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Клиент расписывается на этом телефоне. Для оплаты по SMS не нужна — можно Без подписи.'.tr,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    height: 180,
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFF9E9E9E)),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.grey.shade50,
                    ),
                    child: Signature(
                      controller: controller,
                      backgroundColor: Colors.grey.shade50,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: controller.clear,
                      child: Text('Очистить подпись'.tr),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: Text('Отмена'.tr),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextButton(
                          onPressed: () =>
                              Navigator.pop(sheetContext, Uint8List(0)),
                          child: Text('Без подписи'.tr),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () async {
                            if (controller.isEmpty) {
                              ScaffoldMessenger.of(sheetContext).showSnackBar(
                                SnackBar(
                                  content: Text('Нужна подпись клиента'.tr),
                                ),
                              );
                              return;
                            }
                            final bytes = await controller.toPngBytes();
                            if (!sheetContext.mounted) return;
                            Navigator.pop(sheetContext, bytes);
                          },
                          child: Text('Готово'.tr),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      Future<void>.delayed(
        const Duration(milliseconds: 300),
        controller.dispose,
      );
    }
  }

  static Future<Map<String, dynamic>?> uploadToJob({
    required String jobId,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) return null;
    final fileName = 'signature_${DateTime.now().millisecondsSinceEpoch}.png';
    final storageRef = FirebaseStorage.instance
        .ref()
        .child('jobs/$jobId/attachments/$fileName');
    await storageRef.putData(bytes, SettableMetadata(contentType: 'image/png'));
    final url = await storageRef.getDownloadURL();
    return {
      'url': url,
      'name': fileName,
      'kind': 'signature',
      'uploadedAt': DateTime.now().toIso8601String(),
    };
  }
}
