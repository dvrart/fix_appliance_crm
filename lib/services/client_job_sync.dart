import 'package:cloud_firestore/cloud_firestore.dart';

/// Имя/телефон/адрес клиента должны совпадать на всех карточках работ.
class ClientJobSync {
  static const _companyId = 'fix_appliance_ca';

  static Future<void> apply({
    required String clientId,
    String? name,
    String? phone,
    String? address,
  }) async {
    if (clientId.isEmpty) return;
    final trimmedName = name?.trim();
    final updates = <String, dynamic>{
      if (trimmedName != null && trimmedName.isNotEmpty) 'clientName': trimmedName,
      if (phone != null) 'clientPhone': phone.trim(),
      if (address != null) 'clientAddress': address.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (updates.length <= 1) return;

    final snap = await FirebaseFirestore.instance
        .collection('companies')
        .doc(_companyId)
        .collection('jobs')
        .where('clientId', isEqualTo: clientId)
        .get();
    if (snap.docs.isEmpty) return;

    const chunk = 400;
    for (var i = 0; i < snap.docs.length; i += chunk) {
      final end = (i + chunk > snap.docs.length) ? snap.docs.length : i + chunk;
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs.sublist(i, end)) {
        batch.update(doc.reference, updates);
      }
      await batch.commit();
    }
  }
}
