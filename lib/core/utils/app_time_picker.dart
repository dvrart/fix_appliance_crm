import 'package:flutter/material.dart';

import '../../services/app_time_service.dart';
import '../constants.dart';
import '../l10n/app_locale.dart';
import 'app_date_picker.dart';

/// Единый выбор времени: барабан часов и минут, 24 часа, без круговой прокрутки.
/// Окно снизу — кнопки под большим пальцем.
Future<TimeOfDay?> showAppTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  String? helpText,
}) {
  return showModalBottomSheet<TimeOfDay>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (context) => _AppTimePickerDialog(
      initialTime: initialTime,
      title: helpText ?? 'Выберите время'.tr,
    ),
  );
}

class _AppTimePickerDialog extends StatefulWidget {
  final TimeOfDay initialTime;
  final String title;

  const _AppTimePickerDialog({
    required this.initialTime,
    required this.title,
  });

  @override
  State<_AppTimePickerDialog> createState() => _AppTimePickerDialogState();
}

class _AppTimePickerDialogState extends State<_AppTimePickerDialog> {
  late TimeOfDay _time;
  Key _pickerKey = UniqueKey();
  bool _loadingGeo = false;
  String? _geoError;

  @override
  void initState() {
    super.initState();
    _time = widget.initialTime;
  }

  Future<void> _applyGeolocationTime() async {
    setState(() {
      _loadingGeo = true;
      _geoError = null;
    });
    final result = await AppTimeService.detectFromLocation();
    if (!mounted) return;
    setState(() {
      _loadingGeo = false;
      if (result.info == null) {
        _geoError = result.error ?? 'Не удалось определить время по GPS'.tr;
        return;
      }
      _time = TimeOfDay(
        hour: result.info!.localNow.hour,
        minute: result.info!.localNow.minute,
      );
      _pickerKey = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    final initialDateTime = DateTime(
      2024,
      1,
      1,
      _time.hour,
      _time.minute,
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            AppTimeWheel(
              key: _pickerKey,
              height: 200,
              value: initialDateTime,
              onChanged: (DateTime value) {
                _time = TimeOfDay(hour: value.hour, minute: value.minute);
              },
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: TextButton.icon(
                onPressed: _loadingGeo ? null : _applyGeolocationTime,
                icon: _loadingGeo
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location, size: 20),
                label: Text(
                  _loadingGeo ? 'Определяем по GPS…'.tr : 'По геолокации'.tr,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primaryOnCard,
                  backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
            if (_geoError != null) ...[
              const SizedBox(height: 8),
              Text(
                _geoError!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        backgroundColor: AppColors.cardMuted,
                        foregroundColor: AppColors.ink,
                        shape: const StadiumBorder(),
                      ),
                      child: Text(
                        'Отмена'.tr,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, _time),
                      style: TextButton.styleFrom(
                        backgroundColor: AppColors.isDark
                            ? AppColors.accent
                            : Colors.black,
                        foregroundColor: AppColors.isDark
                            ? Colors.black
                            : Colors.white,
                        shape: const StadiumBorder(),
                      ),
                      child: const Text(
                        'OK',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
