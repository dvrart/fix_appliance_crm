import 'package:flutter/material.dart';

import '../../core/l10n/app_locale.dart';
import 'confirm_action_sheet.dart';

export 'confirm_action_sheet.dart'
    show UnsavedChangesAction, showConfirmCancelSheet;

Future<UnsavedChangesAction> showUnsavedChangesDialog(
  BuildContext context, {
  String? title,
  String? message,
  String? saveLabel,
  String? stayLabel,
  String? discardLabel,
}) {
  return showConfirmActionSheet(
    context,
    title: title ?? 'Сохранить изменения?'.tr,
    message: message ?? 'Без подтверждения изменения не сохранятся.'.tr,
    showDiscard: true,
    saveLabel: saveLabel,
    stayLabel: stayLabel,
    discardLabel: discardLabel,
  );
}
