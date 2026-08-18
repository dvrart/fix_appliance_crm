import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../services/twilio_service.dart';
import '../../services/job_service.dart';
import '../ai/job_preview_screen.dart';
import '../ai/post_call_screen.dart';
import '../../services/ai_service.dart';
import '../jobs/job_details/job_details_screen.dart';
import 'call_screen.dart';
import 'dial_pad_screen.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';

/// Экран истории звонков: звонки, ожидающие проверки данных от ИИ, и общая
/// история всех звонков (входящих и исходящих) через Twilio.
class CallsHistoryScreen extends StatefulWidget {
  final bool embedded;

  const CallsHistoryScreen({super.key, this.embedded = false});

  @override
  State<CallsHistoryScreen> createState() => _CallsHistoryScreenState();
}

class _CallsHistoryScreenState extends State<CallsHistoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final Set<String> _retryingCallIds = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    TwilioService.retryStuckAiCalls();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = TabBar(
      controller: _tabController,
      indicatorColor: AppColors.accent,
      labelColor: widget.embedded ? AppColors.primary : AppColors.accent,
      unselectedLabelColor: widget.embedded ? Colors.grey : Colors.white70,
      tabs: [
        Tab(text: 'К ОБРАБОТКЕ'.tr),
        Tab(text: 'ВСЕ ЗВОНКИ'.tr),
      ],
    );
    final body = TabBarView(
      controller: _tabController,
      children: [_buildPendingReview(), _buildAllCalls()],
    );

    return Scaffold(
      backgroundColor: widget.embedded ? Colors.transparent : null,
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text('Звонки'.tr, style: TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              bottom: tabs,
            ),
      body: widget.embedded
          ? Column(
              children: [
                Material(color: Colors.white, child: tabs),
                Expanded(child: body),
              ],
            )
          : body,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'calls-dial-pad',
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.dialpad),
        label: Text('Набрать номер'.tr),
        onPressed: () => DialPadScreen.open(context),
      ),
    );
  }

  Widget _buildPendingReview() {
    return StreamBuilder<List<CallRecord>>(
      stream: TwilioService.getPendingReviewCalls(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final calls = snapshot.data ?? [];

        if (calls.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_outline, size: 80, color: Colors.green.shade300),
                const SizedBox(height: 16),
                Text(
                  'Все звонки обработаны!'.tr,
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                Text(
                  'После звонка ИИ сам расшифрует разговор\nи заявка появится здесь для проверки'.tr,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: calls.length,
          itemBuilder: (context, index) => _buildPendingCallCard(calls[index]),
        );
      },
    );
  }

  Widget _buildPendingCallCard(CallRecord call) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.accent, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    call.isIncoming ? Icons.phone_callback : Icons.phone_forwarded,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        call.isIncoming ? call.fromNumber : call.toNumber,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        call.startTime != null
                            ? Formatters.formatDateTime(call.startTime)
                            : '',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Новое'.tr,
                    style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
              ],
            ),
            if (call.transcription != null && call.transcription!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  call.transcription!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _skipCall(call),
                    icon: const Icon(Icons.skip_next),
                    label: Text('Пропустить'.tr),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.grey),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _reviewCall(call),
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(
                      call.createdJobId != null ? 'Открыть заявку'.tr : 'Создать заявку'.tr,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
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

  Future<void> _reviewCall(CallRecord call) async {
    if (call.createdJobId != null && call.createdJobId!.isNotEmpty) {
      final job = await JobService.getById(call.createdJobId!);
      if (!mounted) return;
      if (job != null) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => JobDetailsScreen(
              jobId: job.id,
              clientId: job.clientId,
              jobData: job.toMap(),
            ),
          ),
        );
        return;
      }
    }

    ExtractedJobData extractedData;

    if (call.extractedData != null && call.extractedData!.isNotEmpty) {
      // ИИ уже извлёк данные на сервере сразу из записи разговора.
      extractedData = ExtractedJobData.fromJson(call.extractedData!);
    } else if (call.transcription != null && call.transcription!.isNotEmpty) {
      // Запасной путь — если по какой-то причине сервер не извлёк данные,
      // но транскрипция есть, извлекаем их прямо в приложении.
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('ИИ анализирует разговор...'.tr),
                ],
              ),
            ),
          ),
        ),
      );
      try {
        extractedData = await AiService.extractJobData(call.transcription!);
      } catch (e) {
        if (mounted) Navigator.pop(context);
        _showError('${'Ошибка ИИ'.tr}: $e');
        return;
      }
      if (mounted) Navigator.pop(context);
    } else {
      if (!mounted) return;
      final dictated = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const PostCallScreen()),
      );
      if (dictated == true) {
        await TwilioService.markReviewed(call.id);
      }
      return;
    }

    if (!mounted) return;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => JobPreviewScreen(
          extractedData: extractedData,
          originalText: call.transcription ?? '',
          fallbackPhone: call.isIncoming ? call.fromNumber : call.toNumber,
        ),
      ),
    );

    if (result == true) {
      await TwilioService.markReviewed(call.id);
    }
  }

  Future<void> _skipCall(CallRecord call) async {
    await TwilioService.markReviewed(call.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Звонок пропущен'.tr)));
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  Widget _buildAllCalls() {
    return StreamBuilder<List<CallRecord>>(
      stream: TwilioService.getAllCalls(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final calls = snapshot.data ?? [];

        if (calls.isEmpty) {
          return Center(child: Text('Нет звонков'.tr, style: TextStyle(color: Colors.grey)));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: calls.length,
          itemBuilder: (context, index) => _buildCallHistoryCard(calls[index]),
        );
      },
    );
  }

  Widget _buildCallHistoryCard(CallRecord call) {
    final isIncoming = call.isIncoming;
    final duration = call.durationSeconds != null
        ? '${call.durationSeconds! ~/ 60}:${(call.durationSeconds! % 60).toString().padLeft(2, '0')}'
        : '-';

    final (Color statusColor, String statusText) = _statusInfo(call);
    final hasRecording = (call.recordingUrl ?? '').isNotEmpty;
    final connected = (call.durationSeconds ?? 0) > 0;
    final canRetryAi = call.aiStatus == 'error' && (hasRecording || connected);
    final isRetrying = _retryingCallIds.contains(call.id);
    final phone = isIncoming ? call.fromNumber : call.toNumber;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isIncoming ? Colors.green.shade50 : Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                isIncoming ? Icons.call_received : Icons.call_made,
                color: isIncoming ? Colors.green : Colors.blue,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: phone.trim().isEmpty
                    ? null
                    : () => CallScreen.open(context, phoneNumber: phone),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2, right: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        phone,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        call.startTime != null
                            ? '${Formatters.formatDayTime(call.startTime)} • $duration'
                            : duration,
                        style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isRetrying ? 'ИИ обрабатывает'.tr : statusText,
                    style: TextStyle(
                      color: isRetrying ? Colors.purple : statusColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (canRetryAi && !isRetrying)
                  TextButton(
                    onPressed: () => _retryAi(call),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(
                      'Повторить ИИ'.tr,
                      style: const TextStyle(
                        fontSize: 11,
                        decoration: TextDecoration.underline,
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

  Future<void> _retryAi(CallRecord call) async {
    if (_retryingCallIds.contains(call.id)) return;
    setState(() => _retryingCallIds.add(call.id));
    try {
      await TwilioService.retryAiProcessing(call.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ИИ запущен повторно'.tr)),
      );
    } catch (e) {
      if (!mounted) return;
      _showError('Не удалось запустить ИИ'.tr);
    } finally {
      if (mounted) {
        setState(() => _retryingCallIds.remove(call.id));
      }
    }
  }

  (Color, String) _statusInfo(CallRecord call) {
    if (call.aiStatus == 'processing') return (Colors.purple, 'ИИ обрабатывает'.tr);
    if (call.aiStatus == 'error') return (Colors.red, 'Ошибка ИИ'.tr);
    if (call.reviewed) return (Colors.green, 'Обработан'.tr);
    if (call.aiStatus == 'done') return (Colors.orange, 'Ожидает проверки'.tr);

    if (call.answeredBy == 'ai') return (Colors.deepPurple, 'ИИ ответил'.tr);

    switch (call.status) {
      case 'completed':
        return (Colors.blue, 'Завершён'.tr);
      case 'no-answer':
        return (Colors.grey, 'Без ответа'.tr);
      case 'busy':
        return (Colors.grey, 'Занято'.tr);
      case 'failed':
        return (Colors.red, 'Не удался'.tr);
      case 'ringing':
        return (Colors.amber, 'Звонит'.tr);
      case 'in-progress':
        return (Colors.blue, 'В процессе'.tr);
      default:
        return (Colors.grey, call.status);
    }
  }
}
