import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:twilio_voice/twilio_voice.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../services/twilio_service.dart';
import '../../core/l10n/app_locale.dart';

/// Экран активного звонка (исходящего или входящего).
class CallScreen extends StatefulWidget {
  final String phoneNumber;
  final String? contactName;
  final bool isIncoming;
  final String? jobId;
  final bool resumeExisting;

  const CallScreen({
    super.key,
    required this.phoneNumber,
    this.contactName,
    this.isIncoming = false,
    this.jobId,
    this.resumeExisting = false,
  });

  static Future<T?> open<T>(
    BuildContext context, {
    required String phoneNumber,
    String? contactName,
    bool isIncoming = false,
    String? jobId,
    bool resumeExisting = false,
  }) {
    if (!isIncoming) AppFeedback.pleasant();
    return Navigator.of(context, rootNavigator: true).push<T>(
      PageRouteBuilder<T>(
        opaque: false,
        fullscreenDialog: false,
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 520),
        pageBuilder: (_, animation, _) => CallScreen(
          phoneNumber: phoneNumber,
          contactName: contactName,
          isIncoming: isIncoming,
          jobId: jobId,
          resumeExisting: resumeExisting,
        ),
        transitionsBuilder: (_, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: child,
          );
        },
      ),
    );
  }

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  String _callStatus = 'connecting';
  Duration _callDuration = Duration.zero;
  Timer? _durationTimer;
  Timer? _answerWatch;
  bool _isMuted = false;
  bool _isSpeaker = false;
  bool _showKeypad = false;
  bool _handoffBusy = false;
  bool _popped = false;
  bool _closing = false;
  StreamSubscription? _statusSubscription;

  void _popOnce([bool? result]) {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.pop(context, result);
  }

  Future<void> _softClose([bool? result]) async {
    if (_closing || _popped || !mounted) return;
    _closing = true;
    if (_callStatus != 'ended' && _callStatus != 'failed') {
      setState(() => _callStatus = 'ended');
      await Future<void>.delayed(const Duration(milliseconds: 160));
    }
    if (!mounted || _popped) return;
    _popOnce(result);
  }

  @override
  void initState() {
    super.initState();
    _callStatus = _initialStatus();
    _initCall();
  }

  String _initialStatus() {
    final current = TwilioService.callStatus;
    if (current == 'ended' || current == 'failed' || current == 'idle') {
      if (widget.isIncoming) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _popOnce(false));
      }
      return current == 'idle' ? 'ended' : current;
    }
    if (current == 'ringing' ||
        current == 'calling' ||
        current == 'connecting' ||
        current == 'connected') {
      return current;
    }
    return widget.isIncoming ? 'ringing' : 'connecting';
  }

  void _initCall() {
    _statusSubscription = TwilioService.callStatusStream.listen((status) {
      if (!mounted) return;
      setState(() => _callStatus = status);

      if (status == 'connected') {
        _answerWatch?.cancel();
        _startDurationTimer();
        if (!_isSpeaker) unawaited(TwilioService.preferCarAudio());
      } else if (status == 'ended' || status == 'failed') {
        _stopDurationTimer();
        if (status == 'failed') {
          Future.delayed(const Duration(milliseconds: 1800), () {
            unawaited(_softClose(true));
          });
        } else {
          unawaited(_softClose(true));
        }
      }
    });

    if (_callStatus == 'connected') {
      _startDurationTimer();
      if (!_isSpeaker) unawaited(TwilioService.preferCarAudio());
    }

    if (!widget.isIncoming && !widget.resumeExisting) {
      unawaited(TwilioService.makeCall(widget.phoneNumber, jobId: widget.jobId));
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _callDuration = Duration.zero;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _callDuration += const Duration(seconds: 1));
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return duration.inHours > 0
        ? '$hours:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  String _getStatusText() {
    switch (_callStatus) {
      case 'connecting':
        return 'Соединение...'.tr;
      case 'calling':
        return 'Вызов...'.tr;
      case 'ringing':
        return widget.isIncoming ? 'Входящий звонок'.tr : 'Вызов...'.tr;
      case 'connected':
        return _formatDuration(_callDuration);
      case 'ended':
        return 'Звонок завершён'.tr;
      case 'failed':
        final detail = TwilioService.lastPlaceError;
        if (detail != null && detail.trim().isNotEmpty) {
          return '${'Не удалось соединиться'.tr}\n$detail';
        }
        return 'Не удалось соединиться'.tr;
      default:
        return _callStatus;
    }
  }

  Future<void> _toggleMute() async {
    HapticFeedback.lightImpact();
    try {
      final muted = await TwilioService.toggleMute();
      if (mounted) setState(() => _isMuted = muted);
    } catch (e) {
      debugPrint('CallScreen mute: $e');
    }
  }

  Future<void> _toggleSpeaker() async {
    HapticFeedback.lightImpact();
    final wantSpeaker = !_isSpeaker;
    if (mounted) setState(() => _isSpeaker = wantSpeaker);
    try {
      await TwilioService.setSpeaker(wantSpeaker);
    } catch (e) {
      debugPrint('CallScreen speaker: $e');
      if (mounted) setState(() => _isSpeaker = !wantSpeaker);
    }
  }

  Future<void> _sendDigit(String digit) async {
    HapticFeedback.selectionClick();
    try {
      await TwilioService.sendDigits(digit);
    } catch (e) {
      debugPrint('CallScreen digit: $e');
    }
  }

  Future<void> _hangUp() async {
    HapticFeedback.mediumImpact();
    await TwilioService.hangUp();
    await _softClose(true);
  }

  Future<void> _acceptCall() async {
    await TwilioService.answerIncomingCall();
    _answerWatch?.cancel();
    _answerWatch = Timer(const Duration(seconds: 3), () {
      if (!mounted || _popped) return;
      if (_callStatus == 'connected') return;
      debugPrint('CallScreen: answer did not connect — dropping stale invite');
      unawaited(_hangUp());
    });
  }

  Future<void> _rejectCall() async {
    HapticFeedback.mediumImpact();
    await TwilioService.declineIncoming(phoneNumber: widget.phoneNumber);
    await _softClose(false);
  }

  Future<void> _sendToAi() async {
    if (_handoffBusy) return;
    HapticFeedback.mediumImpact();
    setState(() => _handoffBusy = true);
    try {
      await TwilioService.sendToAiSecretary(phoneNumber: widget.phoneNumber);
      await _softClose(false);
    } catch (e) {
      debugPrint('CallScreen sendToAi: $e');
      if (mounted) setState(() => _handoffBusy = false);
    }
  }

  @override
  void dispose() {
    _stopDurationTimer();
    _answerWatch?.cancel();
    _statusSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _callStatus == 'connected';
    final isEnded = _callStatus == 'ended' || _callStatus == 'failed';
    final isRingingIncoming = widget.isIncoming && _callStatus == 'ringing';
    final showInCallControls = !isEnded && !isRingingIncoming;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _popped = true;
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF071018),
          body: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0B1B3A),
                  Color(0xFF12325C),
                  Color(0xFF071018),
                ],
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(context).top + 12,
                ),
                child: Column(
            children: [
              if (!_showKeypad) const Spacer(flex: 2),
              CircleAvatar(
                radius: _showKeypad ? 28 : 64,
                backgroundColor: Colors.white.withValues(alpha: 0.16),
                child: Text(
                  widget.contactName?.isNotEmpty == true
                      ? widget.contactName![0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    fontSize: _showKeypad ? 22 : 48,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              SizedBox(height: _showKeypad ? 8 : 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  widget.contactName ?? widget.phoneNumber,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _showKeypad ? 20 : 30,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              if (widget.contactName != null && !_showKeypad) ...[
                const SizedBox(height: 8),
                Text(
                  widget.phoneNumber,
                  style: const TextStyle(fontSize: 16, color: Colors.white70),
                ),
              ],
              SizedBox(height: _showKeypad ? 8 : 16),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                decoration: BoxDecoration(
                  color: isConnected
                      ? const Color(0x6632D74B)
                      : Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _getStatusText(),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              if (!_showKeypad) const Spacer(),
              if (showInCallControls && _showKeypad) ...[
                const Spacer(),
                _buildKeypad(),
                const SizedBox(height: 10),
              ],
              if (showInCallControls)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildControlButton(
                        icon: _isMuted ? Icons.mic_off : Icons.mic,
                        label: _isMuted ? 'Микрофон выкл'.tr : 'Микрофон'.tr,
                        fill: _isMuted
                            ? const Color(0xFFE53935)
                            : const Color(0xFF25D366),
                        iconColor: Colors.white,
                        onTap: _toggleMute,
                      ),
                      _buildControlButton(
                        icon: Icons.dialpad,
                        label: 'Цифры'.tr,
                        isActive: _showKeypad,
                        onTap: () => setState(() => _showKeypad = !_showKeypad),
                      ),
                      _buildControlButton(
                        icon: _isSpeaker ? Icons.volume_up : Icons.phone_in_talk,
                        label: _isSpeaker ? 'Динамик'.tr : 'Трубка'.tr,
                        fill: const Color(0xFF25D366),
                        iconColor: Colors.white,
                        onTap: _toggleSpeaker,
                      ),
                    ],
                  ),
                ),
              SizedBox(height: _showKeypad ? 12 : 28),
              if (isRingingIncoming)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    children: [
                      _buildAiHandoffButton(
                        title: 'Передать секретарю'.tr,
                        subtitle: 'Ответит на звонок за вас'.tr,
                        enabled: !_handoffBusy,
                        onTap: _sendToAi,
                      ),
                      const SizedBox(height: 28),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildActionButton(
                            icon: Icons.call_end,
                            color: const Color(0xFFE53935),
                            onTap: _rejectCall,
                          ),
                          _buildActionButton(
                            icon: Icons.call,
                            color: const Color(0xFF2EBD59),
                            onTap: _acceptCall,
                          ),
                        ],
                      ),
                    ],
                  ),
                )
              else if (!isEnded)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    children: [
                      if (widget.isIncoming && !_showKeypad)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 22),
                          child: _buildAiHandoffButton(
                            title: 'Переключить на ИИ'.tr,
                            subtitle: 'Секретарь продолжит разговор'.tr,
                            enabled: !_handoffBusy,
                            onTap: _sendToAi,
                          ),
                        ),
                      _buildActionButton(
                        icon: Icons.call_end,
                        color: const Color(0xFFE53935),
                        onTap: _hangUp,
                      ),
                    ],
                  ),
                ),
              SizedBox(height: _showKeypad ? 12 : 36),
            ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['*', '0', '#'],
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 248),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      for (var i = 0; i < row.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(
                          child: Center(
                            child: _buildDigitButton(row[i], size: 52),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDigitButton(String digit, {double size = 56}) {
    return Material(
      color: Colors.white.withValues(alpha: 0.16),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _sendDigit(digit),
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: Text(
              digit,
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isActive = false,
    Color? fill,
    Color? iconColor,
  }) {
    final background = fill ??
        (isActive ? Colors.white : Colors.white.withValues(alpha: 0.2));
    final glyph = iconColor ?? (isActive ? AppColors.primary : Colors.white);
    return Column(
      children: [
        Material(
          color: background,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 64,
              height: 64,
              child: Icon(
                icon,
                color: glyph,
                size: 28,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildAiHandoffButton({
    required String title,
    required String subtitle,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: enabled ? onTap : null,
        child: Ink(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              colors: enabled
                  ? const [Color(0xFF7C4DFF), Color(0xFF00B8D4)]
                  : const [Color(0x667C4DFF), Color(0x6600B8D4)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7C4DFF).withValues(alpha: 0.45),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 18, 14),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: enabled
                      ? const Icon(Icons.auto_awesome, color: Colors.white, size: 26)
                      : const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        enabled ? title : 'Соединяю с секретарём...'.tr,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.82),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: Colors.white.withValues(alpha: 0.85),
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      elevation: 8,
      shadowColor: color.withValues(alpha: 0.4),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 76,
          height: 76,
          child: Icon(icon, color: Colors.white, size: 34),
        ),
      ),
    );
  }
}

String activeCallDisplayNumber(ActiveCall call) {
  return call.callDirection == CallDirection.incoming
      ? call.fromFormatted
      : call.toFormatted;
}
