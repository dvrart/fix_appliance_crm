import '../../core/constants.dart';
import '../../models/client.dart';
import '../../models/job.dart';
import '../../services/sms_service.dart';

class CallerJobs {
  final String name;
  final List<Job> jobs;

  const CallerJobs({required this.name, required this.jobs});

  static CallerJobs resolve(String phone, List<Client> clients, List<Job> jobs) {
    final digits = SmsService.normalizePhone(phone);
    if (digits.length != 10) return const CallerJobs(name: '', jobs: []);
    bool matches(String raw) => SmsService.normalizePhone(raw) == digits;
    String normalizeAddress(String raw) =>
        raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

    var name = '';
    final ownerIds = <String>{};
    final sites = <String, List<({String street, String city, String unit})>>{};
    for (final client in clients) {
      if (client.isDeleted) continue;
      if (matches(client.phone)) {
        ownerIds.add(client.id);
        if (name.isEmpty && !Client.isPlaceholderName(client.fullName)) {
          name = Client.stripClientWord(client.fullName);
        }
      }
      for (final location in client.locations) {
        for (final contact in location.contacts) {
          if (!matches(contact.phone)) continue;
          if (name.isEmpty && !Client.isPlaceholderName(contact.name)) {
            name = Client.stripClientWord(contact.name);
          }
          final street = normalizeAddress(location.street);
          if (street.isNotEmpty) {
            sites.putIfAbsent(client.id, () => []).add((
              street: street,
              city: normalizeAddress(location.city),
              unit: normalizeAddress(location.unit ?? ''),
            ));
          }
        }
      }
    }
    final found = <Job>[];
    for (final job in jobs) {
      if (job.isDeleted || job.isMergedDuplicate || JobStatuses.isClosed(job.status)) continue;
      final directSite = matches(job.jobSitePhone ?? '');
      final address = ' ${normalizeAddress(job.workAddress)} ';
      final atSite = (sites[job.clientId] ?? []).any((site) =>
          address.contains(' ${site.street} ') &&
          (site.city.isEmpty || address.contains(' ${site.city} ')) &&
          (site.unit.isEmpty || address.contains(' ${site.unit} ')));
      if (!directSite && !matches(job.clientPhone) && !ownerIds.contains(job.clientId) && !atSite) continue;
      found.add(job);
      if (name.isEmpty && directSite && !Client.isPlaceholderName(job.jobSiteName)) {
        name = Client.stripClientWord(job.jobSiteName);
      }
      if (name.isEmpty && matches(job.clientPhone) && !Client.isPlaceholderName(job.clientName)) {
        name = Client.stripClientWord(job.clientName);
      }
    }
    found.sort((a, b) => (b.scheduledAt ?? b.createdAt).compareTo(a.scheduledAt ?? a.createdAt));
    return CallerJobs(name: name, jobs: found);
  }
}
