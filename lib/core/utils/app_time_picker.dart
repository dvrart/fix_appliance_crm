import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_time_service.dart';
import '../../core/l10n/app_locale.dart';

/// Единый выбор времени: барабан часов и минут, 24 часа.
Future<TimeOfDay?> showAppTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  String? helpText,
}) {
  return showDialog<TimeOfDay>(
    context: context,
    useRootNavigator: true,
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

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 216,
              width: double.infinity,
              child: CupertinoTheme(
                data: const CupertinoThemeData(
                  brightness: Brightness.light,
                  textTheme: CupertinoTextThemeData(
                    dateTimePickerTextStyle: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                ),
                child: CupertinoDatePicker(
                  key: _pickerKey,
                  mode: CupertinoDatePickerMode.time,
                  use24hFormat: true,
                  minuteInterval: 1,
                  initialDateTime: initialDateTime,
                  onDateTimeChanged: (DateTime value) {
                    final next = TimeOfDay(hour: value.hour, minute: value.minute);
                    if (next != _time) {
                      HapticFeedback.selectionClick();
                    }
                    _time = next;
                  },
                ),
              ),
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
                  foregroundColor: const Color(0xFF14557F),
                  backgroundColor: const Color(0xFF14557F).withValues(alpha: 0.08),
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
                        backgroundColor: const Color(0xFFE8E8E8),
                        foregroundColor: Colors.black,
                        shape: const StadiumBorder(),
                      ),
                      child: Text(
                        'Отмена'.tr,
                        style: TextStyle(
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
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
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
