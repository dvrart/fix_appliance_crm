import 'package:intl/intl.dart';

import '../l10n/app_locale.dart';
import '../../services/app_time_service.dart';

class Formatters {
  static final DateFormat dateShort = DateFormat('dd.MM.yyyy');
  static final DateFormat time24 = DateFormat('HH:mm');
  static final DateFormat dateTime = DateFormat('dd.MM.yyyy HH:mm');

  static String formatDateEn(DateTime? date) {
    if (date == null) return '';
    return DateFormat('MMM d, yyyy', 'en_US').format(date);
  }

  static String formatDate(DateTime? date) {
    if (date == null) return 'Не указана'.tr;
    return AppTimeService.format(date, 'dd.MM.yyyy');
  }

  static String formatDateFull(DateTime? date) {
    if (date == null) return 'Не указана'.tr;
    return AppTimeService.format(
      date,
      'd MMMM yyyy',
      locale: AppLocale.instance.dateLocale,
    );
  }

  static String formatTime(DateTime? date) {
    if (date == null) return '';
    return AppTimeService.format(date, 'HH:mm');
  }

  static String formatDateTime(DateTime? date) {
    if (date == null) return 'Не указано'.tr;
    return AppTimeService.format(date, 'dd.MM.yyyy HH:mm');
  }

  static String formatDayTime(DateTime? date) {
    if (date == null) return '';
    return AppTimeService.format(date, 'dd.MM HH:mm');
  }

  static String formatCurrency(num amount) {
    return '\$${amount.toDouble().toStringAsFixed(2)}';
  }

  static String formatPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) {
      return '(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6)}';
    }
    if (digits.length == 11 && digits.startsWith('1')) {
      return '+1 (${digits.substring(1, 4)}) ${digits.substring(4, 7)}-${digits.substring(7)}';
    }
    return phone;
  }

  static String truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }
}
