import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mek_stripe_terminal/mek_stripe_terminal.dart';
import 'package:permission_handler/permission_handler.dart';

import 'settings_service.dart';
import 'stripe_service.dart';
import '../core/l10n/app_locale.dart';

class StripeReaderStatus {
  final bool connected;
  final String name;
  final bool isHardware;

  const StripeReaderStatus({
    required this.connected,
    required this.name,
    required this.isHardware,
  });
}

/// Приём карты через Stripe: телефон (Tap to Pay) или Bluetooth-терминал Stripe.
class StripeTerminalService {
  static final TapToPayReaderDelegate _tapDelegate = _StatusTapToPayDelegate();
  static final MobileReaderDelegate _mobileDelegate = _StatusMobileReaderDelegate();
  static Completer<List<Reader>>? _discoverCompleter;
  static StreamSubscription<List<Reader>>? _discoverSub;
  static void Function(String)? _statusSink;

  static void _emit(String text) => _statusSink?.call(text);

  static Future<StripeTerminalComplete> collectPayment({
    required String jobId,
    required int documentIndex,
    double? amount,
    double tip = 0,
    void Function(String status)? onStatus,
    void Function(CancelableFuture<PaymentIntent> processing)? onProcessing,
  }) async {
    if (!Platform.isAndroid) {
      throw StripeServiceException(
        'Приём карты сейчас работает на Android (Samsung).',
      );
    }

    _statusSink = onStatus;
    try {
      final config = await SettingsService.loadConfig();
      final useTerminal =
          SettingsService.readCardReader(config) == SettingsService.cardReaderTerminal;

      onStatus?.call('Разрешаю доступ для терминала...'.tr);
      await _requestPermissions(useTerminal: useTerminal);

      onStatus?.call('Подключаю Stripe...'.tr);
      final connection = await _ensureReady();
      final simulated = useTerminal ? false : (kDebugMode || connection.simulated);
      final locationId = useTerminal
          ? await _resolveLocationId(connection.locationId)
          : connection.locationId;

      await _ensureReaderConnected(
        locationId: locationId,
        simulated: simulated,
        useTerminal: useTerminal,
        onStatus: onStatus,
      );

      onStatus?.call('Создаю платёж...'.tr);
      final created = await StripeService.createTerminalPaymentIntent(
        jobId: jobId,
        documentIndex: documentIndex,
        amount: (amount ?? 0) + tip,
        tip: tip,
      );

      onStatus?.call(
        simulated
            ? 'Тестовый режим: сейчас будет симулятор карты'.tr
            : useTerminal
                ? 'Вставьте, приложите или проведите карту на терминале Stripe'.tr
                : 'Поднесите карту клиента к задней панели телефона'.tr,
      );

      final intent = await Terminal.instance.retrievePaymentIntent(created.clientSecret);
      final processing = Terminal.instance.processPaymentIntent(
        intent,
        skipTipping: true,
      );
      onProcessing?.call(processing);

      PaymentIntent processed;
      try {
        processed = await processing;
      } on TerminalException catch (e) {
        if (e.code == TerminalExceptionCode.canceled) {
          throw StripeServiceException('Оплата отменена'.tr);
        }
        throw StripeServiceException(_mapTerminalError(e));
      }

      final succeeded = processed.status == PaymentIntentStatus.succeeded ||
          processed.status == PaymentIntentStatus.requiresCapture;
      if (!succeeded) {
        throw StripeServiceException(
          '${'Платёж не завершён'.tr} (${processed.status.name}). ${'Попробуйте ещё раз'.tr}.',
        );
      }

      onStatus?.call('Сохраняю оплату в заявку...'.tr);
      return StripeService.completeTerminalPayment(
        paymentIntentId:
            processed.id.isNotEmpty ? processed.id : created.paymentIntentId,
      );
    } finally {
      _statusSink = null;
    }
  }

