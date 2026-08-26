import 'package:flutter/material.dart';

import '../../../messages/conversation_screen.dart';
import '../job_details_controller.dart';
import '../../../../core/l10n/app_locale.dart';

class ChatTab extends StatelessWidget {
  final JobDetailsController controller;

  const ChatTab({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final contacts = controller.chatContacts;
        final selected = controller.selectedChatContact;

        return Column(
          children: [
            Expanded(
              child: selected == null || !selected.hasChannel
                  ? Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Нет телефона или email.\nДобавьте контакт клиента.'.tr,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  : ConversationScreen(
                      key: ValueKey(controller.jobId),
                      phoneNumber: selected.phone,
                      email: selected.email.contains('@') ? selected.email : null,
                      contactName: selected.displayName,
                      clientId: controller.clientId,
                      jobId: controller.jobId,
                      recipients: [
                        for (final contact in contacts)
                          ConversationPeer(
                            id: contact.id,
                            label: contact.label,
                            name: contact.displayName,
                            phone: contact.phone,
                            email: contact.email,
                          ),
                      ],
                      embedded: true,
                    ),
            ),
          ],
        );
      },
    );
  }
}

