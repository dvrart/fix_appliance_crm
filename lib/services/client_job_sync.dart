import 'package:cloud_firestore/cloud_firestore.dart';

import 'network_status_service.dart';
import 'sms_service.dart';

/// Имя/телефон/адрес клиента должны совпадать на всех карточках работ.
class ClientJobSync {
  static const _companyId = 'fix_appliance_ca';

  static Future<void> apply({
    required String clientId,
    String? name,
    String? phone,
    String? address,
    String? email,
    bool? isRegular,
  }) async {
    if (clientId.isEmpty) return;
    final trimmedName = name?.trim();
    final updates = <String, dynamic>{
      if (trimmedName != null && trimmedName.isNotEmpty) 'clientName': trimmedName,
      if (phone != null) 'clientPhone': phone.trim(),
      if (address != null) 'clientAddress': address.trim(),
      if (email != null) 'clientEmail': email.trim(),
      if (isRegular != null) 'clientIsRegular': isRegular,
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

    final newPhoneNorm = phone == null ? '' : SmsService.normalizePhone(phone);
    const chunk = 400;
    for (var i = 0; i < snap.docs.length; i += chunk) {
      final end = (i + chunk > snap.docs.length) ? snap.docs.length : i + chunk;
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs.sublist(i, end)) {
        final data = doc.data();
        final docUpdates = Map<String, dynamic>.from(updates);
        final oldPhone = (data['clientPhone'] ?? '').toString().trim();
        final oldPhoneNorm = SmsService.normalizePhone(oldPhone);
        final oldName = (data['clientName'] ?? '').toString().trim();
        final sitePhone = (data['jobSitePhone'] ?? '').toString().trim();
        final sitePhoneNorm = SmsService.normalizePhone(sitePhone);
        final siteName = (data['jobSiteName'] ?? '').toString().trim();
        final hasSite = data['hasJobSite'] == true ||
            (data['jobSiteAddress'] ?? '').toString().trim().isNotEmpty ||
            siteName.isNotEmpty ||
            sitePhone.isNotEmpty;
        if (hasSite &&
            newPhoneNorm.length >= 10 &&
            oldPhoneNorm.length >= 10 &&
            newPhoneNorm != oldPhoneNorm &&
            sitePhoneNorm.length < 10) {
          docUpdates['jobSitePhone'] = oldPhone;
          if (siteName.isEmpty && oldName.isNotEmpty) {
            docUpdates['jobSiteName'] = oldName;
          }
        }
        batch.update(doc.reference, docUpdates);
      }
      await settleWrite(batch.commit());
    }
  }
}