  /// Только найти и подключить терминал, без списания.
  static Future<String> pairHardwareReader({
    void Function(String status)? onStatus,
  }) async {
    if (!Platform.isAndroid) {
      throw StripeServiceException(
        'Терминал Stripe сейчас подключается на Android.',
      );
    }
    _statusSink = onStatus;
    try {
      onStatus?.call('Разрешаю Bluetooth и геолокацию...'.tr);
      await _requestPermissions(useTerminal: true);
      onStatus?.call('Подключаю Stripe...'.tr);
      final connection = await _ensureReady();
      final locationId = await _resolveLocationId(connection.locationId);
      final reader = await _ensureReaderConnected(
        locationId: locationId,
        simulated: false,
        useTerminal: true,
        onStatus: onStatus,
      );
      final name = _readerName(reader);
      await SettingsService.updateConfig('stripeReaderName', name);
      await SettingsService.updateConfig(
        'stripeReaderHardware',
        reader.deviceType != DeviceType.tapToPay,
      );
      return name;
    } finally {
      _statusSink = null;
    }
  }

  static String _readerName(Reader reader) {
    final label = (reader.label ?? '').trim();
    if (label.isNotEmpty) return label;
    final serial = reader.serialNumber.trim();
    if (serial.isNotEmpty) return serial;
    return reader.deviceType == DeviceType.tapToPay
        ? 'Телефон · Stripe Tap to Pay'
        : 'Терминал Stripe';
  }

  static Future<StripeReaderStatus> currentReaderStatus() async {
    final config = await SettingsService.loadConfig();
    final savedName = (config['stripeReaderName'] ?? '').toString().trim();
    final savedHardware = config['stripeReaderHardware'] == true;
    if (Terminal.isInitialized) {
      try {
        final reader = await Terminal.instance.getConnectedReader();
        if (reader != null) {
          final name = _readerName(reader);
          final hardware = reader.deviceType != DeviceType.tapToPay;
          unawaited(SettingsService.updateConfig('stripeReaderName', name));
          unawaited(
            SettingsService.updateConfig('stripeReaderHardware', hardware),
          );
          return StripeReaderStatus(
            connected: true,
            name: name,
            isHardware: hardware,
          );
        }
      } catch (_) {}
    }
    return StripeReaderStatus(
      connected: false,
      name: savedName,
      isHardware: savedHardware,
    );
  }

