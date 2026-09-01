import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/client.dart';

class PhoneClientMatches extends StatelessWidget {
  final List<Client> clients;
  final ValueChanged<Client> onSelect;

  const PhoneClientMatches({
    super.key,
    required this.clients,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (clients.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        border: Border.all(color: AppColors.accent),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Text(
              clients.length == 1
                  ? 'Клиент с этим номером уже есть'.tr
                  : 'Клиенты с этим номером уже есть'.tr,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ),
          for (final client in clients)
            ListTile(
              dense: true,
              leading: CircleAvatar(
                backgroundColor: Colors.white,
                child: Text(
                  client.initials,
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              title: Text(
                client.fullName.isEmpty ? 'Без имени'.tr : client.fullName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                [
                  client.phone,
                  if (client.address.isNotEmpty) client.address,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.chevron_right, color: AppColors.primary),
              onTap: () => onSelect(client),
            ),
        ],
      ),
    );
  }
}
