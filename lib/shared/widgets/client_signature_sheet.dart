import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:signature/signature.dart';

import '../../core/l10n/app_locale.dart';
import 'confirm_action_sheet.dart';

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
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
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
                    'Печатается на PDF счёта'.tr,
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
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      RoundActionButton(
                        color: const Color(0xFFE53935),
                        icon: Icons.close_rounded,
                        tooltip: 'Отмена'.tr,
                        onTap: () => Navigator.pop(sheetContext),
                      ),
                      RoundActionButton(
                        color: const Color(0xFFF5C518),
                        icon: Icons.crop_square_rounded,
                        tooltip: 'Без подписи'.tr,
                        onTap: () =>
                            Navigator.pop(sheetContext, Uint8List(0)),
                      ),
                      RoundActionButton(
                        color: const Color(0xFF22C55E),
                        icon: Icons.check_rounded,
                        tooltip: 'Готово'.tr,
                        onTap: () async {
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
                          if (bytes == null || bytes.isEmpty) {
                            ScaffoldMessenger.of(sheetContext).showSnackBar(
                              SnackBar(
                                content: Text('Не удалось сохранить подпись'.tr),
                              ),
                            );
                            return;
                          }
                          Navigator.pop(sheetContext, bytes);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Отмена'.tr,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'Без подписи'.tr,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'Готово'.tr,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12),
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

  static Future<Map<String, dynamic>> uploadToJob({
    required String jobId,
    required Uint8List bytes,
  }) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final ref = FirebaseStorage.instance.ref().child(
      'jobs/$jobId/attachments/sig_$stamp.png',
    );
    await ref.putData(
      bytes,
      SettableMetadata(contentType: 'image/png'),
    );
    final url = await ref.getDownloadURL();
    return {
      'url': url,
      'kind': 'signature',
      'name': 'signature_$stamp.png',
      'uploadedAt': DateTime.now().toIso8601String(),
    };
  }
}
