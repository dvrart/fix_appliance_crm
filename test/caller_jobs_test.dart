import 'package:fix_appliance_crm/features/calls/caller_jobs.dart';
import 'package:fix_appliance_crm/models/client.dart';
import 'package:fix_appliance_crm/models/contact.dart';
import 'package:fix_appliance_crm/models/job.dart';
import 'package:fix_appliance_crm/models/location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final client = Client(
    id: 'owner',
    fullName: 'Kyle Malinouski',
    phone: '4165550000',
    locations: [
      Location(
        id: 'site',
        street: '123 Main St',
        city: 'Toronto',
        postalCode: '',
        contacts: [Contact(id: 'tenant', name: 'Jane Tenant', phone: '4165551111', role: 'tenant')],
      ),
    ],
  );
  Job job(String id, String address, {String? sitePhone, String? siteName}) => Job(
    id: id,
    clientId: 'owner',
    clientName: client.fullName,
    clientPhone: client.phone,
    clientAddress: address,
    hasJobSite: sitePhone != null,
    jobSitePhone: sitePhone,
    jobSiteName: siteName,
    createdAt: DateTime(2026),
  );

  test('tenant contact resolves only jobs at their address', () {
    final result = CallerJobs.resolve('+1 416 555 1111', [client], [
      job('site', '123 Main St, Toronto'),
      job('other', '999 Other St, Toronto'),
    ]);
    expect(result.name, 'Jane Tenant');
    expect(result.jobs.map((j) => j.id), ['site']);
  });

  test('job site number works without a separate client contact', () {
    final result = CallerJobs.resolve('4165552222', [client], [
      job('site', '123 Main St', sitePhone: '4165552222', siteName: 'Alex Tenant'),
    ]);
    expect(result.name, 'Alex Tenant');
    expect(result.jobs.single.clientName, 'Kyle Malinouski');
  });

  test('short numbers do not match and owners may have multiple jobs', () {
    expect(CallerJobs.resolve('1111', [client], []).jobs, isEmpty);
    final result = CallerJobs.resolve('4165550000', [client], [
      job('a', '123 Main St'), job('b', '999 Other St'),
    ]);
    expect(result.name, 'Kyle Malinouski');
    expect(result.jobs.length, 2);
  });

  test('tenant addresses do not match a different city or apartment', () {
    final tenant = Client(
      id: 'owner',
      fullName: client.fullName,
      phone: client.phone,
      locations: [
        Location(
          id: 'site', street: '123 Main St', city: 'Toronto', unit: 'Unit 2',
          postalCode: '',
          contacts: [Contact(id: 'tenant', name: 'Jane', phone: '4165551111')],
        ),
      ],
    );
    final result = CallerJobs.resolve('4165551111', [tenant], [
      job('right', 'Unit 2, 123 Main St, Toronto'),
      job('wrong city', 'Unit 2, 123 Main St, Ottawa'),
      job('wrong unit', 'Unit 3, 123 Main St, Toronto'),
    ]);
    expect(result.jobs.map((j) => j.id), ['right']);
  });
}
