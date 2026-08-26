import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/client.dart';
import '../models/job.dart';
import '../models/location.dart';
import 'client_service.dart';
import 'firestore_service.dart';
import 'job_service.dart';

class ImportResult {
  final int clientsCreated;
  final int clientsUpdated;
  final int jobsCreated;
  final int skipped;
  final String? error;

  const ImportResult({
    this.clientsCreated = 0,
    this.clientsUpdated = 0,
    this.jobsCreated = 0,
    this.skipped = 0,
    this.error,
  });

  String get summary {
    if (error != null && error!.isNotEmpty) return error!;
    return 'Клиенты: +$clientsCreated / обновлено $clientsUpdated. Заявки: +$jobsCreated.';
  }
}

class ImportExportService {
  static Future<void> exportClientsCsv() async {
    final clients = await ClientService.loadAllOnce();
    final rows = <List<String>>[
      [
        'fullName',
        'phone',
        'email',
        'address',
        'city',
        'postal',
        'company',
        'notes',
        'source',
      ],
    ];
    for (final client in clients) {
      final loc = client.primaryLocation;
      rows.add([
        client.fullName,
        client.phone,
        client.email ?? '',
        loc?.street ?? client.address,
        loc?.city ?? '',
        loc?.postalCode ?? '',
        client.companyName ?? '',
        client.notes ?? '',
        client.source ?? '',
      ]);
    }
    await _shareCsv('fix_clients.csv', rows);
  }

  static Future<void> exportJobsCsv() async {
    final jobs = await JobService.loadAllOnce();
    final rows = <List<String>>[
      [
        'clientName',
        'phone',
        'address',
        'applianceType',
        'brand',
        'model',
        'description',
        'status',
        'priority',
        'scheduledAt',
        'durationMinutes',
        'notes',
        'trackingNumber',
        'amazonOrderId',
      ],
    ];
    for (final job in jobs) {
      rows.add([
        job.clientName,
        job.clientPhone,
        job.workAddress,
        job.applianceType,
        job.applianceBrand,
        job.primaryAppliance?.model ?? '',
        job.description,
        job.status,
        job.priority,
        job.scheduledAt?.toIso8601String() ?? '',
        '${job.durationMinutes}',
        job.packingNotes,
        job.trackingNumber,
        job.amazonOrderId,
      ]);
    }
    await _shareCsv('fix_jobs.csv', rows);
  }

  static Future<void> exportBackupJson() async {
    final clientsSnap = await FirestoreService.clientsRef.get();
    final jobsSnap = await FirestoreService.jobsRef.get();
    final payload = {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'clients': [
        for (final doc in clientsSnap.docs)
          {'id': doc.id, ..._jsonSafe(doc.data()) as Map<String, dynamic>},
      ],
      'jobs': [
        for (final doc in jobsSnap.docs)
          {'id': doc.id, ..._jsonSafe(doc.data()) as Map<String, dynamic>},
      ],
    };
    await _saveOrShare(
      'fix_backup.json',
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  static dynamic _jsonSafe(dynamic value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is FieldValue) return null;
    if (value is GeoPoint) {
      return {'lat': value.latitude, 'lng': value.longitude};
    }
    if (value is DocumentReference) return value.path;
    if (value is Iterable) {
      return [for (final item in value) _jsonSafe(item)];
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (entry.value is! FieldValue) entry.key.toString(): _jsonSafe(entry.value),
      };
    }
    return value.toString();
  }

  static const List<String> importTemplateHeaders = [
    'fullName',
    'firstName',
    'lastName',
    'phone',
    'email',
    'address',
    'city',
    'postal',
    'company',
    'notes',
    'source',
    'applianceType',
    'brand',
    'model',
    'description',
    'status',
    'priority',
    'scheduledAt',
    'durationMinutes',
    'jobSiteName',
    'jobSitePhone',
    'jobSiteEmail',
    'jobSiteAddress',
    'trackingNumber',
    'amazonOrderId',
  ];

