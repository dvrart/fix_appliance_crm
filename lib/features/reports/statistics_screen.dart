import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/client.dart';
import '../../models/expense.dart';
import '../../models/job.dart';
import '../../services/client_service.dart';
import '../../services/expense_service.dart';
import '../../services/job_service.dart';
import '../../services/sms_service.dart';
import '../../services/twilio_service.dart';
import 'statistics_detail_page.dart';

class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  String _filter = 'День';
  DateTime _selectedDate = DateTime.now();

  List<Job> _jobs = const [];
  List<Client> _clients = const [];
  List<CallRecord> _calls = const [];
  List<SmsMessage> _messages = const [];
  List<Expense> _expenses = const [];

  StreamSubscription<List<Job>>? _jobsSub;
  StreamSubscription<List<Client>>? _clientsSub;
  StreamSubscription<List<CallRecord>>? _callsSub;
  StreamSubscription<List<SmsMessage>>? _messagesSub;
  StreamSubscription<List<Expense>>? _expensesSub;

  @override
  void initState() {
    super.initState();
    _jobsSub = JobService.streamAll().listen((items) {
      if (mounted) setState(() => _jobs = items);
    });
    _clientsSub = ClientService.streamAll().listen((items) {
      if (mounted) setState(() => _clients = items);
    });
    _callsSub = TwilioService.streamAll().listen((items) {
      if (mounted) setState(() => _calls = items);
    });
    _messagesSub = SmsService.streamAll().listen((items) {
      if (mounted) setState(() => _messages = items);
    });
    _expensesSub = ExpenseService.streamAll().listen((items) {
      if (mounted) setState(() => _expenses = items);
    });
  }

  @override
  void dispose() {
    _jobsSub?.cancel();
    _clientsSub?.cancel();
    _callsSub?.cancel();
    _messagesSub?.cancel();
    _expensesSub?.cancel();
    super.dispose();
  }

  DateTime get _periodStart {
    final date = _selectedDate;
    switch (_filter) {
      case 'Неделя':
        return DateTime(date.year, date.month, date.day)
            .subtract(Duration(days: date.weekday - 1));
      case 'Месяц':
        return DateTime(date.year, date.month, 1);
      default:
        return DateTime(date.year, date.month, date.day);
    }
  }

  DateTime get _periodEndExclusive {
    switch (_filter) {
      case 'Неделя':
        return _periodStart.add(const Duration(days: 7));
      case 'Месяц':
        return DateTime(_selectedDate.year, _selectedDate.month + 1, 1);
      default:
        return _periodStart.add(const Duration(days: 1));
    }
  }

  bool _inPeriod(DateTime? date) {
    if (date == null) return false;
    return !date.isBefore(_periodStart) && date.isBefore(_periodEndExclusive);
  }

  DateTime? _parseAnyDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw);
    }
    if (raw is num) {
      final value = raw.toDouble();
      if (value > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value.round());
      }
      if (value > 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch((value * 1000).round());
      }
    }
    return null;
  }

  DateTime? _invoiceDate(Map doc) {
    return _parseAnyDate(doc['createdAt']) ??
        _parseAnyDate(doc['issuedAt']) ??
        _parseAnyDate(doc['date']);
  }

  DateTime? _paymentDate(Map payment, DateTime? fallback) {
    return _parseAnyDate(payment['date']) ??
        _parseAnyDate(payment['createdAt']) ??
        fallback;
  }

  String get _periodLabel {
    switch (_filter) {
      case 'Неделя':
        final end = _periodEndExclusive.subtract(const Duration(days: 1));
        return '${DateFormat('d MMM', AppLocale.instance.dateLocale).format(_periodStart)} – ${DateFormat('d MMM yyyy', AppLocale.instance.dateLocale).format(end)}';
      case 'Месяц':
        return DateFormat('LLLL yyyy', AppLocale.instance.dateLocale)
            .format(_selectedDate);
      default:
        return DateFormat('d MMMM yyyy', AppLocale.instance.dateLocale)
            .format(_selectedDate);
    }
  }

  void _shift(int direction) {
    setState(() {
      switch (_filter) {
        case 'Неделя':
          _selectedDate = _selectedDate.add(Duration(days: 7 * direction));
          break;
        case 'Месяц':
          _selectedDate = DateTime(
            _selectedDate.year,
            _selectedDate.month + direction,
            1,
          );
          break;
        default:
          _selectedDate = _selectedDate.add(Duration(days: direction));
      }
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: Color(0xFF14557F)),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    setState(() => _selectedDate = picked);
  }

  List<StatPoint> _callPoints() {
    return [
      for (final call in _calls)
        if (call.startTime != null) StatPoint(call.startTime!),
    ];
  }

  List<StatPoint> _jobPoints() {
    return [for (final job in _jobs) StatPoint(job.createdAt)];
  }

  List<StatPoint> _clientPoints() {
    return [
      for (final client in _clients)
        if (client.createdAt != null) StatPoint(client.createdAt!),
    ];
  }

  List<StatPoint> _invoicePoints() {
    return [
      for (final job in _jobs)
        for (final inv in job.documents)
          if (Job.isInvoice(inv))
            if (_invoiceDate(inv) != null) StatPoint(_invoiceDate(inv)!),
    ];
  }

  List<StatPoint> _paymentPoints() {
    final points = <StatPoint>[];
    for (final job in _jobs) {
      for (final inv in job.documents) {
        if (!Job.isInvoice(inv)) continue;
        final invDate = _invoiceDate(inv);
        final paymentsRaw = inv['payments'];
        if (paymentsRaw is! List) continue;
        for (final payment in paymentsRaw) {
          if (payment is! Map) continue;
          final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
          if (amount <= 0) continue;
          final payDate = _paymentDate(payment, invDate);
          if (payDate == null) continue;
          points.add(StatPoint(payDate, amount));
        }
      }
    }
    return points;
  }

  List<StatPoint> _visitPoints() {
    final points = <StatPoint>[];
    for (final job in _jobs) {
      if (job.visits.isEmpty) {
        if (job.scheduledAt != null) points.add(StatPoint(job.scheduledAt!));
        continue;
      }
      for (final visit in job.visits) {
        points.add(StatPoint(visit.startAt));
      }
    }
    return points;
  }

  List<StatPoint> _donePoints() {
    return [
      for (final job in _jobs)
        if (job.completedAt != null && JobStatuses.isCompletedStatus(job.status))
          StatPoint(job.completedAt!),
    ];
  }

  List<StatPoint> _emailPoints() {
    return [
      for (final message in _messages)
        if (message.isEmail &&
            message.direction == 'inbound' &&
            message.createdAt != null)
          StatPoint(message.createdAt!),
    ];
  }

  List<StatPoint> _smsPoints() {
    return [
      for (final message in _messages)
        if (!message.isEmail &&
            message.direction == 'inbound' &&
            message.createdAt != null)
          StatPoint(message.createdAt!),
    ];
  }

  List<StatPoint> _expensePoints() {
    return [for (final expense in _expenses) StatPoint(expense.date)];
  }

  void _openDetail({
    required String title,
    required IconData icon,
    required Color color,
    required List<StatPoint> points,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StatisticsDetailPage(
          title: title,
          icon: icon,
          color: color,
          filter: _filter,
          selectedDate: _selectedDate,
          points: points,
        ),
      ),
    );
  }

  _ShopStats get _stats {
    var jobs = 0;
    var done = 0;
    var visits = 0;
    var invoices = 0;
    var payments = 0;
    var paidAmount = 0.0;

    for (final job in _jobs) {
      if (_inPeriod(job.createdAt)) {
        jobs++;
      }
      if (_inPeriod(job.completedAt) && JobStatuses.isCompletedStatus(job.status)) {
        done++;
      }
      for (final visit in job.visits) {
        if (_inPeriod(visit.startAt)) visits++;
      }
      if (job.visits.isEmpty && _inPeriod(job.scheduledAt)) visits++;
      for (final inv in job.documents) {
        if (!Job.isInvoice(inv)) continue;
        final invDate = _invoiceDate(inv);
        if (_inPeriod(invDate)) invoices++;
        final paymentsRaw = inv['payments'];
        if (paymentsRaw is List) {
          for (final payment in paymentsRaw) {
            if (payment is! Map) continue;
            final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
            if (amount <= 0) continue;
            final payDate = _paymentDate(payment, invDate);
            if (!_inPeriod(payDate)) continue;
            payments++;
            paidAmount += amount;
          }
        }
      }
    }

    final clients = _clients.where((c) => _inPeriod(c.createdAt)).length;
    final calls = _calls.where((c) => _inPeriod(c.startTime)).length;
    final emails = _messages
        .where((m) => m.isEmail && m.direction == 'inbound' && _inPeriod(m.createdAt))
        .length;
    final sms = _messages
        .where((m) => !m.isEmail && m.direction == 'inbound' && _inPeriod(m.createdAt))
        .length;
    final expenses = _expenses.where((e) => _inPeriod(e.date)).length;

    return _ShopStats(
      calls: calls,
      jobs: jobs,
      done: done,
      visits: visits,
      clients: clients,
      invoices: invoices,
      payments: payments,
      paidAmount: paidAmount,
      emails: emails,
      sms: sms,
      expenses: expenses,
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final money = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        title: Text(
          context.tr('Статистика', 'Statistics'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                for (final filter in const ['День', 'Неделя', 'Месяц'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        trAny(filter),
                        style: TextStyle(
                          color: _filter == filter ? Colors.white : Colors.black87,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      selected: _filter == filter,
                      selectedColor: const Color(0xFF14557F),
                      backgroundColor: Colors.grey.shade200,
                      onSelected: (selected) {
                        if (!selected) return;
                        setState(() => _filter = filter);
                      },
                    ),
                  ),
              ],
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 30, color: Color(0xFF14557F)),
                  onPressed: () => _shift(-1),
                ),
                Expanded(
                  child: TextButton.icon(
                    icon: const Icon(Icons.calendar_month, color: Color(0xFF14557F)),
                    label: Text(
                      _periodLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF14557F),
                      ),
                    ),
                    onPressed: _pickDate,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, size: 30, color: Color(0xFF14557F)),
                  onPressed: () => _shift(1),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.35,
                  children: [
                    _tile(
                      context.tr('Звонки', 'Calls'),
                      '${stats.calls}',
                      Icons.phone_in_talk,
                      const Color(0xFF1565C0),
                      points: _callPoints(),
                    ),
                    _tile(
                      context.tr('Заявки', 'Jobs'),
                      '${stats.jobs}',
                      Icons.assignment,
                      const Color(0xFF14557F),
                      points: _jobPoints(),
                    ),
                    _tile(
                      context.tr('Клиенты', 'Clients'),
                      '${stats.clients}',
                      Icons.people_alt_outlined,
                      const Color(0xFF6A1B9A),
                      points: _clientPoints(),
                    ),
                    _tile(
                      context.tr('Инвойсы', 'Invoices'),
                      '${stats.invoices}',
                      Icons.receipt_long,
                      const Color(0xFF00897B),
                      points: _invoicePoints(),
                    ),
                    _tile(
                      context.tr('Оплаты', 'Payments'),
                      '${stats.payments}',
                      Icons.payments_outlined,
                      const Color(0xFF2E7D32),
                      subtitle: money.format(stats.paidAmount),
                      points: _paymentPoints(),
                    ),
                    _tile(
                      context.tr('Визиты', 'Visits'),
                      '${stats.visits}',
                      Icons.event_available,
                      const Color(0xFFEF6C00),
                      points: _visitPoints(),
                    ),
                    _tile(
                      context.tr('Завершено', 'Completed'),
                      '${stats.done}',
                      Icons.check_circle_outline,
                      const Color(0xFF43A047),
                      points: _donePoints(),
                    ),
                    _tile(
                      context.tr('Письма', 'Emails'),
                      '${stats.emails}',
                      Icons.email_outlined,
                      const Color(0xFFC62828),
                      points: _emailPoints(),
                    ),
                    _tile(
                      context.tr('SMS', 'SMS'),
                      '${stats.sms}',
                      Icons.sms_outlined,
                      const Color(0xFF455A64),
                      points: _smsPoints(),
                    ),
                    _tile(
                      context.tr('Расходы', 'Expenses'),
                      '${stats.expenses}',
                      Icons.receipt_outlined,
                      const Color(0xFFD84315),
                      points: _expensePoints(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(
    String title,
    String value,
    IconData icon,
    Color color, {
    String? subtitle,
    required List<StatPoint> points,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openDetail(
          title: title,
          icon: icon,
          color: color,
          points: points,
        ),
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 22),
                  const Spacer(),
                  Icon(Icons.chevron_right, color: Colors.black26, size: 20),
                ],
              ),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: color,
                  height: 1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.black54,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle,
                  style: TextStyle(
                    color: color.withValues(alpha: 0.8),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShopStats {
  final int calls;
  final int jobs;
  final int done;
  final int visits;
  final int clients;
  final int invoices;
  final int payments;
  final double paidAmount;
  final int emails;
  final int sms;
  final int expenses;

  const _ShopStats({
    required this.calls,
    required this.jobs,
    required this.done,
    required this.visits,
    required this.clients,
    required this.invoices,
    required this.payments,
    required this.paidAmount,
    required this.emails,
    required this.sms,
    required this.expenses,
  });
}
