import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_feedback.dart';
import '../../core/constants.dart';
import '../../core/motion.dart';
import '../../core/sms_text.dart';
import '../../core/utils/app_date_picker.dart';
import '../../core/utils/formatters.dart';
import '../../models/document_settings.dart';
import '../../services/ai_service.dart';
import '../../services/app_time_service.dart';
import '../../services/client_service.dart';
import '../../services/email_service.dart';
import '../../services/firestore_service.dart';
import '../../services/job_service.dart';
import '../../services/message_translate_service.dart';
import '../../services/outbound_media_service.dart';
import '../../services/scheduled_message_service.dart';
import '../../services/settings_service.dart';
import '../../services/sms_service.dart';
import '../../models/client.dart';
import '../../models/job.dart';
import '../ai/job_preview_screen.dart';
import '../calls/call_screen.dart';
import '../clients/client_details_screen.dart';
import '../clients/edit_client_sheet.dart';
import '../jobs/job_details/widgets/full_screen_gallery.dart';
import '../settings/pages/message_templates_page.dart';
import '../settings/widgets/company_logo.dart';
import '../../core/l10n/app_locale.dart';
import '../../shared/app_nav.dart';
import '../../shared/widgets/job_link_button.dart';
import '../../shared/widgets/linked_text.dart';
import '../../shared/widgets/selection_action_bar.dart';
import '../../services/error_log_service.dart';

/// Выбор даты и времени в стиле приложения (как при добавлении визита):
/// месяц и барабан времени в одном листе. Возвращает null при отмене.
Future<DateTime?> showScheduleDateTimePicker(BuildContext context) {
  final now = DateTime.now();
  // Дефолт: +1 час, минуты 00 или 30 — ближайший интервал,
  // без пересечения полуночи (иначе дата незаметно прыгает на завтра).
  var candidate = now.add(const Duration(hours: 1));
  final roundMinute = candidate.minute < 30 ? 30 : 0;
  final roundHour = candidate.hour + (candidate.minute >= 30 ? 1 : 0);
  DateTime picked;
  if (roundHour >= 24) {
    // Переходим полночь → просто +1 час без округления, дата остаётся сегодняшней
    picked = candidate;
  } else {
    picked = DateTime(candidate.year, candidate.month, candidate.day, roundHour, roundMinute);
  }

  return showModalBottomSheet<DateTime>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => _ScheduleDateTimeSheet(initial: picked),
  );
}

class _ScheduleDateTimeSheet extends StatefulWidget {
  final DateTime initial;
  const _ScheduleDateTimeSheet({required this.initial});
  @override
  State<_ScheduleDateTimeSheet> createState() => _ScheduleDateTimeSheetState();
}

class _ScheduleDateTimeSheetState extends State<_ScheduleDateTimeSheet> {
  late DateTime _dt;

  @override
  void initState() {
    super.initState();
    _dt = widget.initial;
  }