  static Future<void> exportImportTemplate() async {
    await _shareCsv('fix_import_template.csv', [
      importTemplateHeaders,
      [
        'John Smith',
        'John',
        'Smith',
        '4165550101',
        'john.smith@gmail.com',
        '123 King St',
        'Toronto',
        'M5V 1A1',
        '',
        'Prefers morning visits',
        'Google',
        'Refrigerator',
        'Samsung',
        'RF28R7351SR',
        'Not cooling',
        'Вызов',
        '🟢 Обычный',
        '2026-08-20 09:00',
        '60',
        'Jane Tenant',
        '4165550102',
        'jane.tenant@yahoo.com',
        '45 Queen St, Toronto, M5H 2N2',
        '',
        '',
      ],
      [
        'Maria Lopez',
        'Maria',
        'Lopez',
        '6475550199',
        'maria.lopez@hotmail.com',
        '88 Bloor St',
        'Toronto',
        'M4W 1A1',
        'Lopez Inc',
        '',
        'Google',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
      ],
    ]);
  }

  static Future<ImportResult> importFromFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['csv', 'json', 'txt'],
    );
    if (file == null) {
      return const ImportResult(error: '');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      return const ImportResult(error: 'Не удалось прочитать файл');
    }
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final name = (file.name).toLowerCase();
    try {
      if (name.endsWith('.json') || text.trim().startsWith('{')) {
        return await _importJson(text);
      }
      return await _importCsv(text);
    } catch (e) {
      return ImportResult(error: 'Ошибка импорта: $e');
    }
  }

  static Future<ImportResult> _importJson(String text) async {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      return const ImportResult(error: 'Неверный JSON');
    }
    var clientsCreated = 0;
    var clientsUpdated = 0;
    var jobsCreated = 0;
    var skipped = 0;
    final clients = decoded['clients'];
    if (clients is List) {
      for (final raw in clients) {
        if (raw is! Map) {
          skipped += 1;
          continue;
        }
        final map = Map<String, dynamic>.from(raw);
        final result = await _upsertClient(map);
        if (result == _Upsert.created) clientsCreated += 1;
        if (result == _Upsert.updated) clientsUpdated += 1;
      }
    }
    final jobs = decoded['jobs'];
    if (jobs is List) {
      for (final raw in jobs) {
        if (raw is! Map) {
          skipped += 1;
          continue;
        }
        await _createJob(Map<String, dynamic>.from(raw));
        jobsCreated += 1;
      }
    }
    return ImportResult(
      clientsCreated: clientsCreated,
      clientsUpdated: clientsUpdated,
      jobsCreated: jobsCreated,
      skipped: skipped,
    );
  }

  static Future<ImportResult> _importCsv(String text) async {
    final table = _parseCsv(text);
    if (table.length < 2) {
      return const ImportResult(error: 'В файле нет строк данных');
    }
    final header = table.first.map(_normHeader).toList();
    var clientsCreated = 0;
    var clientsUpdated = 0;
    var jobsCreated = 0;
    var skipped = 0;
    for (var i = 1; i < table.length; i++) {
      final row = table[i];
      if (row.every((cell) => cell.trim().isEmpty)) continue;
      final map = <String, String>{};
      for (var c = 0; c < header.length && c < row.length; c++) {
        if (header[c].isEmpty) continue;
        map[header[c]] = row[c];
      }
      final first = _pick(map, const ['firstname', 'givenname']);
      final last = _pick(map, const ['lastname', 'surname', 'familyname']);
      final fullName = _pick(map, const [
            'fullname',
            'clientname',
            'name',
            'customername',
            'displayname',
            'customer',
          ]).isNotEmpty
          ? _pick(map, const [
              'fullname',
              'clientname',
              'name',
              'customername',
              'displayname',
              'customer',
            ])
          : [first, last].where((p) => p.isNotEmpty).join(' ');
      final phone = _pick(map, const [
        'phone',
        'clientphone',
        'phonenumber',
        'mobile',
        'mobilenumber',
        'cellphone',
        'telephone',
      ]);
      final email = _pick(map, const [
        'email',
        'emailaddress',
        'mail',
        'customeremail',
      ]);
      final street = _pick(map, const [
        'address',
        'street',
        'clientaddress',
        'streetaddress',
        'addressline1',
        'address1',
        'street1',
      ]);
      final city = _pick(map, const ['city', 'town']);
      final postal = _pick(map, const [
        'postal',
        'postalcode',
        'zip',
        'zipcode',
      ]);
      final company = _pick(map, const [
        'company',
        'companyname',
        'businessname',
      ]);
      final notes = _pick(map, const ['notes', 'note', 'comment', 'comments']);
      final source = _pick(map, const ['source', 'leadsource', 'referral']);
      if (fullName.isEmpty && phone.isEmpty && email.isEmpty) {
        skipped += 1;
        continue;
      }
      final result = await _upsertClient({
        'fullName': fullName,
        'phone': phone,
        'email': email,
        'address': street,
        'city': city,
        'postal': postal,
        'companyName': company,
        'notes': notes,
        'source': source,
      });
      if (result == _Upsert.created) clientsCreated += 1;
      if (result == _Upsert.updated) clientsUpdated += 1;

      final appliance = _pick(map, const [
        'appliancetype',
        'type',
        'service',
        'item',
        'itemname',
      ]);
      final brand = _pick(map, const ['brand', 'make', 'manufacturer']);
      final model = _pick(map, const ['model', 'modelnumber', 'serial']);
      final description = _pick(map, const [
        'description',
        'issue',
        'problem',
        'servicenotes',
      ]);
      final scheduledAt = _parseDateTime(
        _pick(map, const [
          'scheduledat',
          'scheduleddate',
          'appointmentdate',
          'startdate',
          'date',
          'jobdate',
          'startdatetime',
        ]),
        _pick(map, const [
          'scheduledtime',
          'appointmenttime',
          'starttime',
          'time',
        ]),
      );
      final looksLikeJob = appliance.isNotEmpty ||
          brand.isNotEmpty ||
          model.isNotEmpty ||
          scheduledAt != null ||
          _pick(map, const ['status', 'priority', 'jobsiteaddress']).isNotEmpty;
      if (!looksLikeJob) continue;

      await _createJob({
        'clientName': fullName,
        'clientPhone': phone,
        'email': email,
        'clientAddress': [
          street,
          city,
          postal,
        ].where((p) => p.isNotEmpty).join(', '),
        'applianceType': appliance,
        'brand': brand,
        'model': model,
        'description': description.isNotEmpty ? description : notes,
        'status': _pick(map, const ['status', 'jobstatus']).isEmpty
            ? 'Вызов'
            : _pick(map, const ['status', 'jobstatus']),
        'priority': _pick(map, const ['priority']).isEmpty
            ? '🟢 Обычный'
            : _pick(map, const ['priority']),
        'scheduledAt': scheduledAt?.toIso8601String() ?? '',
        'durationMinutes': _pick(map, const [
          'durationminutes',
          'duration',
          'length',
        ]).isEmpty
            ? '60'
            : _pick(map, const ['durationminutes', 'duration', 'length']),
        'packingNotes': notes,
        'trackingNumber': _pick(map, const ['trackingnumber', 'tracking']),
        'amazonOrderId': _pick(map, const ['amazonorderid', 'amazonorder']),
        'jobSiteName': _pick(map, const ['jobsitename', 'sitename', 'tenant']),
        'jobSitePhone': _pick(map, const ['jobsitephone', 'sitephone']),
        'jobSiteEmail': _pick(map, const ['jobsiteemail', 'siteemail']),
        'jobSiteAddress': _pick(map, const [
          'jobsiteaddress',
          'siteaddress',
          'serviceaddress',
        ]),
      });
      jobsCreated += 1;
    }
    return ImportResult(
      clientsCreated: clientsCreated,
      clientsUpdated: clientsUpdated,
      jobsCreated: jobsCreated,
      skipped: skipped,
    );
  }

  static String _normHeader(String cell) {
    return cell.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9а-яё]'), '');
  }

  static String _pick(Map<String, String> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  static DateTime? _parseDateTime(String dateRaw, [String timeRaw = '']) {
    final date = dateRaw.trim();
    final time = timeRaw.trim();
    if (date.isEmpty && time.isEmpty) return null;
    final combined = time.isEmpty ? date : '$date $time';
    final iso = DateTime.tryParse(combined.replaceFirst(' ', 'T'));
    if (iso != null) return iso;
    final dm = RegExp(r'^(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})').firstMatch(date);
    if (dm == null) return null;
    var a = int.parse(dm.group(1)!);
    var b = int.parse(dm.group(2)!);
    var year = int.parse(dm.group(3)!);
    if (year < 100) year += 2000;
    final month = a > 12 ? b : a;
    final day = a > 12 ? a : b;
    var hour = 9;
    var minute = 0;
    final tm = RegExp(
      r'(\d{1,2}):(\d{2})\s*(am|pm)?',
      caseSensitive: false,
    ).firstMatch(time.isNotEmpty ? time : date);
    if (tm != null) {
      hour = int.parse(tm.group(1)!);
      minute = int.parse(tm.group(2)!);
      final ap = (tm.group(3) ?? '').toLowerCase();
      if (ap == 'pm' && hour < 12) hour += 12;
      if (ap == 'am' && hour == 12) hour = 0;
    }
    return DateTime(year, month, day, hour, minute);
  }

  static Future<_Upsert> _upsertClient(Map<String, dynamic> map) async {
    final name = (map['fullName'] ?? map['name'] ?? '').toString().trim();
    final phone = (map['phone'] ?? map['clientPhone'] ?? '').toString().trim();
    if (name.isEmpty && phone.isEmpty) return _Upsert.skipped;
    final email = (map['email'] ?? '').toString().trim();
    final street = (map['address'] ?? map['street'] ?? '').toString().trim();
    final city = (map['city'] ?? '').toString().trim();
    final postal = (map['postal'] ?? map['postalCode'] ?? '').toString().trim();
    final company = (map['companyName'] ?? map['company'] ?? '').toString().trim();
    final notes = (map['notes'] ?? '').toString().trim();
    final source = (map['source'] ?? '').toString().trim();
    final existing = await ClientService.findExisting(phone: phone, email: email);
    if (existing != null) {
      await ClientService.update(existing.id, {
        if (name.isNotEmpty) 'fullName': name,
        if (phone.isNotEmpty) 'phone': phone,
        if (email.isNotEmpty) 'email': email,
        if (company.isNotEmpty) 'companyName': company,
        if (notes.isNotEmpty) 'notes': notes,
        if (source.isNotEmpty) 'source': source,
        ...ClientService.addressFields(
          street: street.isNotEmpty ? street : existing.primaryLocation?.street ?? '',
          city: city.isNotEmpty ? city : existing.primaryLocation?.city ?? '',
          postal: postal.isNotEmpty
              ? postal
              : existing.primaryLocation?.postalCode ?? '',
          currentData: existing.toMap(),
        ),
      });
      return _Upsert.updated;
    }
    await ClientService.create(
      Client(
        id: '',
        fullName: name.isEmpty ? phone : name,
        phone: phone,
        email: email.isEmpty ? null : email,
        companyName: company.isEmpty ? null : company,
        notes: notes.isEmpty ? null : notes,
        source: source.isEmpty ? null : source,
        locations: [
          if (street.isNotEmpty || city.isNotEmpty)
            Location(
              id: 'primary',
              street: street,
              city: city,
              postalCode: postal,
            ),
        ],
      ),
    );
    return _Upsert.created;
  }

  static Future<void> _createJob(Map<String, dynamic> map) async {
    final name = (map['clientName'] ?? map['fullName'] ?? '').toString().trim();
    final phone = (map['clientPhone'] ?? map['phone'] ?? '').toString().trim();
    final email = (map['email'] ?? '').toString().trim();
    var clientId = (map['clientId'] ?? '').toString();
    if (clientId.isEmpty && (phone.isNotEmpty || name.isNotEmpty)) {
      final existing = await ClientService.findExisting(phone: phone, email: email);
      if (existing != null) {
        clientId = existing.id;
        if (email.isNotEmpty && (existing.email ?? '').isEmpty) {
          await ClientService.update(existing.id, {'email': email});
        }
      } else {
        clientId = await ClientService.create(
          Client(
            id: '',
            fullName: name.isEmpty ? phone : name,
            phone: phone,
            email: email.isEmpty ? null : email,
            locations: const [],
          ),
        );
      }
    }
    final scheduledRaw = (map['scheduledAt'] ?? map['scheduledDate'] ?? '').toString();
    final scheduledAt = _parseDateTime(scheduledRaw) ?? DateTime.tryParse(scheduledRaw);
    final duration = int.tryParse('${map['durationMinutes'] ?? ''}') ?? 60;
    final type = (map['applianceType'] ?? map['type'] ?? '').toString();
    final siteName = (map['jobSiteName'] ?? '').toString().trim();
    final sitePhone = (map['jobSitePhone'] ?? '').toString().trim();
    final siteEmail = (map['jobSiteEmail'] ?? '').toString().trim();
    final siteAddress = (map['jobSiteAddress'] ?? '').toString().trim();
    final hasJobSite = siteName.isNotEmpty ||
        sitePhone.isNotEmpty ||
        siteEmail.isNotEmpty ||
        siteAddress.isNotEmpty;
    await JobService.create(
      Job(
        id: '',
        clientId: clientId,
        clientName: name,
        clientPhone: phone,
        clientAddress: (map['clientAddress'] ?? map['address'] ?? '').toString(),
        hasJobSite: hasJobSite,
        jobSiteName: siteName.isEmpty ? null : siteName,
        jobSitePhone: sitePhone.isEmpty ? null : sitePhone,
        jobSiteEmail: siteEmail.isEmpty ? null : siteEmail,
        jobSiteAddress: siteAddress.isEmpty ? null : siteAddress,
        appliances: [
          JobAppliance(
            type: type,
            brand: (map['brand'] ?? '').toString(),
            model: (map['model'] ?? '').toString(),
            issue: (map['description'] ?? '').toString(),
          ),
        ],
        description: (map['description'] ?? '').toString(),
        status: (map['status'] ?? 'Вызов').toString(),
        priority: (map['priority'] ?? '🟢 Обычный').toString(),
        scheduledAt: scheduledAt,
        visits: scheduledAt == null
            ? const []
            : [
                JobVisit.create(
                  startAt: scheduledAt,
                  durationMinutes: duration,
                ),
              ],
        createdAt: DateTime.now(),
        durationMinutes: duration,
        packingNotes: (map['packingNotes'] ?? map['notes'] ?? '').toString(),
        trackingNumber: (map['trackingNumber'] ?? '').toString(),
        amazonOrderId: (map['amazonOrderId'] ?? '').toString(),
      ),
    );
  }

  static Future<void> _shareCsv(String name, List<List<String>> rows) {
    final buffer = StringBuffer('\uFEFF');
    for (final row in rows) {
      buffer.writeln(row.map(_csvEscape).join(','));
    }
    return _shareText(name, buffer.toString());
  }

  static String _csvEscape(String value) {
    final text = value.replaceAll('\r\n', '\n');
    if (text.contains(',') || text.contains('"') || text.contains('\n')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }

  static List<List<String>> _parseCsv(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i += 1;
          } else {
            inQuotes = false;
          }
        } else {
          cell.write(ch);
        }
      } else if (ch == '"') {
        inQuotes = true;
      } else if (ch == ',') {
        row.add(cell.toString());
        cell.clear();
      } else if (ch == '\n') {
        row.add(cell.toString());
        cell.clear();
        rows.add(row);
        row = <String>[];
      } else if (ch != '\r') {
        cell.write(ch);
      }
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row);
    }
    return rows;
  }

  static Future<void> _shareText(String name, String contents) {
    return _saveOrShare(name, contents);
  }

  static Future<void> _saveOrShare(String name, String contents) async {
    final bytes = Uint8List.fromList(utf8.encode(contents));
    try {
      final saved = await FilePicker.saveFile(
        dialogTitle: name,
        fileName: name,
        bytes: bytes,
        mimeType: name.endsWith('.json') ? 'application/json' : 'text/csv',
      );
      if (saved != null) return;
    } catch (error) {
      debugPrint('ImportExport saveFile: $error');
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            file.path,
            mimeType: name.endsWith('.json') ? 'application/json' : 'text/csv',
            name: name,
          ),
        ],
        title: name,
        text: name,
      ),
    );
  }
}

enum _Upsert { created, updated, skipped }
