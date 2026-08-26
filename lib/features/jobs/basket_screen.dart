import 'package:flutter/material.dart';

import '../../core/app_commands.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../core/utils/formatters.dart';
import '../../models/client.dart';
import '../../models/job.dart';
import '../../services/client_service.dart';
import '../../services/job_service.dart';
import '../../services/sms_service.dart';
import '../../services/twilio_service.dart';
import '../../shared/widgets/job_agenda_card.dart';
import 'job_details/job_details_screen.dart';

/// Недавно удалённые заявки и клиенты: 30 дней на восстановление.
class BasketScreen extends StatefulWidget {
  const BasketScreen({super.key});

  @override
  State<BasketScreen> createState() => _BasketScreenState();
}

class _BasketScreenState extends State<BasketScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    JobService.purgeExpiredTrash();
    ClientService.purgeExpiredTrash();
    SmsService.purgeExpiredTrash();
    TwilioService.purgeExpiredTrash();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _restoreJob(Job job) async {
    await JobService.restore(job.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('Заявка восстановлена', 'Job restored'))),
    );
  }

  Future<void> _restoreClient(Client client) async {
    await ClientService.restore(client.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('Клиент восстановлен', 'Client restored'))),
    );
  }

  Future<void> _forgetJob(Job job) async {
    final ok = await _confirmForever(
      context.tr('Удалить заявку навсегда?', 'Delete this job forever?'),
    );
    if (ok != true) return;
    AppCommands.reactAngry();
    await JobService.deleteForever(job.id);
  }

  Future<void> _forgetClient(Client client) async {
    final ok = await _confirmForever(
      context.tr('Удалить клиента навсегда?', 'Delete this client forever?'),
    );
    if (ok != true) return;
    AppCommands.reactAngry();
    await ClientService.deleteForever(client.id);
  }

  Future<bool?> _confirmForever(String title) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(
          context.tr(
            'Это уже нельзя будет отменить.',
            'This cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Отмена', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: Text(context.tr('Удалить навсегда', 'Delete forever')),
          ),
        ],
      ),
    );
  }

  String _daysLeft(int days) {
    if (days <= 0) {
      return context.tr('Скоро удалится', 'Will be removed soon');
    }
    return context.tr('Ещё $days дн.', '$days days left');
  }

  Widget _empty(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black54, height: 1.35),
        ),
      ),
    );
  }

  Future<void> _forgetAllJobs(List<Job> jobs) async {
    final ok = await _confirmForever(
      context.tr(
        'Удалить все заявки навсегда?',
        'Delete all jobs forever?',
      ),
    );
    if (ok != true || _busy) return;
    AppCommands.reactAngry();
    setState(() => _busy = true);
    try {
      for (final job in jobs) {
        await JobService.deleteForever(job.id);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetAllClients(List<Client> clients) async {
    final ok = await _confirmForever(
      context.tr(
        'Удалить всех клиентов навсегда?',
        'Delete all clients forever?',
      ),
    );
    if (ok != true || _busy) return;
    AppCommands.reactAngry();
    setState(() => _busy = true);
    try {
      for (final client in clients) {
        await ClientService.deleteForever(client.id);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetAllDocuments(
    List<({Job job, int index, Map<String, dynamic> doc})> rows,
  ) async {
    final ok = await _confirmForever(
      context.tr(
        'Удалить все счета навсегда?',
        'Delete all invoices forever?',
      ),
    );
    if (ok != true || _busy) return;
    AppCommands.reactAngry();
    setState(() => _busy = true);
    try {
      final jobIds = {for (final row in rows) row.job.id};
      for (final jobId in jobIds) {
        await JobService.deleteAllTrashedDocumentsOnJob(jobId);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetAllCalls(List<CallRecord> calls) async {
    final ok = await _confirmForever(
      context.tr(
        'Удалить все звонки навсегда?',
        'Delete all calls forever?',
      ),
    );
    if (ok != true || _busy) return;
    AppCommands.reactAngry();
    setState(() => _busy = true);
    try {
      for (final call in calls) {
        await TwilioService.deleteForever(call.id);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetAllMessages(List<SmsMessage> messages) async {
    final ok = await _confirmForever(
      context.tr(
        'Удалить все сообщения навсегда?',
        'Delete all messages forever?',
      ),
    );
    if (ok != true || _busy) return;
    AppCommands.reactAngry();
    setState(() => _busy = true);
    try {
      for (final message in messages) {
        await SmsService.deleteForever(message.id);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _deleteAllButton(VoidCallback? onPressed) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _busy ? null : onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red,
            side: const BorderSide(color: Colors.red),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          icon: const Icon(Icons.delete_forever),
          label: Text(context.tr('Удалить все', 'Delete all')),
        ),
      ),
    );
  }

  Widget _hint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Text(
        context.tr(
          '30 дней на восстановление, потом удаление навсегда.',
          '30 days to restore, then they are deleted forever.',
        ),
        style: const TextStyle(color: Colors.black54, height: 1.35),
      ),
    );
  }

  Widget _actions({
    required VoidCallback onRestore,
    required VoidCallback onForget,
  }) {
    return Wrap(
      spacing: 0,
      children: [
        IconButton(
          tooltip: context.tr('Восстановить', 'Restore'),
          icon: const Icon(Icons.restore),
          onPressed: onRestore,
        ),
        IconButton(
          tooltip: context.tr('Удалить навсегда', 'Delete forever'),
          icon: const Icon(Icons.delete_forever, color: Colors.red),
          onPressed: onForget,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(context.tr('Корзина', 'Trash')),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorColor: AppColors.accent,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: [
            Tab(text: context.tr('Заявки', 'Jobs')),
            Tab(text: context.tr('Клиенты', 'Clients')),
            Tab(text: context.tr('Счета', 'Invoices')),
            Tab(text: context.tr('Сообщения', 'Messages')),
            Tab(text: context.tr('Звонки', 'Calls')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          StreamBuilder<List<Job>>(
            stream: JobService.streamTrashed(),
            builder: (context, snap) {
              final jobs = [...(snap.data ?? const <Job>[])]
                ..sort((a, b) => (b.deletedAt ?? b.createdAt)
                    .compareTo(a.deletedAt ?? a.createdAt));
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (jobs.isEmpty) {
                return _empty(
                  context.tr(
                    'Нет удалённых заявок.',
                    'No deleted jobs.',
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 40),
                children: [
                  _hint(),
                  _deleteAllButton(() => _forgetAllJobs(jobs)),
                  for (final job in jobs) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: JobAgendaCard(
                        job: job,
                        footer: _daysLeft(job.trashDaysLeft),
                        onTap: () => _restoreJob(job),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: () => _restoreJob(job),
                              icon: const Icon(Icons.restore, size: 18),
                              label: Text(context.tr('Восстановить', 'Restore')),
                            ),
                            TextButton.icon(
                              onPressed: () => _forgetJob(job),
                              icon: const Icon(Icons.delete_forever, size: 18, color: Colors.red),
                              label: Text(
                                context.tr('Навсегда', 'Forever'),
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
          StreamBuilder<List<Client>>(
            stream: ClientService.streamTrashed(),
            builder: (context, snap) {
              final clients = [...(snap.data ?? const <Client>[])]
                ..sort(
                  (a, b) => (b.deletedAt ?? b.createdAt ?? DateTime(0))
                      .compareTo(a.deletedAt ?? a.createdAt ?? DateTime(0)),
                );
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (clients.isEmpty) {
                return _empty(
                  context.tr(
                    'Нет удалённых клиентов.',
                    'No deleted clients.',
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 40),
                children: [
                  _hint(),
                  _deleteAllButton(() => _forgetAllClients(clients)),
                  for (final client in clients)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppColors.accent,
                          child: Text(
                            client.initials,
                            style: const TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        title: Text(client.fullName),
                        subtitle: Text(
                          [
                            if (client.phone.trim().isNotEmpty) client.phone.trim(),
                            _daysLeft(client.trashDaysLeft),
                          ].join(' · '),
                        ),
                        trailing: _actions(
                          onRestore: () => _restoreClient(client),
                          onForget: () => _forgetClient(client),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          StreamBuilder<List<({Job job, int index, Map<String, dynamic> doc})>>(
            stream: JobService.streamTrashedDocuments(),
            builder: (context, snap) {
              final rows = snap.data ?? const [];
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (rows.isEmpty) {
                return _empty(
                  context.tr(
                    'Нет удалённых счетов. Удалите счёт в заявке — он будет здесь 30 дней.',
                    'No deleted invoices. Delete an invoice on a job and it stays here for 30 days.',
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 40),
                children: [
                  _hint(),
                  _deleteAllButton(() => _forgetAllDocuments(rows)),
                  for (final row in rows)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.green.shade50,
                          child: Icon(
                            (row.doc['type'] ?? '') == 'Estimate'
                                ? Icons.description
                                : Icons.receipt_long,
                            color: Colors.green.shade800,
                          ),
                        ),
                        title: Text(
                          '${row.doc['type'] ?? 'Invoice'} #${row.doc['number'] ?? (row.index + 1)}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(
                          [
                            row.job.clientName,
                            Formatters.formatCurrency(Job.documentTotal(row.doc)),
                            _daysLeft(Job.documentTrashDaysLeft(row.doc)),
                          ].join(' · '),
                        ),
                        trailing: _actions(
                          onRestore: () => JobService.restoreDocument(
                            row.job.id,
                            row.index,
                          ),
                          onForget: () async {
                            final ok = await _confirmForever(
                              context.tr(
                                'Удалить счёт навсегда?',
                                'Delete this invoice forever?',
                              ),
                            );
                            if (ok != true) return;
                            AppCommands.reactAngry();
                            await JobService.deleteDocumentForever(
                              row.job.id,
                              row.index,
                            );
                          },
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          StreamBuilder<List<SmsMessage>>(
            stream: SmsService.streamTrashed(),
            builder: (context, snap) {
              final messages = snap.data ?? const <SmsMessage>[];
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (messages.isEmpty) {
                return _empty(
                  context.tr(
                    'Нет удалённых сообщений. Смахните SMS или письмо влево в чате.',
                    'No deleted messages. Swipe an SMS or email left in the chat.',
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 40),
                children: [
                  _hint(),
                  _deleteAllButton(() => _forgetAllMessages(messages)),
                  for (final message in messages)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.indigo.shade50,
                          child: Icon(
                            message.isEmail ? Icons.email_outlined : Icons.sms_outlined,
                            color: Colors.indigo,
                          ),
                        ),
                        title: Text(
                          message.displayBody,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            message.isOutbound
                                ? context.tr('Исходящее', 'Outgoing')
                                : context.tr('Входящее', 'Incoming'),
                            if (message.isEmail)
                              (message.isOutbound ? message.toEmail : message.fromEmail)
                            else
                              (message.isOutbound ? message.to : message.from),
                            _daysLeft(message.trashDaysLeft),
                          ].where((part) => part.trim().isNotEmpty).join(' · '),
                        ),
                        trailing: _actions(
                          onRestore: () => SmsService.restore(message.id),
                          onForget: () async {
                            final ok = await _confirmForever(
                              context.tr(
                                'Удалить сообщение навсегда?',
                                'Delete this message forever?',
                              ),
                            );
                            if (ok != true) return;
                            AppCommands.reactAngry();
                            await SmsService.deleteForever(message.id);
                          },
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          StreamBuilder<List<CallRecord>>(
            stream: TwilioService.streamTrashed(),
            builder: (context, snap) {
              final calls = snap.data ?? const <CallRecord>[];
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (calls.isEmpty) {
                return _empty(
                  context.tr(
                    'Нет удалённых звонков. Смахните звонок влево в списке.',
                    'No deleted calls. Swipe a call left in the list.',
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 40),
                children: [
                  _hint(),
                  _deleteAllButton(() => _forgetAllCalls(calls)),
                  for (final call in calls)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.indigo.shade50,
                          child: Icon(
                            call.isIncoming ? Icons.call_received : Icons.call_made,
                            color: Colors.indigo,
                          ),
                        ),
                        title: Text(
                          call.isIncoming ? call.fromNumber : call.toNumber,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            call.isIncoming
                                ? context.tr('Входящий', 'Incoming')
                                : context.tr('Исходящий', 'Outgoing'),
                            if (call.startTime != null)
                              Formatters.formatDateTime(call.startTime),
                            _daysLeft(call.trashDaysLeft),
                          ].where((part) => part.toString().trim().isNotEmpty).join(' · '),
                        ),
                        trailing: _actions(
                          onRestore: () => TwilioService.restore(call.id),
                          onForget: () async {
                            final ok = await _confirmForever(
                              context.tr(
                                'Удалить звонок навсегда?',
                                'Delete this call forever?',
                              ),
                            );
                            if (ok != true) return;
                            AppCommands.reactAngry();
                            await TwilioService.deleteForever(call.id);
                          },
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Открытые заявки без даты визита — не корзина.
class UnscheduledJobsScreen extends StatelessWidget {
  const UnscheduledJobsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text(context.tr('Без даты визита', 'Unscheduled')),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<List<Job>>(
        stream: JobService.streamAll(),
        builder: (context, jobsSnap) {
          final jobs = (jobsSnap.data ?? const <Job>[])
              .where((job) => job.isUnscheduled)
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          if (!jobsSnap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (jobs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.tr(
                    'Нет заявок без даты. Поставьте визит — заявка появится в календаре.',
                    'No unscheduled jobs. Set a visit date and the job appears on the calendar.',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54, height: 1.35),
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
            children: [
              Text(
                context.tr(
                  'Эти заявки ещё без слота. Дата визита отправит их в календарь.',
                  'These jobs have no visit slot yet. A date moves them to the calendar.',
                ),
                style: const TextStyle(color: Colors.black54, height: 1.35),
              ),
              const SizedBox(height: 12),
              for (final job in jobs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: JobAgendaCard(
                    job: job,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => JobDetailsScreen(
                            jobId: job.id,
                            clientId: job.clientId,
                            jobData: job.toMap(),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