  /// Диалог «приложите карту» + сам приём.
  static Future<bool> collectWithDialog({
    required BuildContext context,
    required String jobId,
    required int documentIndex,
    required double amount,
    double tip = 0,
  }) async {
    final config = await SettingsService.loadConfig();
    if (!context.mounted) return false;
    final useTerminal =
        SettingsService.readCardReader(config) == SettingsService.cardReaderTerminal;
    final status = ValueNotifier<String>('Готовлю приём карты...'.tr);
    CancelableFuture<PaymentIntent>? processing;
    var closed = false;

    Future<void> closeDialog() async {
      if (closed || !context.mounted) return;
      closed = true;
      Navigator.of(context, rootNavigator: true).pop();
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(
              useTerminal ? 'Терминал Stripe'.tr : 'Приложите карту'.tr,
            ),
            content: ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (context, text, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      useTerminal ? Icons.point_of_sale : Icons.contactless,
                      size: 64,
                      color: const Color(0xFF635BFF),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '\$${(amount + tip).toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(text, textAlign: TextAlign.center),
                  ],
                );
              },
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  try {
                    await processing?.cancel();
                  } catch (_) {}
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext);
                    closed = true;
                  }
                },
                child: Text('Отмена'.tr),
              ),
            ],
          ),
        );
      },
    );

    try {
      await collectPayment(
        jobId: jobId,
        documentIndex: documentIndex,
        amount: amount,
        tip: tip,
        onStatus: (text) => status.value = text,
        onProcessing: (future) => processing = future,
      );
      await closeDialog();
      return true;
    } on StripeServiceException catch (e) {
      await closeDialog();
      if (context.mounted) {
        debugPrint('Stripe terminal: ${e.message}');
      }
      return false;
    } on TerminalException catch (e) {
      await closeDialog();
      if (context.mounted) {
        debugPrint('Stripe terminal: ${_mapTerminalError(e)}');
      }
      return false;
    } catch (e) {
      await closeDialog();
      if (context.mounted) {
        debugPrint('Stripe terminal: $e');
      }
      return false;
    } finally {
      status.dispose();
    }
  }

  static Future<void> _requestPermissions({required bool useTerminal}) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StripeServiceException(
        'Включите Геолокацию в шторке телефона. Без неё Android не показывает Bluetooth-терминал.'.tr,
      );
    }
    var geo = await Geolocator.checkPermission();
    if (geo == LocationPermission.denied) {
      geo = await Geolocator.requestPermission();
    }
    if (geo == LocationPermission.denied ||
        geo == LocationPermission.deniedForever) {
      throw StripeServiceException(
        'Для приёма карты нужна точная геолокация (требование Stripe Terminal).',
      );
    }
    final needed = <Permission>[
      Permission.locationWhenInUse,
      if (useTerminal) Permission.bluetoothScan,
      if (useTerminal) Permission.bluetoothConnect,
    ];
    final statuses = await needed.request();
    final location = statuses[Permission.locationWhenInUse];
    if (location == PermissionStatus.denied ||
        location == PermissionStatus.permanentlyDenied) {
      throw StripeServiceException(
        'Для приёма карты нужна геолокация (требование Stripe Terminal).',
      );
    }
    if (useTerminal) {
      final scan = statuses[Permission.bluetoothScan];
      final connect = statuses[Permission.bluetoothConnect];
      if (scan == PermissionStatus.denied ||
          connect == PermissionStatus.denied ||
          scan == PermissionStatus.permanentlyDenied ||
          connect == PermissionStatus.permanentlyDenied) {
        throw StripeServiceException(
          'Разрешите «Рядом» / Nearby devices для этого приложения, иначе WisePad 3 не виден.'.tr,
        );
      }
      if (!await _isBluetoothOn()) {
        await _requestBluetoothOn();
        if (!await _isBluetoothOn()) {
          throw StripeServiceException(
            'Включите Bluetooth в шторке телефона и нажмите «Найти терминал» ещё раз.'.tr,
          );
        }
      }
    }
  }

  static Future<StripeTerminalConnection> _ensureReady() async {
    StripeTerminalConnection? connection;
    Future<String> fetchToken() async {
      connection = await StripeService.createConnectionToken();
      return connection!.secret;
    }

    if (!Terminal.isInitialized) {
      await Terminal.init(fetchToken: fetchToken, shouldPrintLogs: true);
    }
    connection ??= await StripeService.createConnectionToken();
    return connection!;
  }

  static const _deviceChannel = MethodChannel('fix_appliance/device');

  static Future<bool> _isBluetoothOn() async {
    try {
      return await _deviceChannel.invokeMethod<bool>('isBluetoothOn') == true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> _requestBluetoothOn() async {
    try {
      await _deviceChannel.invokeMethod<bool>('requestBluetooth');
      await Future<void>.delayed(const Duration(milliseconds: 800));
    } catch (_) {}
  }

  static Future<String> _resolveLocationId(String fallback) async {
    try {
      final locations = await Terminal.instance.listLocations(limit: 20);
      for (final location in locations) {
        final id = (location.id ?? '').trim();
        if (id.isNotEmpty) return id;
      }
    } catch (error) {
      debugPrint('Stripe locations: $error');
    }
    return fallback;
  }

  static Future<Reader> _ensureReaderConnected({
    required String locationId,
    required bool simulated,
    required bool useTerminal,
    void Function(String status)? onStatus,
  }) async {
    final already = await Terminal.instance.getConnectedReader();
    if (already != null) {
      final isTap = already.deviceType == DeviceType.tapToPay;
      if (useTerminal != isTap) return already;
      await Terminal.instance.disconnectReader();
    }

    onStatus?.call(
      useTerminal
          ? 'Ищу WisePad 3. Держите его рядом, индикатор должен мигать. Не сопрягайте его в настройках Android.'.tr
          : (simulated
              ? 'Тестовый режим: сейчас будет симулятор карты'.tr
              : 'Ищу NFC на этом телефоне...'.tr),
    );

    if (useTerminal) {
      return _discoverAndConnectBluetooth(
        locationId: locationId,
        onStatus: onStatus,
      );
    }

    await _discoverSub?.cancel();
    _discoverCompleter = Completer<List<Reader>>();
    _discoverSub = Terminal.instance
        .discoverReaders(TapToPayDiscoveryConfiguration(isSimulated: simulated))
        .listen(
      (readers) {
        if (readers.isEmpty) return;
        final completer = _discoverCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete(readers);
        }
      },
      onError: (Object error, StackTrace stack) {
        final completer = _discoverCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(error, stack);
        }
      },
    );
    List<Reader> readers;
    try {
      readers = await _discoverCompleter!.future.timeout(
        const Duration(seconds: 32),
        onTimeout: () => throw StripeServiceException(
          simulated
              ? 'Не удалось запустить тестовый терминал. Проверьте интернет.'.tr
              : 'Телефон не увидел NFC. Включите NFC в настройках Android.'.tr,
        ),
      );
    } finally {
      await _discoverSub?.cancel();
      _discoverSub = null;
      _discoverCompleter = null;
    }
    try {
      return await Terminal.instance.connectReader(
        readers.first,
        configuration: TapToPayConnectionConfiguration(
          locationId: locationId,
          merchantDisplayName: 'Fix Appliance',
          readerDelegate: _tapDelegate,
        ),
      );
    } on TerminalException catch (e) {
      throw StripeServiceException(_mapTerminalError(e));
    }
  }

  static Future<Reader> _discoverAndConnectBluetooth({
    required String locationId,
    void Function(String status)? onStatus,
  }) async {
    await _discoverSub?.cancel();
    final found = Completer<Reader>();
    _discoverSub = Terminal.instance
        .discoverReaders(
          BluetoothDiscoveryConfiguration(
            isSimulated: false,
            timeoutInSeconds: 0,
          ),
        )
        .listen(
      (readers) {
        if (found.isCompleted || readers.isEmpty) return;
        found.complete(readers.first);
      },
      onError: (Object error, StackTrace stack) {
        if (!found.isCompleted) found.completeError(error, stack);
      },
    );

    Reader discovered;
    try {
      discovered = await found.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw StripeServiceException(
          'WisePad 3 не найден. 1) Забудьте его в Настройки Android → Bluetooth. 2) Не сопрягайте там — только через это приложение. 3) Геолокация точная + Nearby devices. 4) Подержите кнопку питания на ридере, пока не замигает, и держите рядом.'.tr,
        ),
      );
    } catch (error) {
      await _discoverSub?.cancel();
      _discoverSub = null;
      if (error is StripeServiceException) rethrow;
      throw StripeServiceException(_mapUnknown(error));
    }

    onStatus?.call(
      '${'Нашёл'.tr} ${discovered.serialNumber}. ${'Подключаю. Если появится 6‑значный код — подтвердите на телефоне и на WisePad.'.tr}',
    );
    try {
      return await Terminal.instance.connectReader(
        discovered,
        configuration: BluetoothConnectionConfiguration(
          locationId: locationId,
          readerDelegate: _mobileDelegate,
        ),
      );
    } on TerminalException catch (e) {
      throw StripeServiceException(_mapTerminalError(e));
    } finally {
      await _discoverSub?.cancel();
      _discoverSub = null;
    }
  }

  static String _mapUnknown(Object error) {
    if (error is TerminalException) return _mapTerminalError(error);
    return error.toString();
  }

  static String _mapDisplay(ReaderDisplayMessage message) {
    switch (message) {
      case ReaderDisplayMessage.retryCard:
        return 'Повторите карту на терминале'.tr;
      case ReaderDisplayMessage.insertCard:
        return 'Вставьте карту в терминал'.tr;
      case ReaderDisplayMessage.insertOrSwipeCard:
        return 'Вставьте или проведите карту'.tr;
      case ReaderDisplayMessage.swipeCard:
        return 'Проведите карту'.tr;
      case ReaderDisplayMessage.removeCard:
        return 'Выньте карту'.tr;
      case ReaderDisplayMessage.multipleContactlessCardsDetected:
        return 'Рядом несколько карт. Оставьте одну.'.tr;
      case ReaderDisplayMessage.tryAnotherReadMethod:
        return 'Карта не считалась. Попробуйте вставить или провести.'.tr;
      case ReaderDisplayMessage.tryAnotherCard:
        return 'Эта карта не подошла. Попробуйте другую.'.tr;
      case ReaderDisplayMessage.cardRemovedTooEarly:
        return 'Карту вынули слишком рано. Попробуйте снова.'.tr;
      case ReaderDisplayMessage.checkMobileDevice:
        return 'Смотрите инструкции на телефоне'.tr;
    }
  }

  static String _mapInput(List<ReaderInputOption> options) {
    final parts = <String>[];
    for (final option in options) {
      switch (option) {
        case ReaderInputOption.insertCard:
          parts.add('вставить'.tr);
        case ReaderInputOption.swipeCard:
          parts.add('провести'.tr);
        case ReaderInputOption.tapCard:
          parts.add('приложить'.tr);
        case ReaderInputOption.manualEntry:
          break;
      }
    }
    if (parts.isEmpty) return 'Ожидаю карту на терминале'.tr;
    return '${'На терминале'.tr}: ${parts.join(', ')}';
  }

  static String _mapTerminalError(TerminalException error) {
    switch (error.code) {
      case TerminalExceptionCode.canceled:
        return 'Оплата отменена'.tr;
      case TerminalExceptionCode.nfcDisabled:
        return 'Включите NFC в настройках телефона и попробуйте снова.'.tr;
      case TerminalExceptionCode.tapToPayUnsupportedDevice:
        return 'Этот телефон не поддерживает приём карты через NFC.'.tr;
      case TerminalExceptionCode.tapToPayDebugNotSupported:
        return 'Настоящая карта на debug-сборке не принимается. Нужна release-сборка и живые ключи Stripe.'.tr;
      case TerminalExceptionCode.tapToPayInsecureEnvironment:
        return 'Tap to Pay не работает, пока включены параметры разработчика. Выключите их для живых платежей.'.tr;
      case TerminalExceptionCode.tapToPayDeviceTampered:
        return 'Телефон не проходит проверку безопасности Stripe для Tap to Pay.'.tr;
      case TerminalExceptionCode.bluetoothDisabled:
        return 'Включите Bluetooth в шторке телефона.'.tr;
      case TerminalExceptionCode.locationServicesDisabled:
        return 'Включите Геолокацию. Без неё WisePad 3 не находится.'.tr;
      case TerminalExceptionCode.readerNotRecovered:
        return 'Связь с ридером оборвалась. Забудьте WisePad в настройках Android Bluetooth и подключайте только через приложение.'.tr;
      default:
        return error.message.isNotEmpty ? error.message : error.code.name;
    }
  }
}

