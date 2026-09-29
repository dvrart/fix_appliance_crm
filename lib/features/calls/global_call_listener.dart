import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:twilio_voice/twilio_voice.dart';
import '../../services/services.dart';
import 'call_screen.dart';

/// Оборачивает всё приложение и следит за событиями Twilio Voice: если
/// приходит входящий звонок, пока приложение открыто на любом экране,
/// автоматически показывает экран звонка. Если мастер ушёл со экрана,
/// звонок продолжается — шторка возвращает на разговор.
class GlobalCallListener extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  const GlobalCallListener({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  @override
  State<GlobalCallListener> createState() => _GlobalCallListenerState();
}

class _GlobalCallListenerState extends State<GlobalCallListener>
    with WidgetsBindingObserver {
  StreamSubscription<MethodCall>? _nativeSubscription;
  StreamSubscription<CallEvent>? _subscription;
  StreamSubscription<String>? _statusSub;
  Timer? _incomingDebounce;
  bool _callScreenShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = TwilioService.callEventStream.listen(_onCallEvent);
    _statusSub = TwilioService.callStatusStream.listen(_onCallStatus);
    _nativeSubscription = NotificationService.nativeEvents.listen(_onNative);
    NotificationService.bindNativeEvents();
    _start();
  }

  Future<void> _onNative(MethodCall call) async {
    if (call.method == 'resumeActiveCall') {
      await _openActiveCallScreen(resume: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_onAppResumed());
  }

  Future<void> _onAppResumed() async {
    unawaited(NotificationService.initialize());
    unawaited(TwilioService.refreshRegistration());
    final dropped = await TwilioService.dropStaleIncomingIfNeeded();
    if (!mounted || dropped) return;
    await _openActiveCallScreen(resume: true);
  }

  Future<void> _start() async {
    await TwilioService.initialize();
    if (!mounted) return;
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration(milliseconds: i == 0 ? 400 : 280));
      if (!mounted) return;
      final dropped = await TwilioService.dropStaleIncomingIfNeeded();
      if (dropped) return;
      if (_isLive(TwilioService.callStatus) ||
          TwilioService.activeCall != null) {
        await _openActiveCallScreen(resume: true);
        return;
      }
    }
  }

  bool _isLive(String status) {
    return status == 'connected' ||
        status == 'calling' ||
        status == 'connecting' ||
        status == 'ringing';
  }

  void _onCallStatus(String status) {
    if (status == 'connected') {
      unawaited(TwilioService.preferCarAudio());
    }
    if (_isLive(status)) {
      final call = TwilioService.activeCall;
      final phone = call == null
          ? ''
          : (call.callDirection == CallDirection.incoming
                ? TwilioService.displayIncomingNumber(call)
                : activeCallDisplayNumber(call));
      unawaited(LocalNotificationService.showActiveCall(phone: phone));
    } else {
      unawaited(LocalNotificationService.cancelActiveCall());
    }
  }

  void _onCallEvent(CallEvent event) {
    if (TwilioService.placingOutgoing) return;

    if (event == CallEvent.callEnded ||
        event == CallEvent.missedCall ||
        event == CallEvent.declined) {
      _incomingDebounce?.cancel();
      return;
    }

    if (_callScreenShown) return;

    final isIncomingRing =
        event == CallEvent.incoming || event == CallEvent.ringing;
    final isIncomingActive =
        event == CallEvent.connected || event == CallEvent.answer;

    if (isIncomingRing) {
      _incomingDebounce?.cancel();
      _incomingDebounce = Timer(const Duration(milliseconds: 400), () {
        unawaited(_openActiveCallScreen());
      });
      return;
    }

    if (isIncomingActive) {
      unawaited(_openActiveCallScreen());
    }
  }

  Future<void> _openActiveCallScreen({bool resume = false}) async {
    if (!mounted ||
        _callScreenShown ||
        CallScreen.isShown ||
        !_isLive(TwilioService.callStatus)) {
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      return;
    }
    _callScreenShown = true;
    try {
      if (await TwilioService.dropStaleIncomingIfNeeded()) return;
      if (!mounted || !_isLive(TwilioService.callStatus)) return;
      final activeCall =
          TwilioService.activeCall ??
          TwilioVoicePlatform.instance.call.activeCall;
      if (activeCall == null) return;
      final isIncoming = activeCall.callDirection == CallDirection.incoming;
      if (!resume && !isIncoming && TwilioService.placingOutgoing) return;
      final navigator = widget.navigatorKey.currentState;
      if (navigator == null) return;
      await _openCallScreen(
        navigator,
        activeCall,
        isIncoming: isIncoming,
        resumeExisting: true,
      );
    } finally {
      _callScreenShown = false;
    }
  }

  Future<void> _openCallScreen(
    NavigatorState navigator,
    ActiveCall activeCall, {
    required bool isIncoming,
    required bool resumeExisting,
  }) async {
    var phone = isIncoming
        ? TwilioService.displayIncomingNumber(activeCall)
        : activeCallDisplayNumber(activeCall);
    final sid = TwilioService.parentCallSid(activeCall);
    if (isIncoming &&
        phone.replaceAll(RegExp(r'\D'), '').length < 10 &&
        sid != null) {
      phone = await _inboundCaller(sid) ?? phone;
    }
    final name = await _resolveContactName(phone);
    if (!mounted || !navigator.mounted || !_isLive(TwilioService.callStatus)) {
      return;
    }
    if (sid != null && TwilioService.parentCallSid() != sid) return;
    await CallScreen.open(
      navigator.context,
      phoneNumber: phone,
      contactName: name,
      isIncoming: isIncoming,
      resumeExisting: resumeExisting,
    );
  }

  Future<String?> _inboundCaller(String callSid) async {
    try {
      final snapshot = await FirestoreService.callsRef
          .doc(callSid)
          .get()
          .timeout(const Duration(seconds: 1));
      if (!snapshot.exists) return null;
      final from = (snapshot.data() as Map)['fromNumber']?.toString() ?? '';
      return from.isEmpty ? null : from;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveContactName(String phone) async {
    try {
      final normalized = SmsService.normalizePhone(phone);
      if (normalized.isEmpty) return null;
      final clients = await ClientService.streamAll().first.timeout(
        const Duration(seconds: 1),
      );
      for (final c in clients) {
        if (SmsService.normalizePhone(c.phone) == normalized) return c.fullName;
      }
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingDebounce?.cancel();
    _subscription?.cancel();
    _statusSub?.cancel();
    _nativeSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
