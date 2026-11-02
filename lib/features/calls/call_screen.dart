import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:twilio_voice/twilio_voice.dart';
import '../../core/app_commands.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/motion.dart';
import '../../models/client.dart';
import '../../services/call_routing.dart';
import '../../services/client_service.dart';
import '../../services/twilio_service.dart';
import '../../core/l10n/app_locale.dart';
import '../care_plan/care_plan_widgets.dart';

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

  /// Экран звонка на экране прямо сейчас. Не даём положить второй сверху:
  /// прямой вызов из карточки и `GlobalCallListener` иначе могли открыть
  /// два экрана на один разговор, и при завершении оба анимировались разом.
  static bool _shown = false;
  static bool get isShown => _shown;

  static Future<T?> open<T>(
    BuildContext context, {
    required String phoneNumber,
    String? contactName,
    bool isIncoming = false,
    String? jobId,
    bool resumeExisting = false,
  }) async {
    if (_shown) return null;
    _shown = true;
    if (!isIncoming) AppFeedback.pleasant();
    try {
      final navigator =
          rootNavigatorKey.currentState ??
          Navigator.of(context, rootNavigator: true);
      return await navigator.push<T>(
        PageRouteBuilder<T>(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 360),
          reverseTransitionDuration: const Duration(milliseconds: 420),
          pageBuilder: (_, animation, _) => CallScreen(
            phoneNumber: phoneNumber,
            contactName: contactName,
            isIncoming: isIncoming,
            jobId: jobId,
            resumeExisting: resumeExisting,
          ),
          transitionsBuilder: (_, animation, _, child) {
            // Только прозрачность и лёгкий масштаб по центру — никакого
            // сдвига в сторону ни на открытии, ни на закрытии.
            final curved = CurvedAnimation(
              parent: animation,
              curve: AppMotion.enter,
              reverseCurve: AppMotion.exit,
            );
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
                child: child,
              ),
            );
          },
        ),
      );
    } finally {
      _shown = false;
    }
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
      await Future<void>.delayed(const Duration(milliseconds: 260));
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
        current == 'connected' ||
        current == 'answering' ||
        current == 'reconnecting' ||
        current == 'audioFailed' ||
        current == 'movingToCell') {
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
      } else if (status == 'movedToCell' || status == 'cell') {
        // Дальше разговор идёт обычным звонком SIM — экран успевает сказать,
        // что делать, и уходит.
        _stopDurationTimer();
        Future.delayed(const Duration(seconds: 3), () {
          unawaited(_softClose(true));
        });
      } else if (status == 'ended' || status == 'failed') {
        _stopDurationTimer();
        if (status == 'failed') {
          if (_offerCellAfterFailure) return;
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

  /// Исходящий из приложения не дозвонился, а SIM указан: вместо тихого
  /// закрытия экран предлагает позвонить этому клиенту через сотовую связь.
  bool get _offerCellAfterFailure =>
      !widget.isIncoming &&
      TwilioService.routing.hasCell &&
      TwilioService.routing.effective == CallRoute.app;

  void _startDurationTimer() {
    // После «связь восстановлена» таймер продолжает, а не начинает с нуля.
    if (_durationTimer != null) return;
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
      case 'answering':
        return 'Соединяю звук…'.tr;
      case 'connected':
        return _formatDuration(_callDuration);
      case 'reconnecting':
        return 'Связь прервалась'.tr;
      case 'audioFailed':
        return 'Звук не соединился'.tr;
      case 'movingToCell':
        return 'Перевожу на обычный телефон…'.tr;
      case 'movedToCell':
        return 'Звонок переведён на SIM'.tr;
      case 'cell':
        return 'Звоню через сотовую связь…'.tr;
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
      // Мёртвый инвайт не даёт даже «Ответить». Если ответ дошёл и ждём
      // звук, это решает TwilioService: «Соединяю звук…» или переход на SIM.
      if (_callStatus != 'ringing') return;
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
    CallScreen._shown = false;
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
    final isHandover = const {
      'cell',
      'movingToCell',
      'movedToCell',
    }.contains(_callStatus);
    final showInCallControls = !isEnded &&
        !isRingingIncoming &&
        !isHandover &&
        _callStatus != 'audioFailed';

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
          // Scaffold даёт body только maxWidth, а Column берёт ширину самого
          // широкого ребёнка. Пока на экране есть Row с кнопками — это вся
          // ширина; в момент «Звонок завершён» Row пропадал, Column сжимался
          // до ширины номера и прилипал к левому краю — экран «уезжал влево».
          body: SizedBox.expand(
            child: DecoratedBox(
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
              Builder(
                builder: (context) {
                  final cleanName = Client.stripClientWord(widget.contactName);
                  final hasRealName =
                      cleanName.isNotEmpty &&
                      !Client.isPlaceholderName(cleanName);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: _showKeypad ? 28 : 64,
                        backgroundColor: Colors.white.withValues(alpha: 0.16),
                        child: Text(
                          hasRealName ? cleanName[0].toUpperCase() : '?',
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
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                hasRealName ? cleanName : widget.phoneNumber,
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
                            if (ClientService.isRegularClient(
                              phone: widget.phoneNumber,
                            ))
                              RegularClientStar(
                                size: _showKeypad ? 20 : 26,
                                onDark: true,
                                padding: const EdgeInsets.only(left: 6),
                              ),
                          ],
                        ),
                      ),
                      if (hasRealName && !_showKeypad) ...[
                        const SizedBox(height: 8),
                        Text(
                          widget.phoneNumber,
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                      // Звонит клиент на Care Plan — гарантийный вызов.
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: CarePlanCallBadge(
                          phone: widget.phoneNumber,
                          compact: _showKeypad,
                        ),
                      ),
                    ],
                  );
                },
              ),
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
              _buildSignalBanner(),
              if (!_showKeypad) const Spacer(),
              if (showInCallControls && _showKeypad) ...[
                const Spacer(),
                _buildKeypad(),
                const SizedBox(height: 10),
              ],
              if (!isRingingIncoming)
                _fade(
                  visible: showInCallControls,
                  child: Padding(
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
              else if (_callStatus == 'failed' && _offerCellAfterFailure)
                _buildFailedActions()
              else
                _fade(
                  visible: !isEnded && !isHandover,
                  child: Padding(
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
                ),
              SizedBox(height: _showKeypad ? 12 : 36),
            ],
                ),
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }

  /// Что сейчас со звуком — словами, чтобы мастер понимал, слышит ли его
  /// клиент (просьба FIX, 27.10.2026).
  Widget _buildSignalBanner() {
    return ValueListenableBuilder<Set<CallQualityWarning>>(
      valueListenable: TwilioService.qualityWarnings,
      builder: (context, warnings, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: TwilioService.peerAnswered,
          builder: (context, peerAnswered, _) {
            final banner = _signalBanner(warnings, peerAnswered);
            if (banner == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: banner,
            );
          },
        );
      },
    );
  }

  Widget? _signalBanner(Set<CallQualityWarning> warnings, bool peerAnswered) {
    const red = Color(0xFFE53935);
    const green = Color(0xFF2E7D32);
    switch (_callStatus) {
      case 'answering':
        return _notice(
          Icons.hourglass_top,
          'Клиент вас пока не слышит — жду звук'.tr,
          const Color(0xFF5C6BC0),
        );
      case 'reconnecting':
        return _notice(
          Icons.wifi_off,
          'Пропал интернет — клиент вас сейчас не слышит. Восстанавливаю связь…'.tr,
          red,
        );
      case 'audioFailed':
        return _audioFailedNotice();
      case 'movingToCell':
      case 'movedToCell':
        return _notice(
          Icons.sim_card,
          'Сейчас зазвонит обычный телефон. Ответьте и нажмите 1 — вы соединитесь с клиентом.'.tr,
          green,
        );
      case 'cell':
        final note = TwilioService.handoverNote;
        return _notice(
          Icons.sim_card,
          '${note == null ? '' : '${note.tr}. '}${'Клиент увидит номер мастерской.'.tr}',
          green,
        );
      case 'connected':
        if (!_isMuted &&
            warnings.contains(CallQualityWarning.constantAudioInputLevel)) {
          return _notice(
            Icons.mic_off,
            'Микрофон не передаёт звук — клиент вас не слышит'.tr,
            red,
          );
        }
        if (warnings.any((w) => const {
              CallQualityWarning.highPacketLoss,
              CallQualityWarning.lowMos,
              CallQualityWarning.highJitter,
              CallQualityWarning.highRtt,
            }.contains(w))) {
          return _notice(
            Icons.network_check,
            'Слабый интернет — клиент может вас плохо слышать'.tr,
            const Color(0xFFF9A825),
          );
        }
        if (!widget.isIncoming && peerAnswered) {
          return _notice(Icons.check_circle, 'Клиент на линии'.tr, green);
        }
        return null;
      default:
        return null;
    }
  }

  Widget _audioFailedNotice() {
    final canMove = TwilioService.routing.hasCell;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _notice(
          Icons.error_outline,
          'Звук не соединился — клиент вас не слышит. Слабый интернет на телефоне.'.tr,
          const Color(0xFFE53935),
        ),
        const SizedBox(height: 10),
        if (canMove)
          _buildWideAction(
            icon: Icons.sim_card,
            label: 'Перевести на обычный телефон'.tr,
            color: const Color(0xFF2EBD59),
            onTap: () => unawaited(TwilioService.moveIncomingToCell()),
          )
        else
          Text(
            'Положите трубку и перезвоните с обычного телефона.'.tr,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
      ],
    );
  }

  Widget _notice(IconData icon, String text, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFailedActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          _buildWideAction(
            icon: Icons.sim_card,
            label: 'Позвонить через сотовую связь'.tr,
            color: const Color(0xFF2EBD59),
            onTap: _callViaCell,
          ),
          const SizedBox(height: 14),
          _buildWideAction(
            icon: Icons.close,
            label: 'Закрыть'.tr,
            color: Colors.white24,
            onTap: () => unawaited(_softClose(false)),
          ),
        ],
      ),
    );
  }

  Future<void> _callViaCell() async {
    HapticFeedback.mediumImpact();
    await TwilioService.placeViaCell(widget.phoneNumber, jobId: widget.jobId);
  }

  Widget _buildWideAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  /// Кнопки после отбоя не выдёргиваем из разметки, а гасим: иначе Column
  /// перестраивается и всё содержимое прыгает вверх за миг до закрытия.
  Widget _fade({required bool visible, required Widget child}) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: child,
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
