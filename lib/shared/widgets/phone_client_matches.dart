import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../models/client.dart';
import '../../services/client_service.dart';

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
        color: AppColors.tint(AppColors.accent, 0.14),
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
                color: AppColors.primaryOnCard,
              ),
            ),
          ),
          for (final client in clients)
            ListTile(
              dense: true,
              leading: CircleAvatar(
                backgroundColor: AppColors.card,
                child: Text(
                  client.initials,
                  style: TextStyle(
                    color: AppColors.primaryOnCard,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      client.fullName.isEmpty
                          ? 'Без имени'.tr
                          : client.fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (client.isRegular ||
                      ClientService.isRegularClient(
                        clientId: client.id,
                        phone: client.phone,
                        email: client.email,
                      ))
                    const RegularClientStar(size: 16),
                ],
              ),
              subtitle: Text(
                [
                  client.phone,
                  if (client.address.isNotEmpty) client.address,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.chevron_right, color: AppColors.primaryOnCard),
              onTap: () => onSelect(client),
            ),
        ],
      ),
    );
  }
}