  String _relativeLabel(DateTime dt) {
    final diff = dt.difference(DateTime.now());
    if (diff.isNegative) return 'в прошлом'.tr;
    final h = diff.inHours;
    final m = diff.inMinutes % 60;
    if (h == 0) return 'через $m мин'.tr;
    if (m == 0) return 'через $h ч'.tr;
    return 'через $h ч $m мин'.tr;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final tooSoon = _dt.isBefore(DateTime.now().add(const Duration(minutes: 1)));
    final relLabel = _relativeLabel(_dt);

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Запланировать отправку'.tr,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              tooSoon
                  ? 'Выберите время хотя бы на минуту вперёд'.tr
                  : relLabel,
              style: TextStyle(
                fontSize: 14,
                color: tooSoon ? Colors.red : Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              appDateTimeLabel(_dt),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            AppDateTimePanel(
              value: _dt,
              firstDate: now,
              lastDate: now.add(const Duration(days: 365)),
              onChanged: (v) => setState(() => _dt = v),
            ),
            const SizedBox(height: 8),
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
                      child: Text('Отмена'.tr,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: TextButton(
                      onPressed: tooSoon ? null : () => Navigator.pop(context, _dt),
                      style: TextButton.styleFrom(
                        backgroundColor: tooSoon ? Colors.grey.shade300 : Colors.black,
                        foregroundColor: Colors.white,
                        shape: const StadiumBorder(),
                        disabledForegroundColor: Colors.grey,
                      ),
                      child: Text('Запланировать'.tr,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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

enum ConversationChannel { sms, email }

/// Хозяин или человек на объекте — отдельная нить SMS.
class ConversationPeer {
  final String id;
  final String label;
  final String name;
  final String phone;
  final String email;
  final String address;

  const ConversationPeer({
    required this.id,
    required this.label,
    required this.name,
    this.phone = '',
    this.email = '',
    this.address = '',
  });

  String get displayName {
    final cleaned = SmsText.stripClientWord(name, phone);
    return cleaned.isEmpty ? label : cleaned;
  }

  String get normalizedPhone => SmsService.normalizePhone(phone);

  String get normalizedEmail => email.trim().toLowerCase();

  bool get hasPhone => normalizedPhone.length >= 10;

  bool get hasEmail => normalizedEmail.contains('@');

  bool get hasChannel => hasPhone || hasEmail;

  bool get isOwner =>
      id == 'owner' ||
      id == 'client' ||
      id.startsWith('owner-') ||
      label == 'Хозяин'.tr;

  String get subtitleLine => [
    label,
    if (hasPhone) phone.trim(),
    if (hasEmail) email.trim(),
    if (address.trim().isNotEmpty) address.trim(),
  ].join(' · ');

  static Future<ConversationPeer?> pick(
    BuildContext context,
    List<ConversationPeer> peers, {
    String? title,
    bool phoneOnly = false,
  }) async {
    final available = [
      for (final peer in peers)
        if (phoneOnly ? peer.hasPhone : peer.hasChannel) peer,
    ];
    if (available.isEmpty) return null;
    if (available.length == 1) return available.first;
    return showModalBottomSheet<ConversationPeer>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.72;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    title ?? 'Кому написать?'.tr,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final peer in available)
                        ListTile(
                          leading: Icon(
                            peer.isOwner ? Icons.person : Icons.location_on,
                            color: AppColors.primary,
                          ),
                          title: Text(peer.displayName),
                          subtitle: Text(peer.subtitleLine),
                          onTap: () => Navigator.pop(sheetContext, peer),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  static bool _isGenericTenantName(String value) {
    final lower = value.trim().toLowerCase();
    return lower.isEmpty ||
        lower == 'арендатор' ||
        lower == 'tenant' ||
        lower == 'хозяин' ||
        lower == 'owner' ||
        Client.isPlaceholderName(value);
  }

  static bool _addressesMatch(String a, String b) {
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9а-яё]+'), ' ')
        .trim();
    final na = norm(a);
    final nb = norm(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb || na.contains(nb) || nb.contains(na)) return true;
    final sa = norm(a.split(',').first);
    final sb = norm(b.split(',').first);
    return sa.length >= 4 && sb.length >= 4 && (sa == sb || sa.contains(sb) || sb.contains(sa));
  }

  /// Хозяин и люди на объекте (арендатор) для переключения нити.
  static Future<List<ConversationPeer>> loadForClient({
    String clientId = '',
    String? jobId,
    String name = '',
    String phone = '',
    String email = '',
  }) async {
    final peers = <ConversationPeer>[];
    final seenPhones = <String>{};
    final seenEmails = <String>{};

    void add(ConversationPeer peer) {
      if (!peer.hasChannel) return;
      final normPhone = peer.normalizedPhone;
      final normEmail = peer.normalizedEmail;
      final newPhone = peer.hasPhone && !seenPhones.contains(normPhone);
      final newEmail = peer.hasEmail && !seenEmails.contains(normEmail);
      if (!newPhone && !newEmail) {
        final idx = peers.indexWhere(
          (p) =>
              (peer.hasPhone && p.normalizedPhone == normPhone) ||
              (peer.hasEmail && p.normalizedEmail == normEmail),
        );
        if (idx >= 0) {
          final existing = peers[idx];
          final betterName =
              _isGenericTenantName(existing.name) && !_isGenericTenantName(peer.name)
                  ? peer.name
                  : existing.name;
          final betterAddr = existing.address.trim().isEmpty &&
                  peer.address.trim().isNotEmpty
              ? peer.address.trim()
              : existing.address;
          if (betterName != existing.name || betterAddr != existing.address) {
            peers[idx] = ConversationPeer(
              id: existing.id,
              label: existing.label,
              name: betterName,
              phone: existing.phone,
              email: existing.email,
              address: betterAddr,
            );
          }
        }
        return;
      }
      if (newPhone) seenPhones.add(normPhone);
      if (newEmail) seenEmails.add(normEmail);
      peers.add(
        ConversationPeer(
          id: peer.id,
          label: peer.label,
          name: peer.name,
          phone: newPhone ? peer.phone.trim() : '',
          email: newEmail ? peer.email.trim() : '',
          address: peer.address.trim(),
        ),
      );
    }

    try {
      final trimmedJobId = (jobId ?? '').trim();
      final job = trimmedJobId.isEmpty
          ? null
          : await JobService.getById(trimmedJobId);
      var resolvedClientId = clientId.trim();
      if (resolvedClientId.isEmpty &&
          job != null &&
          job.clientId.trim().isNotEmpty) {
        resolvedClientId = job.clientId.trim();
      }
      var client = resolvedClientId.isEmpty
          ? null
          : await ClientService.getById(resolvedClientId);
      if (client == null && phone.trim().isNotEmpty) {
        client = await ClientService.findByPhone(phone);
      }
      if (client == null && email.trim().contains('@')) {
        client = await ClientService.findByEmail(email);
      }
      if (client != null && resolvedClientId.isEmpty) {
        resolvedClientId = client.id;
      }

      final jobs = <Job>[];
      if (job != null) {
        jobs.add(job);
      } else if (resolvedClientId.isNotEmpty) {
        final snap = await FirestoreService.jobsRef
            .where('clientId', isEqualTo: resolvedClientId)
            .get();
        for (final doc in snap.docs) {
          final parsed = Job.fromMap(
            doc.data() as Map<String, dynamic>,
            doc.id,
          );
          if (!parsed.isDeleted) {
            jobs.add(parsed);
          }
        }
        jobs.sort((a, b) {
          final aClosed = JobStatuses.isClosed(a.status);
          final bClosed = JobStatuses.isClosed(b.status);
          if (aClosed != bClosed) return aClosed ? 1 : -1;
          return b.createdAt.compareTo(a.createdAt);
        });
      }

      final String ownerName;
      final String ownerPhone;
      final String ownerEmail;
      if (client != null) {
        ownerName = client.fullName.trim().isNotEmpty
            ? client.fullName.trim()
            : ((job?.clientName ?? '').trim().isNotEmpty
                ? job!.clientName.trim()
                : name.trim());
        ownerPhone = client.phone.trim().isNotEmpty
            ? client.phone.trim()
            : (job?.clientPhone ?? '').trim();
        ownerEmail = (client.email ?? '').trim().isNotEmpty
            ? client.email!.trim()
            : (job?.clientEmail ?? '').trim();
      } else if (job != null) {
        ownerName = job.clientName.trim().isNotEmpty
            ? job.clientName.trim()
            : name.trim();
        ownerPhone = job.clientPhone.trim().isNotEmpty
            ? job.clientPhone.trim()
            : phone.trim();
        ownerEmail = (job.clientEmail ?? '').trim().isNotEmpty
            ? job.clientEmail!.trim()
            : email.trim();
      } else {
        ownerName = name.trim();
        ownerPhone = phone.trim();
        ownerEmail = email.trim();
      }

      add(
        ConversationPeer(
          id: 'owner',
          label: 'Хозяин'.tr,
          name: ownerName.isEmpty ? 'Хозяин'.tr : ownerName,
          phone: ownerPhone,
          email: ownerEmail,
          address: client?.address ?? job?.clientAddress ?? '',
        ),
      );
      if (client != null) {
        for (var i = 0; i < client.extraPhones.length; i++) {
          final extra = client.extraPhones[i].trim();
          if (extra.isEmpty) continue;
          add(
            ConversationPeer(
              id: 'owner-extra-$i',
              label: 'Хозяин'.tr,
              name: ownerName.isEmpty ? 'Хозяин'.tr : ownerName,
              phone: extra,
              address: client.address,
            ),
          );
        }
      }

      if (job != null) {
        final sName = (job.jobSiteName ?? '').trim();
        final sAddr = (job.jobSiteAddress ?? '').trim().isNotEmpty
            ? job.jobSiteAddress!.trim()
            : job.workAddress.trim();
        if (job.hasJobSite ||
            (job.jobSitePhone ?? '').trim().isNotEmpty ||
            (job.jobSiteEmail ?? '').trim().isNotEmpty) {
          add(
            ConversationPeer(
              id: 'job-${job.id}',
              label: 'Арендатор'.tr,
              name: sName.isEmpty ? 'Арендатор'.tr : sName,
              phone: job.jobSitePhone ?? '',
              email: job.jobSiteEmail ?? '',
              address: sAddr,
            ),
          );
        }
        for (var i = 0; i < job.extraPhones.length; i++) {
          final extra = job.extraPhones[i].trim();
          if (extra.isEmpty) continue;
          add(
            ConversationPeer(
              id: 'job-extra-$i',
              label: job.hasJobSite ? 'Арендатор'.tr : 'Хозяин'.tr,
              name: (job.hasJobSite && sName.isNotEmpty)
                  ? sName
                  : (ownerName.isEmpty ? 'Контакт'.tr : ownerName),
              phone: extra,
              address: sAddr,
            ),
          );
        }
        if (client != null && sAddr.isNotEmpty) {
          for (final location in client.locations) {
            final locAddr = location.fullAddress.trim();
            if (!_addressesMatch(locAddr, sAddr)) continue;
            for (final contact in location.contacts) {
              if (contact.role == 'owner') continue;
              final cName = contact.name.trim().isNotEmpty
                  ? contact.name.trim()
                  : (sName.isNotEmpty ? sName : 'Арендатор'.tr);
              add(
                ConversationPeer(
                  id: 'loc-${contact.id.isEmpty ? contact.phone : contact.id}',
                  label: contact.role == 'manager'
                      ? contact.roleLabel
                      : 'Арендатор'.tr,
                  name: cName,
                  phone: contact.phone,
                  address: locAddr,
                ),
              );
            }
          }
        }
      }

      if (client != null && job == null) {
        for (final location in client.locations) {
          final locAddr = location.fullAddress.trim();
          for (final contact in location.contacts) {
            final isFirstOwner = peers.isEmpty && contact.role == 'owner';
            final label = isFirstOwner
                ? 'Хозяин'.tr
                : (contact.role == 'manager'
                    ? contact.roleLabel
                    : 'Арендатор'.tr);
            final cName = contact.name.trim().isNotEmpty &&
                    contact.name.trim().toLowerCase() !=
                        ownerName.toLowerCase()
                ? contact.name.trim()
                : (locAddr.isNotEmpty ? locAddr.split(',').first.trim() : label);
            add(
              ConversationPeer(
                id: 'loc-${contact.id.isEmpty ? contact.phone : contact.id}',
                label: label,
                name: cName,
                phone: contact.phone,
                address: locAddr,
              ),
            );
          }
        }
      }

      if (job == null) {
        for (final item in jobs) {
          final sName = (item.jobSiteName ?? '').trim();
          final sAddr = (item.jobSiteAddress ?? '').trim().isNotEmpty
              ? item.jobSiteAddress!.trim()
              : item.workAddress.trim();
          final displayTenant = !_isGenericTenantName(sName)
              ? sName
              : (sAddr.isNotEmpty ? sAddr.split(',').first.trim() : 'Арендатор'.tr);
          if (item.hasJobSite ||
              (item.jobSitePhone ?? '').trim().isNotEmpty ||
              (item.jobSiteEmail ?? '').trim().isNotEmpty) {
            add(
              ConversationPeer(
                id: 'job-${item.id}',
                label: 'Арендатор'.tr,
                name: displayTenant,
                phone: item.jobSitePhone ?? '',
                email: item.jobSiteEmail ?? '',
                address: sAddr,
              ),
            );
          }
          for (var i = 0; i < item.extraPhones.length; i++) {
            final extra = item.extraPhones[i].trim();
            if (extra.isEmpty) continue;
            add(
              ConversationPeer(
                id: 'job-${item.id}-extra-$i',
                label: item.hasJobSite ? 'Арендатор'.tr : 'Хозяин'.tr,
                name: item.hasJobSite ? displayTenant : ownerName,
                phone: extra,
                address: sAddr,
              ),
            );
          }
        }
      }

      for (final item in jobs) {
        final callId = (item.sourceCallId ?? '').trim();
        if (callId.isEmpty) continue;
        final callDoc = await FirestoreService.callsRef.doc(callId).get();
        if (!callDoc.exists) continue;
        final callData = (callDoc.data() as Map<String, dynamic>?) ?? const {};
        final ex = (callData['extractedData'] is Map)
            ? Map<String, dynamic>.from(callData['extractedData'] as Map)
            : const <String, dynamic>{};
        final cPhone = (ex['contact_on_site_phone'] ?? '').toString().trim();
        if (cPhone.isEmpty) continue;
        final cName = (ex['contact_on_site_name'] ?? item.jobSiteName ?? '')
            .toString()
            .trim();
        final sAddr = (item.jobSiteAddress ?? '').trim().isNotEmpty
            ? item.jobSiteAddress!.trim()
            : item.workAddress.trim();
        add(
          ConversationPeer(
            id: 'call-$callId',
            label: 'Арендатор'.tr,
            name: cName.isEmpty
                ? (sAddr.isNotEmpty ? sAddr.split(',').first.trim() : 'Арендатор'.tr)
                : cName,
            phone: cPhone,
            address: sAddr,
          ),
        );
      }

      if (phone.trim().isNotEmpty || email.trim().contains('@')) {
        final isFirst = peers.isEmpty;
        final fallbackLabel = isFirst ? 'Хозяин'.tr : 'Арендатор'.tr;
        add(
          ConversationPeer(
            id: isFirst ? 'owner' : 'site',
            label: fallbackLabel,
            name: name.trim().isNotEmpty ? name.trim() : fallbackLabel,
            phone: phone,
            email: email,
          ),
        );
      }
    } catch (_) {}
    return peers;
  }
}

/// Переписка с одним клиентом. SMS и почта переключаются, лента меняется.
class ConversationScreen extends StatefulWidget {
  final String phoneNumber;
  final String? email;
  final String? contactName;
  final String? clientId;
  final String? jobId;
  final List<String> extraPhones;
  final List<ConversationPeer> recipients;
  final ValueChanged<ConversationPeer>? onRecipientChanged;
  final bool embedded;

  /// Встроенный чат ([embedded]): выбрана ли сейчас вкладка «Чат» в карточке
  /// заявки. У обычной карточки видимость решает маршрут — параметр не нужен.
  final bool embeddedVisible;
  final ConversationChannel? initialChannel;
  final bool websiteInbox;

  /// Сообщение, о котором было уведомление: лента подводит к нему и на
  /// пару секунд подсвечивает. Иначе в длинной переписке непонятно, что
  /// именно пришло.
  final String? highlightMessageId;

  const ConversationScreen({
    super.key,
    this.phoneNumber = '',
    this.email,
    this.contactName,
    this.clientId,
    this.jobId,
    this.extraPhones = const [],
    this.recipients = const [],
    this.onRecipientChanged,
    this.embedded = false,
    this.embeddedVisible = true,
    this.initialChannel,
    this.websiteInbox = false,
    this.highlightMessageId,
  });

  static Future<void> open(
    BuildContext context, {
    String phoneNumber = '',
    String? email,
    String? contactName,
    String? clientId,
    String? jobId,
    ConversationChannel? initialChannel,
    bool websiteInbox = false,
    bool rootNavigator = false,
    bool askRecipient = false,
    String? highlightMessageId,
  }) async {
    AppFeedback.pleasant();
    var resolvedName = (contactName ?? '').trim();
    if (!websiteInbox &&
        resolvedName.isEmpty &&
        (email ?? '').trim().contains('@')) {
      resolvedName = await SettingsService.loadWatchedSenderName(email!);
    }
    final recipients = !websiteInbox
        ? await ConversationPeer.loadForClient(
            clientId: clientId ?? '',
            jobId: jobId,
            name: resolvedName.isNotEmpty ? resolvedName : (contactName ?? ''),
            phone: phoneNumber,
            email: email ?? '',
          )
        : const <ConversationPeer>[];
    if (!context.mounted) return;
    var targetPhone = phoneNumber;
    var targetEmail = email;
    var targetName = websiteInbox
        ? kWebsiteInboxTitle
        : (resolvedName.isNotEmpty ? resolvedName : contactName);
    if (!websiteInbox && askRecipient && recipients.length > 1) {
      final chosen = await ConversationPeer.pick(context, recipients);
      if (chosen == null || !context.mounted) return;
      targetPhone = chosen.phone;
      targetEmail = chosen.hasEmail ? chosen.email : null;
      targetName = chosen.displayName;
    }
    await AppNav.openCard<void>(
      context,
      rootNavigator: rootNavigator,
      key: AppNav.chatKey(
        phone: targetPhone,
        email: targetEmail,
        jobId: jobId,
        websiteInbox: websiteInbox,
      ),
      builder: (_) => ConversationScreen(
        phoneNumber: targetPhone,
        email: targetEmail,
        contactName: targetName,
        clientId: websiteInbox ? null : clientId,
        jobId: jobId,
        recipients: recipients,
        initialChannel: websiteInbox
            ? ConversationChannel.email
            : initialChannel,
        websiteInbox: websiteInbox,
        highlightMessageId: highlightMessageId,
      ),
    );
  }

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen>
    with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;
  bool _extracting = false;
  late ConversationChannel _channel;
  final List<OutboundAttachment> _attachments = [];
  late String _phone;
  late String _email;
  late String _contactName;
  late String _peerId;
  final Map<String, List<SmsMessage>> _threadCache = {};
  late Stream<List<SmsMessage>> _messagesStream;
  late Stream<List<ScheduledMessage>> _scheduledStream;

  String get _threadKey => widget.websiteInbox
      ? 'website-email'
      : '$_channel|$_phone|$_email';
  final Set<String> _selectedIds = {};
  /// Сообщения, по которым прямо сейчас уходит решение «отправить / не надо».
  final Set<String> _decidingIds = {};
  List<String> _visibleIds = const [];
  Timer? _translateDebounce;

  /// Сообщение из уведомления: подсвечиваем и подводим к нему ленту.
  String? _highlightId;
  final GlobalKey _highlightKey = GlobalKey();
  bool _highlightShown = false;
  Timer? _highlightTimer;

  /// Приложение на переднем плане. В фоне входящее не «просмотрено» —
  /// бейдж и шторка должны про него честно напомнить.
  bool _appResumed = true;
  DateTime? _lastAutoMarkAt;

  bool get _selecting => _selectedIds.isNotEmpty;

  void _clearSelection() => setState(() => _selectedIds.clear());

  void _toggleSelected(String id) {
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  void _selectAllVisible() {
    setState(() => _selectedIds.addAll(_visibleIds));
  }

  Future<void> _deleteSelected() async {
    final ids = _selectedIds.toList();
    _clearSelection();
    await SmsService.deleteMany(ids);
  }

  Future<void> _copySelected() async {
    final messages = _threadCache[_threadKey] ?? const <SmsMessage>[];
    final byId = {for (final m in messages) m.id: m};
    final parts = <String>[];
    for (final id in _selectedIds) {
      final message = byId[id];
      if (message == null) continue;
      final subject = message.subject.trim();
      final body = message.body.trim();
      if (subject.isNotEmpty && body.isNotEmpty) {
        parts.add('$subject\n$body');
      } else if (subject.isNotEmpty) {
        parts.add(subject);
      } else if (body.isNotEmpty) {
        parts.add(body);
      }
    }
    if (parts.isEmpty) return;
    await AppFeedback.copy(context, parts.join('\n\n'));
    _clearSelection();
  }

  static const List<String> _reactionEmojis = ['👍', '❤️', '😂', '😊', '🙏', '❗'];
  final Map<String, String> _optimisticReactions = {};

  String _effectiveReaction(SmsMessage message) =>
      _optimisticReactions[message.id] ?? message.reaction;

  SmsMessage? _singleSelectedMessage() {
    if (_selectedIds.length != 1) return null;
    final id = _selectedIds.first;
    final messages = _threadCache[_threadKey] ?? const <SmsMessage>[];
    for (final m in messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<void> _applyReaction(SmsMessage message, String emoji) async {
    final current = _effectiveReaction(message);
    final next = current == emoji ? '' : emoji;
    AppFeedback.selection();
    setState(() {
      _optimisticReactions[message.id] = next;
      _selectedIds.clear();
    });
    final targetPhone = _hasPhone
        ? _phone
        : (message.isOutbound ? message.to : message.from);
    await SmsService.reactToMessage(
      message: message,
      emoji: next,
      toPhone: targetPhone,
      clientId: widget.clientId,
    );
  }

  Future<void> _pickMessageReaction(SmsMessage message) async {
    final current = _effectiveReaction(message);
    final chosen = await showModalBottomSheet<String>(
      sheetAnimationStyle: AppMotion.sheet,
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final emoji in _reactionEmojis)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.pop(sheetContext, emoji),
                  child: Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: current == emoji
                          ? AppColors.accent.withValues(alpha: 0.35)
                          : AppColors.cardMuted,
                      border: current == emoji
                          ? Border.all(color: AppColors.primary, width: 1.5)
                          : null,
                    ),
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await _applyReaction(message, chosen);
  }

  Widget _buildSelectionReactionBar(SmsMessage message) {
    final current = _effectiveReaction(message);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final emoji in _reactionEmojis)
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _applyReaction(message, emoji),
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: current == emoji
                      ? AppColors.accent.withValues(alpha: 0.35)
                      : AppColors.cardMuted,
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 21)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildReactionButton(SmsMessage message, bool onDark) {
    final current = _effectiveReaction(message).trim();
    final hasReaction = current.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _selecting ? null : () => _pickMessageReaction(message),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: hasReaction ? 9 : 6,
          vertical: hasReaction ? 3 : 2,
        ),
        decoration: BoxDecoration(
          color: hasReaction
              ? (onDark ? const Color(0xFF263238) : Colors.white)
              : (onDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.05)),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: hasReaction
                ? AppColors.primary.withValues(alpha: 0.35)
                : (onDark ? Colors.white24 : Colors.black12),
          ),
          boxShadow: hasReaction
              ? const [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: hasReaction
            ? Text(
                current,
                style: const TextStyle(fontSize: 17, height: 1.1),
              )
            : Icon(
                Icons.add_reaction_outlined,
                size: 16,
                color: onDark ? Colors.white70 : Colors.grey.shade600,
              ),
      ),
    );
  }

  List<ConversationPeer> _loadedPeers = const [];

  /// После создания заявки из переписки значок в шапке должен её найти:
  /// меняем ключ, чтобы [JobLinkButton] заново поискал заявку по номеру.
  int _jobLinkRevision = 0;

  /// ИИ разбирает переписку перед открытием экрана «Проверьте данные».
  bool _creatingJob = false;

  List<ConversationPeer> get _peers {
    final result = <ConversationPeer>[];
    final seenPhones = <String>{};
    final seenEmails = <String>{};
    for (final peer in [...widget.recipients, ..._loadedPeers]) {
      if (!peer.hasChannel) continue;
      final normPhone = peer.normalizedPhone;
      final normEmail = peer.normalizedEmail;
      final newPhone = peer.hasPhone && !seenPhones.contains(normPhone);
      final newEmail = peer.hasEmail && !seenEmails.contains(normEmail);
      if (!newPhone && !newEmail) {
        final idx = result.indexWhere(
          (p) =>
              (peer.hasPhone && p.normalizedPhone == normPhone) ||
              (peer.hasEmail && p.normalizedEmail == normEmail),
        );
        if (idx >= 0 &&
            result[idx].address.trim().isEmpty &&
            peer.address.trim().isNotEmpty) {
          result[idx] = ConversationPeer(
            id: result[idx].id,
            label: result[idx].label,
            name: result[idx].name,
            phone: result[idx].phone,
            email: result[idx].email,
            address: peer.address.trim(),
          );
        }
        continue;
      }
      if (newPhone) seenPhones.add(normPhone);
      if (newEmail) seenEmails.add(normEmail);
      result.add(
        ConversationPeer(
          id: peer.id,
          label: peer.label,
          name: peer.name,
          phone: newPhone ? peer.phone.trim() : '',
          email: newEmail ? peer.email.trim() : '',
          address: peer.address.trim(),
        ),
      );
    }
    return result;
  }

  bool get _hasPhone => SmsService.normalizePhone(_phone).length >= 10;
  bool get _hasEmail => _email.contains('@');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ErrorLogService.markScreen('Переписка');
    _applyPeerFromWidget();
    _channel = widget.websiteInbox
        ? ConversationChannel.email
        : widget.initialChannel ??
            (_hasEmail && !_hasPhone
                ? ConversationChannel.email
                : ConversationChannel.sms);
    _bindStreams();
    _textController.addListener(_onDraftChanged);
    final highlight = (widget.highlightMessageId ?? '').trim();
    _highlightId = highlight.isEmpty ? null : highlight;
    _markRead();
    unawaited(_loadPeersIfNeeded());
  }

  /// Подвести ленту к сообщению из уведомления и снять подсветку.
  ///
  /// Лента перевёрнута и строится лениво: сообщение, о котором пришло
  /// уведомление, почти всегда последнее и уже на экране. Если его пузырь
  /// ещё не построен, прокрутки не будет — подсветка просто погаснет, и
  /// переписка останется там, где открылась.
  void _revealHighlight() {
    if (_highlightId == null || _highlightShown) return;
    _highlightShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _highlightKey.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: 0.5,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          ),
        );
      }
    });
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _highlightId = null);
    });
  }

  /// Пузырь сообщения из уведомления: ключ для прокрутки и мягкая рамка.
  Widget _highlightWrap(SmsMessage message, Widget bubble) {
    if (_highlightId == null || message.id != _highlightId) return bubble;
    return Container(
      key: _highlightKey,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3C4),
        borderRadius: BorderRadius.circular(16),
      ),
      child: bubble,
    );
  }

  Future<void> _loadPeersIfNeeded() async {
    if (widget.websiteInbox) return;
    final cid = (widget.clientId ?? '').trim();
    final jid = (widget.jobId ?? '').trim();
    if (cid.isEmpty && jid.isEmpty) return;
    final loaded = await ConversationPeer.loadForClient(
      clientId: cid,
      jobId: jid.isEmpty ? null : jid,
      name: _contactName.isNotEmpty ? _contactName : (widget.contactName ?? ''),
      phone: _phone,
      email: _email,
    );
    if (!mounted || loaded.isEmpty) return;
    setState(() {
      _loadedPeers = loaded;
      if (_peerId.isEmpty || !_peers.any((p) => p.id == _peerId)) {
        final match = _findMatchingPeer(_phone, _email);
        if (match != null) _peerId = match.id;
      }
    });
  }

  @override
  void didUpdateWidget(covariant ConversationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final phoneChanged = oldWidget.phoneNumber != widget.phoneNumber;
    final emailChanged = oldWidget.email != widget.email;
    final inboxChanged = oldWidget.websiteInbox != widget.websiteInbox;
    final clientChanged = oldWidget.clientId != widget.clientId ||
        oldWidget.jobId != widget.jobId;
    if (phoneChanged || emailChanged || inboxChanged) {
      _applyPeerFromWidget();
      if (widget.websiteInbox || (!_hasPhone && _hasEmail)) {
        _channel = ConversationChannel.email;
      } else if (!_hasEmail) {
        _channel = ConversationChannel.sms;
      }
      _markRead();
    } else if (oldWidget.recipients.length != widget.recipients.length) {
      final match = _findMatchingPeer(_phone, _email);
      if (match != null) _peerId = match.id;
    }
    if (clientChanged) {
      unawaited(_loadPeersIfNeeded());
    }
    if (phoneChanged || emailChanged || inboxChanged ||
        oldWidget.extraPhones != widget.extraPhones ||
        oldWidget.clientId != widget.clientId) {
      _bindStreams();
    }
    // Мастер переключился на вкладку «Чат» в карточке заявки — это тот же
    // просмотр переписки, что и открытие карточки: помечаем прочитанным.
    if (widget.embedded &&
        !oldWidget.embeddedVisible &&
        widget.embeddedVisible) {
      _markRead();
    }
  }

  void _bindStreams() {
    _messagesStream = SmsService.streamConversation(
      _phone,
      email: _hasEmail ? _email : null,
      extraPhones: widget.extraPhones,
      emailsOnly: _channel == ConversationChannel.email,
      websiteInbox: widget.websiteInbox,
    );
    _scheduledStream = ScheduledMessageService.streamPendingForConversation(
      _phone,
      email: _hasEmail ? _email : null,
      clientId: widget.clientId,
    );
    _selectedIds.clear();
  }

  ConversationPeer? _findMatchingPeer(String phone, String email) {
    final normPhone = SmsService.normalizePhone(phone);
    final normEmail = email.trim().toLowerCase();
    final peers = _peers;
    for (final peer in peers) {
      if (peer.hasPhone &&
          normPhone.length >= 10 &&
          peer.normalizedPhone == normPhone) {
        return peer;
      }
      if (peer.hasEmail &&
          normEmail.contains('@') &&
          peer.normalizedEmail == normEmail) {
        return peer;
      }
    }
    return peers.isEmpty ? null : peers.first;
  }

  void _applyPeerFromWidget() {
    _phone = widget.phoneNumber;
    _email = (widget.email ?? '').trim();
    _contactName = (widget.contactName ?? '').trim();
    final match = _findMatchingPeer(_phone, _email);
    _peerId = match?.id ?? '';
    if (match != null) {
      _phone = match.phone;
      _email = match.email.trim();
      _contactName = match.displayName;
    }
  }

  void _selectPeer(ConversationPeer peer) {
    setState(() {
      _peerId = peer.id;
      _phone = peer.phone;
      _email = peer.email.trim();
      _contactName = peer.displayName;
      if (!_hasPhone && _hasEmail) {
        _channel = ConversationChannel.email;
      } else if (_hasPhone && _channel == ConversationChannel.email && !_hasEmail) {
        _channel = ConversationChannel.sms;
      }
      _bindStreams();
    });
    widget.onRecipientChanged?.call(peer);
    _markRead();
  }

  void _onDraftChanged() {
    if (mounted) setState(() {});
    // Pre-warm translation cache so Send is instant when the user finishes typing
    _translateDebounce?.cancel();
    final text = _textController.text.trim();
    if (text.length >= 3) {
      _translateDebounce = Timer(
        const Duration(milliseconds: 1500),
        () => _warmTranslation(text),
      );
    }
  }

  void _warmTranslation(String text) {
    if (!mounted) return;
    if (MessageTranslateService.looksRussian(text)) {
      unawaited(MessageTranslateService.toEnglish(text));
    } else if (MessageTranslateService.needsRussian(text)) {
      unawaited(MessageTranslateService.toRussian(text));
    }
  }

  void _markRead() {
    SmsService.markConversationRead(
      _phone,
      email: _hasEmail ? _email : null,
      clientId: widget.clientId,
      websiteInbox: widget.websiteInbox,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    if (_appResumed) _markReadIfVisible();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Карточка снова стала верхней (вернулись «Назад» к уже открытому
    // чату): если за время, пока она была под другими экранами, пришли
    // сообщения — они не прочитаны, хотя мастер их сейчас видит.
    _markReadIfVisible();
  }

  /// Переписка реально перед глазами: приложение на переднем плане, экран
  /// открыт (у карточки — верхний маршрут, у встроенного чата заявки —
  /// ещё и выбранная вкладка «Чат»). Только тогда новое входящее можно
  /// смело отмечать прочитанным сразу.
  bool get _conversationVisible {
    if (!_appResumed) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (widget.embedded && !widget.embeddedVisible) return false;
    return true;
  }

  void _markReadIfVisible() {
    if (!_conversationVisible) return;
    final messages = _threadCache[_threadKey] ?? const <SmsMessage>[];
    for (final message in messages) {
      if (!message.isOutbound && !message.read) {
        _markReadThrottled();
        return;
      }
    }
  }

  /// Отметка «прочитано» — это запрос к Firestore; на каждое событие
  /// стрима её не жжём, но и ждать следующего сообщения не надо.
  void _markReadThrottled() {
    final now = DateTime.now();
    if (_lastAutoMarkAt != null &&
        now.difference(_lastAutoMarkAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastAutoMarkAt = now;
    _markRead();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _translateDebounce?.cancel();
    _highlightTimer?.cancel();
    // Вышли из переписки — всё, что в ней лежало (включая пришедшее,
    // пока мастер её читал), считается просмотренным.
    _markRead();
    _textController.removeListener(_onDraftChanged);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Пикер даты+времени в стиле приложения — лист с двумя строками.
  /// Возвращает null если пользователь отменил.
  Future<DateTime?> _pickScheduleTime() =>
      showScheduleDateTimePicker(context);

  /// Запланировать текущий черновик на [sendAt].
  Future<void> _scheduleMessage(DateTime sendAt) async {
    final text = _textController.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;

    if (_channel == ConversationChannel.email && !_hasEmail) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет email у клиента'.tr), backgroundColor: Colors.red),
      );
      return;
    }
    if (_channel == ConversationChannel.sms && !_hasPhone) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет телефона у клиента'.tr), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() => _isSending = true);
    final pending = List<OutboundAttachment>.from(_attachments);
    _textController.clear();
    setState(() => _attachments.clear());

    try {
      final uploaded = <String>[];
      for (final file in pending) {
        uploaded.add(await OutboundMediaService.upload(file));
      }

      var englishBody = text;
      var russianBody = text;
      if (text.isNotEmpty && MessageTranslateService.looksRussian(text)) {
        englishBody = await MessageTranslateService.toEnglish(text);
        if (MessageTranslateService.failedEnglish(text, englishBody)) englishBody = text;
        russianBody = text;
      }

      await ScheduledMessageService.schedule(
        channel: _channel == ConversationChannel.email ? 'email' : 'sms',
        to: _phone,
        toEmail: _email,
        body: englishBody,
        bodyRu: russianBody != englishBody ? russianBody : '',
        clientId: widget.clientId,
        mediaUrls: uploaded,
        sendAt: sendAt,
      );

      if (!mounted) return;
      setState(() => _isSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${'Запланировано на'.tr} ${Formatters.messageStamp(sendAt)}',
          ),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _textController.text = text;
        _attachments
          ..clear()
          ..addAll(pending);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось запланировать'.tr), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if ((text.isEmpty && _attachments.isEmpty) || _isSending) return;

    if (_channel == ConversationChannel.email && !_hasEmail) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет email у клиента'.tr), backgroundColor: Colors.red),
      );
      return;
    }
    if (_channel == ConversationChannel.sms && !_hasPhone) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет телефона у клиента'.tr), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() => _isSending = true);
    final pending = List<OutboundAttachment>.from(_attachments);
    _textController.clear();
    setState(() => _attachments.clear());

    try {
      final uploaded = <String>[];
      for (final file in pending) {
        uploaded.add(await OutboundMediaService.upload(file));
      }

      var englishBody = text;
      var russianBody = text;
      if (text.isNotEmpty && MessageTranslateService.looksRussian(text)) {
        englishBody = await MessageTranslateService.toEnglish(text);
        russianBody = text;
        if (MessageTranslateService.failedEnglish(text, englishBody)) {
          englishBody = text;
        }
      } else if (text.isNotEmpty) {
        englishBody = text;
        // Russian translation for owner's display is non-blocking — don't hold up send
        if (MessageTranslateService.needsRussian(text)) {
          unawaited(MessageTranslateService.toRussian(text)); // warms cache
        }
      }

      final bool ok;
      if (_channel == ConversationChannel.email) {
        ok = await EmailService.sendEmail(
          to: _email,
          body: englishBody,
          clientId: widget.clientId,
          phone: _phone,
          mediaUrls: uploaded,
          bodyRu: russianBody,
        );
      } else {
        final mms = <String>[];
        final extra = StringBuffer(englishBody);
        for (var i = 0; i < pending.length; i++) {
          if (pending[i].isMmsSafe) {
            mms.add(uploaded[i]);
          } else {
            if (extra.isNotEmpty) extra.writeln();
            extra.write(uploaded[i]);
          }
        }
        ok = await SmsService.sendSms(
          to: _phone,
          body: extra.toString().trim(),
          clientId: widget.clientId,
          mediaUrls: mms,
          bodyRu: russianBody,
        );
      }

      if (!mounted) return;
      setState(() => _isSending = false);

      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось отправить сообщение'.tr), backgroundColor: Colors.red),
        );
        _textController.text = text;
        setState(() {
          _attachments
            ..clear()
            ..addAll(pending);
        });
      } else {
        // Лента перевёрнута: ноль — это низ. Если мастер читал старое,
        // своё отправленное всё равно показываем.
        if (_scrollController.hasClients && _scrollController.offset > 0) {
          _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _textController.text = text;
        _attachments
          ..clear()
          ..addAll(pending);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить сообщение'.tr), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _pickAttachment() async {
    showModalBottomSheet<void>(
      sheetAnimationStyle: AppMotion.sheet,
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.photo_camera, color: AppColors.primary),
                title: Text('Камера'.tr),
                onTap: () async {
                  Navigator.pop(context);
                  await _addAttachment(await OutboundMediaService.pickImage(ImageSource.camera));
                },
              ),
              ListTile(
                leading: Icon(Icons.photo_library, color: AppColors.primary),
                title: Text('Галерея'.tr),
                onTap: () async {
                  Navigator.pop(context);
                  await _addAttachment(await OutboundMediaService.pickImage(ImageSource.gallery));
                },
              ),
              ListTile(
                leading: Icon(Icons.attach_file, color: AppColors.primary),
                title: Text('Файл'.tr),
                onTap: () async {
                  Navigator.pop(context);
                  await _addAttachment(await OutboundMediaService.pickFile());
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _addAttachment(OutboundAttachment? file) async {
    if (file == null || !mounted) return;
    setState(() => _attachments.add(file));
  }

  Future<void> _openMedia(String url) async {
    final lower = url.toLowerCase();
    final isImage = lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.png') ||
        lower.contains('.gif') ||
        lower.contains('.webp');
    if (isImage) {
      _openPhoto(url);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _call() async {
    if (!_hasPhone) return;
    CallScreen.open(
      context,
      phoneNumber: _phone,
      contactName: _contactName.isEmpty ? widget.contactName : _contactName,
    );
  }

  static String _stripSmsHeader(String text) {
    final normalized = text.replaceAll('\r\n', '\n').trim();
    final parts = normalized.split('\n\n');
    if (parts.length >= 2) {
      final first = parts.first.trim().toLowerCase();
      if (first.contains('fix-appliance') ||
          first.contains('fixappliance') ||
          first.contains('fix appliance')) {
        return parts.sublist(1).join('\n\n').trim();
      }
    }
    return normalized;
  }

  /// Диалог целиком — и вопросы мастера, и ответы клиента, с временем
  /// каждого сообщения. Иначе реплика клиента «Yes» или «door is 128»
  /// висит в воздухе без вопроса мастера «461 Blackburn Dr, Brantford?».
  String _buildConversationTranscript(List<SmsMessage> allMessages) {
    final fmt = DateFormat('yyyy-MM-dd HH:mm');
    final lines = <String>[];
    for (final m in allMessages) {
      if (m.isDeleted || m.sendingRejected || m.awaitingApproval) continue;
      final rawBody =
          m.body.trim().isNotEmpty ? m.body.trim() : m.bodyRu.trim();
      final body = m.isOutbound ? _stripSmsHeader(rawBody) : rawBody;
      final parts = <String>[
        if (m.subject.trim().isNotEmpty) m.subject.trim(),
        if (body.isNotEmpty) body,
      ];
      if (parts.isEmpty) continue;
      final who = m.isOutbound ? 'Мастер' : 'Клиент';
      final when = m.createdAt != null ? '[${fmt.format(m.createdAt!)}] ' : '';
      lines.add('$when$who: ${parts.join('\n')}');
    }
    return lines.join('\n');
  }

  Future<void> _createJobFromSelected() => _createJob(onlySelected: true);

  /// «Создать заявку» из переписки (всей или только выделенных сообщений).
  /// Сообщения разбираются ИИ: имя, адрес, техника, поломка и дата визита
  /// подставляются в экран «Проверьте данные», который сам заводит карточку
  /// клиента (если её ещё нет) и заявку.
  Future<void> _createJob({bool onlySelected = false}) async {
    if (_creatingJob) return;
    final allMessages =
        _threadCache[_threadKey] ?? await _messagesStream.first;
    final selectedSet = Set<String>.from(_selectedIds);
    final sourceMessages = onlySelected && selectedSet.isNotEmpty
        ? [for (final m in allMessages) if (selectedSet.contains(m.id)) m]
        : allMessages;
    if (sourceMessages.isEmpty) return;
    final inbound = sourceMessages.where((m) => !m.isOutbound).toList();

    // SMS, которую ИИ пометил как заявку на ремонт: у неё уже разобраны
    // техника и неисправность, и после создания заявки она помечается
    // «принята», чтобы карточка в шторке погасла.
    SmsMessage? offer;
    for (final message in inbound) {
      if (message.smsOfferPending && (message.jobId ?? '').trim().isEmpty) {
        offer = message;
        break;
      }
    }
    if (offer == null && onlySelected) {
      for (final message in inbound) {
        if (message.extractedData != null &&
            message.extractedData!.isNotEmpty) {
          offer = message;
          break;
        }
      }
    }

    final conversationText = _buildConversationTranscript(sourceMessages);
    final plainSelectedBody = onlySelected
        ? [
            for (final m in sourceMessages)
              if ((m.body.trim().isNotEmpty ? m.body.trim() : m.bodyRu.trim())
                  .isNotEmpty)
                m.isOutbound
                    ? _stripSmsHeader(
                        m.body.trim().isNotEmpty ? m.body.trim() : m.bodyRu.trim(),
                      )
                    : (m.body.trim().isNotEmpty ? m.body.trim() : m.bodyRu.trim()),
          ].where((s) => s.isNotEmpty).join('\n')
        : '';

    // Найти существующего клиента в базе: по id, по телефону переписки,
    // по email или по контактам в переписке.
    Client? existingClient;
    final cid = (widget.clientId ?? '').trim();
    if (cid.isNotEmpty) {
      existingClient = await ClientService.getById(cid);
      if (existingClient != null && existingClient.isDeleted) {
        existingClient = null;
      }
    }
    if (existingClient == null && _hasPhone) {
      existingClient = await ClientService.findByPhone(_phone);
    }
    if (existingClient == null && _hasEmail) {
      existingClient = await ClientService.findByEmail(_email);
    }
    if (existingClient == null) {
      for (final peer in _peers) {
        if (peer.hasPhone) {
          existingClient = await ClientService.findByPhone(peer.phone);
          if (existingClient != null) break;
        }
        if (peer.hasEmail) {
          existingClient = await ClientService.findByEmail(peer.email);
          if (existingClient != null) break;
        }
      }
    }

    // Разобрать переписку целиком: «меня зовут Рохан, холодильник не
    // морозит» → имя, техника и поломка уже в форме, а не пустые поля.
    setState(() => _creatingJob = true);
    ExtractedJobData? fromAi;
    try {
      if (conversationText.trim().isNotEmpty) {
        fromAi = await AiService.extractJobData(conversationText);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AiService.isBusyError(e)
                ? 'ИИ перегружен, попробуйте позже'.tr
                : 'Ошибка ИИ'.tr,
          ),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _creatingJob = false);
    }

    // Что ИИ не разобрал — добираем из SMS-заявки и из самой переписки.
    final offerData = offer != null &&
            offer.extractedData != null &&
            offer.extractedData!.isNotEmpty
        ? ExtractedJobData.fromJson(offer.extractedData!)
        : null;

    if (existingClient == null) {
      final aiPhone = fromAi?.clientPhone ?? offerData?.clientPhone;
      if (aiPhone != null && aiPhone.trim().isNotEmpty) {
        existingClient = await ClientService.findByPhone(aiPhone);
      }
    }
    if (existingClient == null) {
      final aiEmail = fromAi?.clientEmail ?? offerData?.clientEmail;
      if (aiEmail != null && aiEmail.contains('@')) {
        existingClient = await ClientService.findByEmail(aiEmail);
      }
    }

    // Телефон из переписки надёжнее: ИИ просят отдавать 10 цифр без «+1»,
    // а карточка и нить SMS знают полный номер. Чужой номер от ИИ (клиент
    // дал другой в письме) не затираем.
    String? resolvedPhone;
    if (_hasPhone) {
      final aiPhone = fromAi?.clientPhone ?? offerData?.clientPhone;
      resolvedPhone = aiPhone != null &&
              SmsService.normalizePhone(aiPhone) !=
                  SmsService.normalizePhone(_phone)
          ? aiPhone
          : _phone;
    } else {
      resolvedPhone =
          fromAi?.clientPhone ?? offerData?.clientPhone ?? existingClient?.phone;
    }

    final extracted = ExtractedJobData(
      clientName: fromAi?.clientName ??
          offerData?.clientName ??
          existingClient?.fullName,
      clientPhone: resolvedPhone,
      clientEmail: fromAi?.clientEmail ??
          offerData?.clientEmail ??
          (_hasEmail ? _email : existingClient?.email),
      address: fromAi?.address ?? offerData?.address,
      unit: fromAi?.unit ?? offerData?.unit,
      city: fromAi?.city ?? offerData?.city,
      postalCode: fromAi?.postalCode ?? offerData?.postalCode,
      applianceType: fromAi?.applianceType ?? offerData?.applianceType,
      brand: fromAi?.brand ?? offerData?.brand,
      model: fromAi?.model ?? offerData?.model,
      problemDescription:
          fromAi?.problemDescription ??
          offerData?.problemDescription ??
          (plainSelectedBody.isNotEmpty ? plainSelectedBody : null),
      scheduledDate: fromAi?.scheduledDate ?? offerData?.scheduledDate,
      scheduledTime: fromAi?.scheduledTime ?? offerData?.scheduledTime,
      contactOnSiteName:
          fromAi?.contactOnSiteName ?? offerData?.contactOnSiteName,
      contactOnSitePhone:
          fromAi?.contactOnSitePhone ?? offerData?.contactOnSitePhone,
      hasJobSite:
          (fromAi?.hasJobSite ?? false) || (offerData?.hasJobSite ?? false),
      notes: fromAi?.notes ?? offerData?.notes,
    );

    if (!mounted) return;
    final resolvedClientId = existingClient?.id ??
        ((widget.clientId ?? '').trim().isNotEmpty ? widget.clientId : null);
    final result = await AppNav.navigatorOf(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => JobPreviewScreen(
          extractedData: extracted,
          originalText: conversationText,
          fallbackPhone: _hasPhone ? _phone : existingClient?.phone,
          fallbackEmail: _hasEmail ? _email : existingClient?.email,
          existingClientId: resolvedClientId,
          existingClient: existingClient,
          sourceSmsId: offer?.id,
        ),
      ),
    );
    if (result == true && mounted) {
      if (onlySelected) _clearSelection();
      setState(() => _jobLinkRevision++);
    }
  }

  Future<void> _openClientCard() async {
    Client? client;
    final id = (widget.clientId ?? '').trim();
    if (id.isNotEmpty) {
      client = await ClientService.getById(id);
    }
    client ??= await ClientService.findByPhone(_phone);
    if (client == null && _email.contains('@')) {
      client = await ClientService.findByEmail(_email);
    }
    if (!mounted) return;
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Нет карточки клиента'.tr),
          action: SnackBarAction(
            label: 'Создать заявку'.tr,
            onPressed: _createJob,
          ),
        ),
      );
      return;
    }
    await AppNav.openCard(
      context,
      key: AppNav.clientKey(client.id),
      builder: (_) => ClientDetailsScreen(
        clientId: client!.id,
        clientData: client.toUiMap(),
      ),
    );
  }

  /// Извлекает имя и адрес из входящих сообщений через Gemini
  /// и открывает карточку клиента с предзаполненными полями для подтверждения.
  Future<void> _extractAndApplyToClient() async {
    // Найти клиента — по id, потом по телефону, потом по email
    Client? client;
    final cid = (widget.clientId ?? '').trim();
    if (cid.isNotEmpty) {
      client = await ClientService.getById(cid);
    }
    client ??= await ClientService.findByPhone(_phone);
    if (client == null && _email.contains('@')) {
      client = await ClientService.findByEmail(_email);
    }
    if (!mounted) return;
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет карточки клиента'.tr)),
      );
      return;
    }

    final allMessages =
        _threadCache[_threadKey] ?? await _messagesStream.first;
    final conversationText = _buildConversationTranscript(allMessages);
    if (conversationText.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Нет входящих сообщений'.tr)),
      );
      return;
    }

    setState(() => _extracting = true);
    try {
      final extracted = await AiService.extractJobData(conversationText);
      if (!mounted) return;

      if (extracted.clientName == null && extracted.address == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Имя и адрес не найдены в переписке'.tr),
          ),
        );
        return;
      }

      // Смержить с текущими данными клиента
      final mergedData = Map<String, dynamic>.from(client.toUiMap());
      if (extracted.clientName != null) {
        mergedData['fullName'] = extracted.clientName!;
        mergedData['name'] = extracted.clientName!;
      }
      if (extracted.address != null) {
        final unitPart = (extracted.unit ?? '').trim();
        final addrParts = <String>[
          extracted.address!,
          if (unitPart.isNotEmpty) 'Unit $unitPart',
        ];
        if ((extracted.city ?? '').isNotEmpty) addrParts.add(extracted.city!);
        if ((extracted.postalCode ?? '').isNotEmpty) addrParts.add(extracted.postalCode!);
        mergedData['address'] = addrParts.join(', ');
      }

      // Открыть EditClientSheet с предзаполненными данными
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: AppColors.card,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => EditClientSheet(
          clientId: client!.id,
          currentData: mergedData,
          extractName: (data) {
            for (final k in ['fullName', 'name', 'clientName']) {
              final v = data[k]?.toString().trim() ?? '';
              if (v.isNotEmpty) return v;
            }
            return 'Без имени'.tr;
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AiService.isBusyError(e)
                ? 'ИИ перегружен, попробуйте позже'.tr
                : 'Ошибка ИИ'.tr,
          ),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  bool _isImageMediaUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.png') ||
        lower.contains('.gif') ||
        lower.contains('.webp');
  }

  void _openPhoto(String url) {
    final messages = _threadCache[_threadKey] ?? const <SmsMessage>[];
    final urls = <String>[];
    for (final m in messages) {
      if (m.isDeleted) continue;
      for (final mediaUrl in m.mediaUrls) {
        if (_isImageMediaUrl(mediaUrl) && !urls.contains(mediaUrl)) {
          urls.add(mediaUrl);
        }
      }
    }
    if (!urls.contains(url)) {
      urls.add(url);
    }
    final initialIndex = urls.indexOf(url);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenGallery(
          images: [
            for (final itemUrl in urls) {'url': itemUrl},
          ],
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
        ),
      ),
    );
  }

  /// Шаблон в поле ввода. Подстановки заполняем здесь: иначе клиенту уходило
  /// буквальное «{review}» вместо ссылки на отзыв.
  Future<String> _resolveTemplate(String body) async {
    var text = body;
    if (SmsText.hasPlaceholder(text, 'name')) {
      // «Клиент +14165550101» — это подпись карточки, а не имя: такое уходило
      // клиенту в SMS. Нет имени — нет и обращения.
      text = SmsText.fillName(
        text,
        _contactName.isNotEmpty ? _contactName : (widget.contactName ?? ''),
      );
    }
    if (SmsText.hasPlaceholder(text, 'review')) {
      final config = await SettingsService.loadConfig();
      text = SmsText.replacePlaceholder(
        text,
        'review',
        SettingsService.readGoogleReviewUrl(config),
      );
    }
    if (SmsText.hasPlaceholder(text, 'company') ||
        SmsText.hasPlaceholder(text, 'phone') ||
        SmsText.hasPlaceholder(text, 'email') ||
        SmsText.hasPlaceholder(text, 'hst') ||
        SmsText.hasPlaceholder(text, 'valid_days')) {
      final docs = await SettingsService.loadDocumentSettings();
      text = SmsText.replacePlaceholder(text, 'company', docs.companyName);
      text = SmsText.replacePlaceholder(text, 'phone', docs.companyPhone);
      text = SmsText.replacePlaceholder(text, 'email', docs.companyEmail);
      text = SmsText.replacePlaceholder(text, 'hst', docs.hstNumber);
      text = SmsText.replacePlaceholder(
        text,
        'valid_days',
        '${docs.estimateValidDays}',
      );
    }

    final needsJobContext = SmsText.hasPlaceholder(text, 'date') ||
        SmsText.hasPlaceholder(text, 'time') ||
        SmsText.hasPlaceholder(text, 'address') ||
        SmsText.hasPlaceholder(text, 'total') ||
        SmsText.hasPlaceholder(text, 'due') ||
        SmsText.hasPlaceholder(text, 'paid') ||
        SmsText.hasPlaceholder(text, 'amount') ||
        SmsText.hasPlaceholder(text, 'items') ||
        SmsText.hasPlaceholder(text, 'url');

    if (needsJobContext) {
      Job? job;
      Client? client;
      try {
        final jid = (widget.jobId ?? '').trim();
        if (jid.isNotEmpty) {
          job = await JobService.getById(jid);
        }
        var cid = (widget.clientId ?? '').trim();
        if (cid.isEmpty && job != null && job.clientId.trim().isNotEmpty) {
          cid = job.clientId.trim();
        }
        if (cid.isNotEmpty) {
          client = await ClientService.getById(cid);
        } else if (_phone.trim().isNotEmpty) {
          client = await ClientService.findByPhone(_phone);
          if (client != null) cid = client.id;
        }
        if (job == null && cid.isNotEmpty) {
          final snap = await FirestoreService.jobsRef
              .where('clientId', isEqualTo: cid)
              .get();
          final jobs = <Job>[];
          for (final doc in snap.docs) {
            final parsed = Job.fromMap(
              doc.data() as Map<String, dynamic>,
              doc.id,
            );
            if (!parsed.isDeleted) jobs.add(parsed);
          }
          if (jobs.isNotEmpty) {
            jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
            final peerDigits = SmsService.normalizePhone(_phone);
            final bySitePhone = peerDigits.length >= 10
                ? jobs
                      .where(
                        (j) =>
                            SmsService.normalizePhone(j.jobSitePhone ?? '') ==
                            peerDigits,
                      )
                      .toList()
                : const <Job>[];
            final pool = bySitePhone.isNotEmpty ? bySitePhone : jobs;
            job = pool.firstWhere(
              (j) => j.activeVisits.isNotEmpty,
              orElse: () => pool.first,
            );
          }
        }
      } catch (_) {}

      final visit = job?.nextActiveVisit() ?? job?.latestVisit;
      if (visit != null) {
        final clock = AppTimeService.bookingWallClock(visit.startAt);
        final dateStr = DateFormat('MMMM d', 'en_US').format(clock);
        final timeStr = DateFormat('HH:mm').format(clock);
        text = SmsText.replacePlaceholder(text, 'date', dateStr);
        text = SmsText.replacePlaceholder(text, 'time', timeStr);
      }
      final addr = (job?.workAddress ?? '').trim().isNotEmpty
          ? job!.workAddress.trim()
          : (client?.address ?? '').trim();
      if (addr.isNotEmpty) {
        text = SmsText.replacePlaceholder(text, 'address', addr);
      }

      if (job != null && job.documents.isNotEmpty) {
        Map<String, dynamic>? activeDoc;
        for (final doc in job.documents.reversed) {
          if (!Job.isDocumentTrashed(doc)) {
            activeDoc = doc;
            break;
          }
        }
        if (activeDoc != null) {
          final total = Job.documentTotal(activeDoc);
          final paid = Job.documentPaid(activeDoc);
          final due = (total - paid) > 0 ? (total - paid) : 0.0;
          final amount = due > 0 ? due : total;
          final items = DocumentSettings.formatItems(
            activeDoc['items'] is List
                ? activeDoc['items'] as List
                : const [],
          );
          text = SmsText.replacePlaceholder(
            text,
            'total',
            Formatters.formatCurrency(total),
          );
          text = SmsText.replacePlaceholder(
            text,
            'due',
            Formatters.formatCurrency(due),
          );
          text = SmsText.replacePlaceholder(
            text,
            'paid',
            Formatters.formatCurrency(paid),
          );
          text = SmsText.replacePlaceholder(
            text,
            'amount',
            Formatters.formatCurrency(amount),
          );
          text = SmsText.replacePlaceholder(text, 'items', items);

          var docUrl = '';
          final stripe = activeDoc['stripe'];
          if (stripe is Map) {
            docUrl = (stripe['shortUrl'] ?? stripe['url'] ?? '')
                .toString()
                .trim();
          }
          if (docUrl.isEmpty) {
            docUrl = (activeDoc['pdfShortUrl'] ??
                    activeDoc['pdfUrl'] ??
                    activeDoc['confirmShortUrl'] ??
                    activeDoc['confirmLongUrl'] ??
                    '')
                .toString()
                .trim();
          }
          if (docUrl.isNotEmpty) {
            text = SmsText.replacePlaceholder(text, 'url', docUrl);
          }
        }
      }
    }
    return text.trim();
  }

  Future<void> _showSmsTemplates({ValueChanged<String>? onSelect}) async {
    final results = await Future.wait([
      SettingsService.loadSmsTemplates(),
      SettingsService.loadSmsTemplateTitles(),
      SettingsService.loadChatCustomTemplates(),
    ]);
    var templates = results[0] as Map<String, String>;
    var titles = results[1] as Map<String, String>;
    var custom = results[2] as List<Map<String, String>>;
    if (!mounted) return;

    const sections = <String>[
      'В пути и работа',
      'Визиты',
      'Документы и оплата',
    ];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> reloadSheet() async {
              final next = await Future.wait([
                SettingsService.loadSmsTemplates(),
                SettingsService.loadSmsTemplateTitles(),
                SettingsService.loadChatCustomTemplates(),
              ]);
              if (!sheetContext.mounted) return;
              setSheetState(() {
                templates = next[0] as Map<String, String>;
                titles = next[1] as Map<String, String>;
                custom = next[2] as List<Map<String, String>>;
              });
            }

            String titleFor(
              ({
                String key,
                String section,
                String defaultTitle,
                IconData icon,
                Color color,
              }) spec,
            ) {
              final customTitle = (titles[spec.key] ?? '').trim();
              return customTitle.isNotEmpty ? customTitle : spec.defaultTitle.tr;
            }

            return SafeArea(
              child: DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.72,
                minChildSize: 0.4,
                maxChildSize: 0.94,
                builder: (context, scrollController) {
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                context.tr('Выбрать шаблон', 'Choose template'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () async {
                                await Navigator.push<void>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const MessageTemplatesPage(),
                                  ),
                                );
                                await reloadSheet();
                              },
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              label: Text('Настроить'.tr),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView(
                          controller: scrollController,
                          children: [
                            if (custom.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  4,
                                ),
                                child: Text(
                                  'Мои шаблоны'.tr,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.inkMuted,
                                  ),
                                ),
                              ),
                              for (final item in custom)
                                ListTile(
                                  leading: Icon(
                                    Icons.chat_bubble_outline,
                                    color: AppColors.primaryOnCard,
                                  ),
                                  title: Text(
                                    item['title'] ?? '',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    item['body'] ?? '',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () async {
                                    Navigator.pop(sheetContext);
                                    final text = await _resolveTemplate(
                                      item['body'] ?? '',
                                    );
                                    if (onSelect != null) {
                                      onSelect(text);
                                    } else {
                                      if (!mounted) return;
                                      setState(
                                        () => _textController.text = text,
                                      );
                                    }
                                  },
                                ),
                              const Divider(height: 16),
                            ],
                            for (var s = 0; s < sections.length; s++) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  10,
                                  16,
                                  4,
                                ),
                                child: Text(
                                  sections[s].tr,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.inkMuted,
                                  ),
                                ),
                              ),
                              for (final item
                                  in SettingsService.builtinSmsSpecs.where(
                                    (spec) => spec.section == sections[s],
                                  ))
                                ListTile(
                                  leading: Icon(item.icon, color: item.color),
                                  title: Text(
                                    titleFor(item),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    templates[item.key] ?? '',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () async {
                                    Navigator.pop(sheetContext);
                                    final text = await _resolveTemplate(
                                      templates[item.key] ?? '',
                                    );
                                    if (onSelect != null) {
                                      onSelect(text);
                                    } else {
                                      if (!mounted) return;
                                      setState(
                                        () => _textController.text = text,
                                      );
                                    }
                                  },
                                ),
                              if (s < sections.length - 1)
                                const Divider(height: 16),
                            ],
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final thread = Column(
      children: [
        if (_peers.length > 1) _buildRecipientBar(),
        Expanded(
          child: StreamBuilder<List<SmsMessage>>(
            key: ValueKey(_threadKey),
            stream: _messagesStream,
            builder: (context, snapshot) {
              final key = _threadKey;
              if (snapshot.hasData) {
                _threadCache[key] = snapshot.data!;
              }
              final messages = snapshot.data ?? _threadCache[key] ?? [];

              if (messages.isEmpty &&
                  snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (messages.isEmpty) {
                return Center(
                  child: Text(
                    _channel == ConversationChannel.email
                        ? (widget.websiteInbox
                            ? 'Письма с сайта'.tr
                            : 'Нет писем — напишите первым'.tr)
                        : 'Нет SMS — напишите первым'.tr,
                    style: const TextStyle(color: Colors.grey),
                  ),
                );
              }

              _visibleIds = [for (final message in messages) message.id];
              if (_highlightId != null && _visibleIds.contains(_highlightId)) {
                _revealHighlight();
              }
              // Пришло новое, пока мастер смотрит в эту переписку —
              // отметка не ждёт выхода: бейдж и шторка не должны врать.
              _markReadIfVisible();

              // Лента перевёрнута: offset 0 — это низ, последнее сообщение.
              // Так низ держится сам, и прокрутку к нему звать не надо.
              // Раньше здесь был jumpTo(maxScrollExtent) в postFrame: у
              // ListView.builder до раскладки всех пузырей maxScrollExtent —
              // грубая оценка (у нас 8173 против настоящих 5452), прыжок
              // уезжал за конец, и BouncingScrollPhysics потом секунду
              // медленно подтягивала ленту обратно — это и был рывок. Любая
              // смена высоты выше экрана (картинка догрузилась, появился
              // «Перевод…») запускала то же самое заново.
              return ListView.builder(
                controller: _scrollController,
                reverse: true,
                padding: const EdgeInsets.all(16),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final msgIndex = messages.length - 1 - index;
                  final message = messages[msgIndex];
                  final showDayDivider =
                      message.createdAt != null &&
                      (msgIndex == 0 ||
                          !_isSameMessageDay(
                            messages[msgIndex - 1].createdAt,
                            message.createdAt,
                          ));
                  final bubble = _highlightWrap(
                    message,
                    _buildBubble(message),
                  );
                  if (!showDayDivider) return bubble;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildDayDivider(message.createdAt),
                      bubble,
                    ],
                  );
                },
              );
            },
          ),
        ),
        if (!widget.websiteInbox && !_selecting) _buildScheduledBanner(),
        // Действия выбора внизу вместо поля ввода — под большим пальцем.
        if (_selecting)
          SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!widget.websiteInbox && _singleSelectedMessage() != null)
                  _buildSelectionReactionBar(_singleSelectedMessage()!),
                SelectionActionBar(
                  count: _selectedIds.length,
                  onCancel: _clearSelection,
                  onCreateJob:
                      widget.websiteInbox ? null : _createJobFromSelected,
                  creatingJob: _creatingJob,
                  onSelectAll: _selectAllVisible,
                  onCopy: _copySelected,
                  onDelete: _deleteSelected,
                ),
              ],
            ),
          )
        else if (!widget.websiteInbox)
          _buildInputBar(),
      ],
    );

    if (widget.embedded) {
      return ColoredBox(color: AppColors.surface, child: thread);
    }

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selecting) _clearSelection();
      },
      child: Scaffold(
        backgroundColor: AppColors.surface,
        appBar: _selecting
            ? AppBar(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _clearSelection,
                ),
                title: Text('${_selectedIds.length}'),
              )
            : AppBar(
                title: ValueListenableBuilder<int>(
                  valueListenable: ClientService.regularRevision,
                  builder: (context, _, _) {
                    final isRegular =
                        !widget.websiteInbox &&
                        ClientService.isRegularClient(
                          clientId: widget.clientId,
                          phone: _phone,
                          email: _email,
                        );
                    final rawTitle = _contactName.isNotEmpty
                        ? _contactName
                        : (widget.contactName ?? '');
                    final titleText = widget.websiteInbox
                        ? kWebsiteInboxTitle.tr
                        : SmsText.stripClientWord(
                            rawTitle,
                            _hasPhone ? _phone : _email,
                          );
                    final subParts = [
                      if (_hasPhone &&
                          SmsService.normalizePhone(titleText) !=
                              SmsService.normalizePhone(_phone))
                        _phone,
                      if (_hasEmail &&
                          titleText.toLowerCase() != _email.toLowerCase())
                        _email,
                    ];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                titleText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                            if (isRegular)
                              const RegularClientStar(size: 18, onDark: true),
                          ],
                        ),
                        if (!widget.websiteInbox && subParts.isNotEmpty)
                          Text(
                            subParts.join(' · '),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.normal,
                            ),
                          ),
                      ],
                    );
                  },
                ),
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                actions: _quickActions(),
              ),
        body: thread,
      ),
    );
  }

  bool _isSameMessageDay(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    final wa = AppTimeService.wallClock(a);
    final wb = AppTimeService.wallClock(b);
    return wa.year == wb.year && wa.month == wb.month && wa.day == wb.day;
  }

  String _dayDividerLabel(DateTime? date) {
    if (date == null) return '';
    final value = AppTimeService.wallClock(date);
    final now = AppTimeService.wallClock(DateTime.now());
    final shift = DateTime(value.year, value.month, value.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final datePart = DateFormat(
      value.year == now.year ? 'd MMMM' : 'd MMMM yyyy',
      AppLocale.instance.dateLocale,
    ).format(value);
    if (shift == 0) return '${'Сегодня'.tr}, $datePart';
    if (shift == -1) return '${'Вчера'.tr}, $datePart';
    return datePart;
  }

  Widget _buildDayDivider(DateTime? date) {
    if (date == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 14),
      child: Row(
        children: [
          Expanded(child: Divider(height: 1, color: AppColors.border)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                _dayDividerLabel(date),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.inkMuted,
                ),
              ),
            ),
          ),
          Expanded(child: Divider(height: 1, color: AppColors.border)),
        ],
      ),
    );
  }

  Widget _buildBubble(SmsMessage message) {
    final isOutbound = message.isOutbound;
    // Сообщение, которое придумал сервер, ждёт решения мастера. Рисуем его
    // не голубым «отправлено», а черновиком с кнопками — иначе
    // неотправленный текст выглядит в переписке как ушедший клиенту.
    final waiting = message.awaitingApproval;
    final refused = message.sendingRejected;
    final onDark = AppColors.isDark;
    final selected = _selectedIds.contains(message.id);
    final outboundBg = AppColors.isDark
        ? const Color(0xFF153E5C)
        : const Color(0xFFD4ECFF);
    final inboundBg = AppColors.isDark
        ? const Color(0xFF3E3210)
        : const Color(0xFFFFF3C4);
    final bubbleBorderColor = waiting
        ? Colors.orange.shade300
        : refused
            ? AppColors.border
            : isOutbound
                ? const Color(0xFF64B5F6).withValues(alpha: 0.55)
                : const Color(0xFFFFD54F).withValues(alpha: 0.65);
    // Долгое нажатие выделяет сообщение, двойное касание по тексту — слова
    // внутри него. Порог долгого нажатия укорочен, иначе жест забирает себе
    // выделение текста (см. QuickLongPress).
    return QuickLongPress(
      onLongPress: () => _toggleSelected(message.id),
      onTap: _selecting ? () => _toggleSelected(message.id) : null,
      child: Align(
      alignment: isOutbound ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // Значок собеседника слева от его сообщения, мой — справа от моего,
        // оба у нижнего края пузыря, как в обычном мессенджере.
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_selecting && !isOutbound)
            Padding(
              padding: const EdgeInsets.only(right: 6, bottom: 10),
              child: SelectCheckbox(selected: selected),
            ),
          if (!isOutbound) _senderAvatar(outbound: false),
          Flexible(
            child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.selectedCard
              : waiting
                  ? AppColors.tint(AppColors.accent, 0.16)
                  : refused
                      ? AppColors.cardMuted
                      : (isOutbound ? outboundBg : inboundBg),
          border: Border.all(
            color: bubbleBorderColor,
            width: waiting ? 1.5 : 1.0,
          ),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isOutbound ? 14 : 2),
            bottomRight: Radius.circular(isOutbound ? 2 : 14),
          ),
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  waiting
                      ? Icons.schedule_send_rounded
                      : refused
                          ? Icons.block_rounded
                          : (message.isEmail ? Icons.email : Icons.sms),
                  size: 14,
                  color: onDark
                      ? Colors.white70
                      : waiting
                          ? Colors.orange.shade800
                          : refused
                              ? Colors.grey.shade600
                              : (message.isEmail
                                  ? const Color(0xFFEA4335)
                                  : Colors.indigo),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    waiting
                        ? 'Ждёт вашего разрешения'.tr
                        : refused
                            ? 'Не отправлено'.tr
                            : message.isEmail
                        ? (isOutbound
                            ? '${'Кому'.tr}: ${message.toEmail.isNotEmpty ? message.toEmail : message.to}'
                            : '${'От'.tr}: ${message.fromEmail.isNotEmpty ? message.fromEmail : message.from}')
                        : (isOutbound ? 'SMS'.tr : '${'От'.tr}: ${message.from}'),
                    style: TextStyle(
                      color: onDark
                          ? Colors.white70
                          : waiting
                              ? (AppColors.isDark
                                  ? const Color(0xFFFFCA28)
                                  : Colors.orange.shade900)
                              : AppColors.inkMuted,
                      fontSize: 11,
                      fontWeight: waiting ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (message.isEmail && message.subject.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                message.subject.trim(),
                style: TextStyle(
                  color: onDark ? Colors.white : AppColors.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 6),
            if (message.mediaUrls.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  children: [
                    for (final url in message.mediaUrls)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _buildMediaPreview(url, onDark),
                      ),
                  ],
                ),
              )
            else if (message.hasPendingMedia ||
                (message.body.trim().isEmpty && message.aiStatus == 'processing'))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  height: 120,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: AppColors.cardMuted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.aiStatus == 'processing')
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      Text(
                        message.aiStatus == 'processing' ? 'Загружается фото…'.tr : 'Фото'.tr,
                        style: TextStyle(color: AppColors.inkMuted),
                      ),
                    ],
                  ),
                ),
              ),
            if (message.body.trim().isNotEmpty)
              _TranslatedMessageBody(
                message: message,
                isOutbound: onDark,
                // Пока идёт выделение сообщений, нажатия забирают галочки.
                interactive: !_selecting,
              ),
            if (message.extractedData != null &&
                (message.extractedData!['model'] != null ||
                    message.extractedData!['brand'] != null))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  [
                    if (message.extractedData!['brand'] != null)
                      '${'Бренд'.tr}: ${message.extractedData!['brand']}',
                    if (message.extractedData!['model'] != null)
                      '${'Модель'.tr}: ${message.extractedData!['model']}',
                    if (message.jobId != null) 'Добавлено в заявку'.tr,
                  ].join(' · '),
                  style: TextStyle(
                    color: onDark ? Colors.white70 : AppColors.primaryOnCard,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (waiting) _approvalButtons(message),
            // Оператор мог зарезать SMS уже после отправки (Twilio 30007).
            // Без этой пометки такое сообщение выглядело доставленным.
            if (message.deliveryFailed) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFD32F2F),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 14,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '${'Не доставлено'.tr}: ${message.failureReason}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              mainAxisSize: MainAxisSize.max,
              children: [
                if (!widget.websiteInbox && !waiting && !refused) ...[
                  _buildReactionButton(message, onDark),
                  const SizedBox(width: 8),
                ],
                Text(
                  Formatters.formatTime(message.createdAt),
                  style: TextStyle(
                    color: onDark ? Colors.white70 : Colors.grey.shade500,
                    fontSize: 11,
                  ),
                ),
                _deliveryMark(message, onDark),
              ],
            ),
          ],
        ),
      ),
          ),
          if (isOutbound) _senderAvatar(outbound: true),
          if (_selecting && isOutbound)
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 10),
              child: SelectCheckbox(selected: selected),
            ),
        ],
      ),
    ),
    );
  }

  /// Кружок у пузыря: у клиента — первая буква имени (или человечек), у
  /// мастерской — логотип приложения.
  Widget _senderAvatar({required bool outbound}) {
    const size = 30.0;
    final Widget avatar;
    if (outbound) {
      avatar = const CompanyLogo(size: size);
    } else {
      final name =
          (_contactName.isNotEmpty ? _contactName : (widget.contactName ?? ''))
              .trim();
      final first = name.isEmpty ? '' : name.characters.first.toUpperCase();
      final letter = RegExp(r'\p{L}', unicode: true).hasMatch(first);
      avatar = Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.isDark
              ? const Color(0xFF5C4A12)
              : const Color(0xFFFFE082),
          border: Border.all(
            color: const Color(0xFFFFD54F).withValues(alpha: 0.9),
          ),
        ),
        child: letter
            ? Text(
                first,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: AppColors.isDark ? Colors.white : AppColors.ink,
                ),
              )
            : Icon(
                Icons.person_rounded,
                size: 19,
                color: AppColors.isDark ? Colors.white : AppColors.ink,
              ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(
        left: outbound ? 6 : 0,
        right: outbound ? 0 : 6,
        bottom: 10,
      ),
      child: avatar,
    );
  }

  /// Галочка доставки под исходящим SMS: отправлено → доставлено → прочитано.
  ///
  /// Статус приносит Twilio (`smsStatusCallback`). «Прочитано» обычные SMS не
  /// отдают — такую квитанцию дают только RCS и WhatsApp, поэтому у телефонов
  /// почти всегда потолок «Доставлено». Недоставленное рисует красная плашка
  /// выше, здесь его не дублируем. У писем галочек нет: там этих статусов нет.
  Widget _deliveryMark(SmsMessage message, bool onDark) {
    if (message.isEmail) return const SizedBox.shrink();
    final state = message.delivery;
    if (state == SmsDelivery.none || state == SmsDelivery.failed) {
      return const SizedBox.shrink();
    }
    // Подписи через context.tr: в словаре en_ui «Отправлено» уже занято
    // статусом доставки запчасти («Shipped»), а здесь нужно «Sent».
    final (IconData icon, String label) = switch (state) {
      SmsDelivery.queued => (
          Icons.schedule_rounded,
          context.tr('Отправляется', 'Sending'),
        ),
      SmsDelivery.sent => (Icons.done_rounded, context.tr('Отправлено', 'Sent')),
      SmsDelivery.delivered => (
          Icons.done_all_rounded,
          context.tr('Доставлено', 'Delivered'),
        ),
      SmsDelivery.read => (
          Icons.done_all_rounded,
          context.tr('Прочитано', 'Read'),
        ),
      _ => (Icons.done_rounded, ''),
    };
    final color = state == SmsDelivery.read
        ? (onDark ? const Color(0xFF8BE9FD) : Colors.lightBlue.shade700)
        : (onDark ? Colors.white70 : Colors.grey.shade600);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 3),
          Icon(icon, size: 13, color: color),
        ],
      ),
    );
  }

  /// «Отправить» / «Не отправлять» под текстом, который придумал сервер.
  /// Пока решение не принято, клиенту ничего не ушло.
  Widget _approvalButtons(SmsMessage message) {
    final busy = _decidingIds.contains(message.id);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: busy ? null : () => _decideOutbox(message, send: true),
              icon: const Icon(Icons.send_rounded, size: 18),
              label: Text('Отправить'.tr),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF22C55E),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: busy ? null : () => _decideOutbox(message, send: false),
              icon: const Icon(Icons.close_rounded, size: 18),
              label: Text('Не отправлять'.tr),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE53935),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _decideOutbox(SmsMessage message, {required bool send}) async {
    if (_decidingIds.contains(message.id)) return;
    AppFeedback.haptic();
    setState(() => _decidingIds.add(message.id));
    try {
      final ok = await SmsService.decideOutbox(message.id, send: send);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? (send
                    ? 'Сообщение отправлено'.tr
                    : 'Сообщение не отправлено'.tr)
                : SmsService.failureText(),
          ),
          backgroundColor: ok
              ? (send ? Colors.green : Colors.grey.shade700)
              : Colors.orange.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => _decidingIds.remove(message.id));
    }
  }

  Widget _buildMediaPreview(String url, bool isOutbound) {
    final lower = url.toLowerCase();
    final isImage = lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.png') ||
        lower.contains('.gif') ||
        lower.contains('.webp');
    if (isImage) {
      return GestureDetector(
        onTap: () => _openMedia(url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            url,
            height: 180,
            width: double.infinity,
            fit: BoxFit.cover,
            // Превью в переписке: без cacheHeight каждое фото от клиента
            // распаковывается целиком, и длинная ветка съедает память.
            cacheHeight: 540,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            },
            errorBuilder: (_, _, _) => _fileTile(url, isOutbound),
          ),
        ),
      );
    }
    return _fileTile(url, isOutbound);
  }

  Widget _fileTile(String url, bool isOutbound) {
    final name = Uri.tryParse(url)?.pathSegments.last.replaceAll(RegExp(r'^\d+_'), '') ??
        'Файл'.tr;
    return Material(
      color: isOutbound ? Colors.white12 : Colors.grey.shade100,
      borderRadius: BorderRadius.circular(8),
      child: ListTile(
        dense: true,
        leading: Icon(
          Icons.insert_drive_file,
          color: isOutbound ? Colors.white : AppColors.primary,
        ),
        title: Text(
          Uri.decodeComponent(name),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isOutbound ? Colors.white : Colors.black87,
            fontSize: 13,
          ),
        ),
        onTap: () => _openMedia(url),
      ),
    );
  }

  Future<void> _openComposeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        return ComposeMessageSheet(
          initialText: _textController.text,
          channel: _channel,
          sending: _isSending,
          onChanged: (value) => _textController.text = value,
          onSend: () async {
            Navigator.pop(sheetContext);
            await _send();
          },
          onSchedule: (sendAt) async {
            Navigator.pop(sheetContext);
            await _scheduleMessage(sendAt);
          },
        );
      },
    );
    if (mounted) setState(() {});
  }

  Widget _buildRecipientBar() {
    final peers = _peers;
    final activeId = peers.any((peer) => peer.id == _peerId)
        ? _peerId
        : peers.first.id;

    Widget buildChip(
      ConversationPeer peer, {
      bool? forceSelected,
      String? customTitle,
      String? customSubtitle,
      bool showDropdown = false,
      VoidCallback? onTapOverride,
    }) {
      final selected = forceSelected ?? (peer.id == activeId);
      final title = customTitle ??
          (peer.displayName == peer.label
              ? peer.label
              : '${peer.label} · ${peer.displayName}');
      final defaultSub = [
        if (peer.hasPhone) peer.phone.trim() else if (peer.hasEmail) peer.email.trim(),
        if (!peer.isOwner && peer.address.trim().isNotEmpty)
          peer.address.split(',').first.trim(),
      ].where((s) => s.isNotEmpty).join(' · ');
      final contact = customSubtitle ?? defaultSub;
      return Material(
        color: selected ? AppColors.primary : AppColors.card,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTapOverride ?? () => _selectPeer(peer),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? AppColors.primary
                    : AppColors.primary.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  peer.isOwner ? Icons.person : Icons.location_on,
                  size: 18,
                  color: selected ? Colors.white : AppColors.primaryOnCard,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: selected ? Colors.white : AppColors.ink,
                        ),
                      ),
                      if (contact.isNotEmpty)
                        Text(
                          contact,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: selected ? Colors.white70 : AppColors.inkMuted,
                          ),
                        ),
                    ],
                  ),
                ),
                if (showDropdown)
                  Icon(
                    Icons.arrow_drop_down,
                    size: 20,
                    color: selected ? Colors.white : AppColors.primaryOnCard,
                  ),
              ],
            ),
          ),
        ),
      );
    }

    final ownerPeers = [for (final p in peers) if (p.isOwner) p];
    final tenantPeers = [for (final p in peers) if (!p.isOwner) p];

    Widget buildGroupChip(
      List<ConversationPeer> group, {
      required String fallbackTitle,
      required String pickerTitle,
    }) {
      if (group.length == 1) {
        return buildChip(group.first);
      }
      final activeInGroup = group.where((p) => p.id == activeId).firstOrNull;
      final displayPeer = activeInGroup ?? group.first;
      final selected = activeInGroup != null;
      final title = selected
          ? (displayPeer.displayName == displayPeer.label
              ? '${displayPeer.label} (${group.length})'
              : '${displayPeer.label} · ${displayPeer.displayName}')
          : '$fallbackTitle (${group.length})';
      final subtitle = selected
          ? [
              if (displayPeer.hasPhone)
                displayPeer.phone.trim()
              else if (displayPeer.hasEmail)
                displayPeer.email.trim(),
              if (!displayPeer.isOwner && displayPeer.address.trim().isNotEmpty)
                displayPeer.address.split(',').first.trim(),
            ].where((s) => s.isNotEmpty).join(' · ')
          : group.map((p) => p.displayName).take(3).join(', ');
      return buildChip(
        displayPeer,
        forceSelected: selected,
        customTitle: title,
        customSubtitle: subtitle,
        showDropdown: true,
        onTapOverride: () async {
          final chosen = await ConversationPeer.pick(
            context,
            group,
            title: pickerTitle,
          );
          if (chosen != null && mounted) {
            _selectPeer(chosen);
          }
        },
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: ownerPeers.isNotEmpty && tenantPeers.isNotEmpty
          ? Row(
              children: [
                Expanded(
                  child: buildGroupChip(
                    ownerPeers,
                    fallbackTitle: 'Хозяин'.tr,
                    pickerTitle: 'Хозяин'.tr,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: buildGroupChip(
                    tenantPeers,
                    fallbackTitle: 'Арендатор'.tr,
                    pickerTitle: 'Выберите арендатора'.tr,
                  ),
                ),
              ],
            )
          : Row(
              children: [
                for (var i = 0; i < peers.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: buildChip(peers[i])),
                ],
              ],
            ),
    );
  }

  Widget _buildScheduledBanner() {
    return StreamBuilder<List<ScheduledMessage>>(
      key: ValueKey(_threadKey),
      stream: _scheduledStream,
      builder: (context, snapshot) {
        final items = (snapshot.data ?? [])
            .where((m) => m.isPending)
            .toList();
        if (items.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          decoration: BoxDecoration(
            color: AppColors.tint(const Color(0xFFFFCC02), 0.14),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFFCC02), width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.schedule,
                      size: 16,
                      color: AppColors.isDark
                          ? const Color(0xFFFFCA28)
                          : const Color(0xFF856404),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Запланировано: ${items.length}'.tr,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.isDark
                            ? const Color(0xFFFFCA28)
                            : const Color(0xFF856404),
                      ),
                    ),
                  ],
                ),
              ),
              for (final msg in items) _buildScheduledItem(msg),
              const SizedBox(height: 4),
            ],
          ),
        );
      },
    );
  }

  Widget _buildScheduledItem(ScheduledMessage msg) {
    final isEmail = msg.channel == 'email';
    final displayBody = msg.bodyRu.isNotEmpty ? msg.bodyRu : msg.body;
    final failed = msg.status == 'failed';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              isEmail ? Icons.mail_outline : Icons.sms_outlined,
              size: 16,
              color: failed ? Colors.red : const Color(0xFF856404),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayBody,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF333300)),
                ),
                Text(
                  failed
                      ? '${'Ошибка'.tr}: ${msg.errorMsg ?? ''}'
                      : Formatters.messageStamp(msg.sendAt.toLocal()),
                  style: TextStyle(
                    fontSize: 11,
                    color: failed ? Colors.red : Colors.grey.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.cancel_outlined, size: 18, color: Color(0xFF856404)),
            tooltip: 'Отменить'.tr,
            onPressed: () async {
              await ScheduledMessageService.cancel(msg.id);
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _quickActions() {
    return [
      IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.person_outline, color: Colors.white, size: 22),
        tooltip: 'Карточка клиента'.tr,
        onPressed: _openClientCard,
      ),
      // По какой заявке идёт переписка. Почта с сайта ни к кому не
      // привязана — там показывать нечего. Заявки нет — вместо значка
      // кнопка «Создать заявку», чтобы карточку клиента и заявку можно
      // было завести прямо из переписки.
      if (!widget.websiteInbox)
        JobLinkButton(
          key: ValueKey('job-link-$_jobLinkRevision'),
          jobId: widget.jobId,
          clientId: widget.clientId,
          phone: _phone,
          onCreateJob: _createJob,
          busy: _creatingJob,
        ),
      IconButton(
        visualDensity: VisualDensity.compact,
        icon: _extracting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.auto_fix_high, color: Colors.white, size: 20),
        tooltip: 'Сохранить имя и адрес в карточку'.tr,
        onPressed: _extracting ? null : _extractAndApplyToClient,
      ),
      if (_hasPhone)
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: IconButton.filled(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.call, size: 18),
            tooltip: 'Позвонить'.tr,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF22C55E),
              foregroundColor: Colors.white,
            ),
            onPressed: _call,
          ),
        ),
    ];
  }

  Widget _buildChannelSwitch() {
    final isEmail = _channel == ConversationChannel.email;
    final canSwitch = _hasPhone && _hasEmail;

    Widget segment({
      required ConversationChannel value,
      required IconData icon,
      required bool enabled,
      required String tooltip,
    }) {
      final active = _channel == value;
      final activeColor = value == ConversationChannel.email
          ? const Color(0xFFEA4335)
          : AppColors.primary;
      return Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: !enabled || active
              ? null
              : () {
                  AppFeedback.pleasant();
                  setState(() {
                    _channel = value;
                    _bindStreams();
                  });
                  _markRead();
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: active ? activeColor : Colors.transparent,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 16,
              color: active
                  ? Colors.white
                  : (enabled ? Colors.grey.shade700 : Colors.grey.shade400),
            ),
          ),
        ),
      );
    }

    if (!canSwitch) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: (isEmail ? const Color(0xFFEA4335) : AppColors.primary)
              .withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          isEmail ? Icons.email_rounded : Icons.sms_rounded,
          size: 18,
          color: isEmail ? const Color(0xFFEA4335) : AppColors.primary,
        ),
      );
    }

    return Container(
      height: 36,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment(
            value: ConversationChannel.sms,
            icon: Icons.sms_rounded,
            enabled: _hasPhone,
            tooltip: 'SMS'.tr,
          ),
          segment(
            value: ConversationChannel.email,
            icon: Icons.email_rounded,
            enabled: _hasEmail,
            tooltip: 'Email'.tr,
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    final isEmail = _channel == ConversationChannel.email;
    return Container(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 6,
        bottom: 6 + (widget.embedded ? 0 : MediaQuery.of(context).padding.bottom),
      ),
      decoration: BoxDecoration(
        color: AppColors.card,
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -1))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_attachments.isNotEmpty)
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _attachments.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final file = _attachments[index];
                  return Stack(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AppColors.cardMuted,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: file.isImage
                            ? Image.memory(
                                file.bytes,
                                fit: BoxFit.cover,
                                cacheWidth: 216,
                                cacheHeight: 216,
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.insert_drive_file, color: AppColors.primaryOnCard, size: 20),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Text(
                                      file.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 10),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: () => setState(() => _attachments.removeAt(index)),
                          child: const CircleAvatar(
                            radius: 10,
                            backgroundColor: Colors.black54,
                            child: Icon(Icons.close, size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          if (_attachments.isNotEmpty) const SizedBox(height: 6),
          Row(
            children: [
              _buildChannelSwitch(),
              const SizedBox(width: 6),
              Expanded(
                child: Material(
                  color: AppColors.cardMuted,
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _isSending ? null : _openComposeSheet,
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.only(left: 12, right: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _textController.text.trim().isEmpty
                                  ? 'Пишите по-русски — клиенту уйдёт на английском'.tr
                                  : _textController.text.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: _textController.text.trim().isEmpty
                                    ? AppColors.inkMuted
                                    : AppColors.ink,
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.library_books_outlined, size: 18),
                            color: AppColors.inkMuted,
                            tooltip: context.tr('Выбрать шаблон', 'Choose template'),
                            onPressed: _showSmsTemplates,
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.attach_file, size: 18),
                            color: AppColors.inkMuted,
                            tooltip: 'Прикрепить'.tr,
                            onPressed: _isSending ? null : _pickAttachment,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _isSending
                  ? const SizedBox(
                      width: 38,
                      height: 38,
                      child: Padding(
                        padding: EdgeInsets.all(9),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : GestureDetector(
                      onLongPress: () async {
                        final text = _textController.text.trim();
                        if (text.isEmpty && _attachments.isEmpty) return;
                        final dt = await _pickScheduleTime();
                        if (dt != null) await _scheduleMessage(dt);
                      },
                      child: SizedBox(
                        width: 38,
                        height: 38,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          onPressed: _send,
                          icon: Icon(
                            isEmail ? Icons.email_rounded : Icons.send_rounded,
                            size: 18,
                          ),
                          tooltip: 'Отправить (удержать — запланировать)'.tr,
                          style: IconButton.styleFrom(
                            backgroundColor: isEmail
                                ? const Color(0xFFEA4335)
                                : AppColors.primary,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ),
            ],
          ),
        ],
      ),
    );
  }
}

class ComposeMessageSheet extends StatefulWidget {
  final String initialText;
  final ConversationChannel channel;
  final bool sending;
  final ValueChanged<String> onChanged;
  final Future<void> Function() onSend;
  final Future<void> Function(DateTime sendAt)? onSchedule;

  const ComposeMessageSheet({
    super.key,
    required this.initialText,
    required this.channel,
    required this.sending,
    required this.onChanged,
    required this.onSend,
    this.onSchedule,
  });

  @override
  State<ComposeMessageSheet> createState() => _ComposeMessageSheetState();
}

class _ComposeMessageSheetState extends State<ComposeMessageSheet> {
  late final TextEditingController _controller;
  final GlobalKey _polishKey = GlobalKey();
  bool _polishing = false;
  String? _polishSource;
  String? _lastPolished;
  int _polishVariant = 0;
  String _emojiLevel = 'normal';
  bool _showPolishMenu = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _controller.addListener(() => widget.onChanged(_controller.text));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _polish({String? emoji}) async {
    final text = _controller.text.trim();
    if (text.isEmpty || _polishing) return;
    if (emoji != null) _emojiLevel = emoji;
    if (_polishSource == null || text != _lastPolished) {
      _polishSource = text;
    }
    setState(() => _polishing = true);
    _polishVariant += 1;
    final out = await MessageTranslateService.polish(
      _polishSource!,
      variant: _polishVariant,
      emoji: _emojiLevel,
      previous: _lastPolished ?? '',
    );
    if (!mounted) return;
    final offerMenu = !_showPolishMenu;
    setState(() {
      _polishing = false;
      _showPolishMenu = true;
    });
    if (out.trim().isNotEmpty) {
      _lastPolished = out.trim();
      _controller.value = TextEditingValue(
        text: out,
        selection: TextSelection.collapsed(offset: out.length),
      );
    }
    if (offerMenu) {
      await Future<void>.delayed(const Duration(milliseconds: 160));
      if (mounted) await _openPolishMenu();
    }
  }

  Future<void> _scheduleFromSheet() async {
    if (widget.onSchedule == null) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final dt = await showScheduleDateTimePicker(context);
    if (dt == null || !mounted) return;
    await widget.onSchedule!(dt);
  }

  Future<void> _openPolishMenu() async {
    final box = _polishKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final origin = box.localToGlobal(Offset.zero);
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy - 8,
        origin.dx + box.size.width,
        origin.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'more',
          child: Text(
            _emojiLevel == 'more' ? '✓ Больше эмодзи'.tr : 'Больше эмодзи'.tr,
          ),
        ),
        PopupMenuItem(
          value: 'less',
          child: Text(
            _emojiLevel == 'less' ? '✓ Меньше эмодзи'.tr : 'Меньше эмодзи'.tr,
          ),
        ),
        PopupMenuItem(
          value: 'normal',
          child: Text(
            _emojiLevel == 'normal' ? '✓ Обычные эмодзи'.tr : 'Обычные эмодзи'.tr,
          ),
        ),
      ],
    );
    if (selected == null || !mounted) return;
    await _polish(emoji: selected);
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 10 + inset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 34,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Сообщение'.tr,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              height: 1.1,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            textAlignVertical: TextAlignVertical.top,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 15, height: 1.3),
            decoration: InputDecoration(
              hintText: 'Пишите по-русски — клиенту уйдёт на английском'.tr,
              filled: true,
              fillColor: AppColors.cardMuted,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                key: _polishKey,
                onPressed: _polishing ? null : () => _polish(),
                onLongPress: _polishing ? null : _openPolishMenu,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 36),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_polishing)
                      const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.auto_fix_high, size: 17),
                    const SizedBox(width: 5),
                    Text(
                      _showPolishMenu
                          ? 'Ещё'.tr
                          : 'Оформить'.tr,
                    ),
                    const SizedBox(width: 2),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _polishing ? null : _openPolishMenu,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Icon(Icons.expand_less, size: 17),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (widget.onSchedule != null) ...[
                Tooltip(
                  message: 'Запланировать'.tr,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: OutlinedButton(
                      onPressed: widget.sending ? null : _scheduleFromSheet,
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                        side: BorderSide(color: AppColors.primary.withValues(alpha: 0.35)),
                        foregroundColor: AppColors.primary,
                      ),
                      child: const Icon(Icons.schedule, size: 18),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              SizedBox(
                width: 38,
                height: 38,
                child: IconButton.filled(
                  onPressed: widget.sending ? null : widget.onSend,
                  tooltip: 'Отправить'.tr,
                  style: IconButton.styleFrom(
                    backgroundColor: widget.channel == ConversationChannel.email
                        ? const Color(0xFFEA4335)
                        : AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  icon: Icon(
                    widget.channel == ConversationChannel.email
                        ? Icons.email_rounded
                        : Icons.send_rounded,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TranslatedMessageBody extends StatefulWidget {
  final SmsMessage message;
  final bool isOutbound;
  final bool interactive;

  const _TranslatedMessageBody({
    required this.message,
    required this.isOutbound,
    this.interactive = true,
  });

  @override
  State<_TranslatedMessageBody> createState() => _TranslatedMessageBodyState();
}

class _TranslatedMessageBodyState extends State<_TranslatedMessageBody> {
  late String _display;
  String? _original;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _display = widget.message.displayBody;
    final ru = widget.message.bodyRu.trim();
    final original = widget.message.body.trim();
    if (ru.isNotEmpty && original.isNotEmpty && ru != original) {
      _original = widget.message.isOutbound ? original : original;
    }
    _maybeTranslateInbound();
  }

  @override
  void didUpdateWidget(covariant _TranslatedMessageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id ||
        oldWidget.message.body != widget.message.body ||
        oldWidget.message.bodyRu != widget.message.bodyRu) {
      _display = widget.message.displayBody;
      final ru = widget.message.bodyRu.trim();
      final original = widget.message.body.trim();
      _original = (ru.isNotEmpty && original.isNotEmpty && ru != original)
          ? original
          : null;
      _maybeTranslateInbound();
    }
  }

  Future<void> _maybeTranslateInbound() async {
    final message = widget.message;
    if (message.isOutbound) return;
    final existingRu = message.bodyRu.trim();
    final alreadyTranslated = existingRu.isNotEmpty &&
        existingRu != message.body.trim() &&
        MessageTranslateService.looksRussian(existingRu);
    if (alreadyTranslated) return;
    if (!MessageTranslateService.needsRussian(message.body)) return;
    setState(() => _loading = true);
    final ru = await MessageTranslateService.toRussian(message.body);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (ru.trim().isNotEmpty) {
        _display = ru;
        if (ru.trim() != message.body.trim()) {
          _original = message.body.trim();
        }
      }
    });
    if (ru.trim().isNotEmpty && ru.trim() != message.body.trim()) {
      await SmsService.saveBodyRu(message.id, ru);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = AppColors.ink;
    final subColor = AppColors.inkMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Перевод...'.tr,
              style: TextStyle(
                color: subColor,
                fontSize: 12,
              ),
            ),
          ),
        LinkedText(
          _display,
          interactive: widget.interactive,
          style: TextStyle(color: color, fontSize: 15),
        ),
        if (_original != null && _original!.trim() != _display.trim()) ...[
          const SizedBox(height: 6),
          LinkedText(
            _original!,
            interactive: widget.interactive,
            style: TextStyle(
              color: subColor,
              fontSize: 11,
              height: 1.3,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ],
    );
  }
}