class _StatusTapToPayDelegate extends TapToPayReaderDelegate {
  @override
  void onStartInstallingUpdate(ReaderSoftwareUpdate update, Cancellable cancelUpdate) {
    StripeTerminalService._emit('Обновляю терминал...'.tr);
  }

  @override
  void onReportReaderSoftwareUpdateProgress(double progress) {}

  @override
  void onFinishInstallingUpdate(ReaderSoftwareUpdate? update, TerminalException? exception) {}

  @override
  void onRequestReaderDisplayMessage(ReaderDisplayMessage message) {
    StripeTerminalService._emit(StripeTerminalService._mapDisplay(message));
  }

  @override
  void onRequestReaderInput(List<ReaderInputOption> options) {
    StripeTerminalService._emit(StripeTerminalService._mapInput(options));
  }
}

class _StatusMobileReaderDelegate extends MobileReaderDelegate {
  @override
  void onReportAvailableUpdate(ReaderSoftwareUpdate update) {}

  @override
  void onStartInstallingUpdate(ReaderSoftwareUpdate update, Cancellable cancelUpdate) {
    StripeTerminalService._emit('Обновляю прошивку терминала...'.tr);
  }

  @override
  void onReportReaderSoftwareUpdateProgress(double progress) {}

  @override
  void onFinishInstallingUpdate(ReaderSoftwareUpdate? update, TerminalException? exception) {}

  @override
  void onRequestReaderDisplayMessage(ReaderDisplayMessage message) {
    StripeTerminalService._emit(StripeTerminalService._mapDisplay(message));
  }

  @override
  void onRequestReaderInput(List<ReaderInputOption> options) {
    StripeTerminalService._emit(StripeTerminalService._mapInput(options));
  }
}
