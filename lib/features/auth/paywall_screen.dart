import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/company_session.dart';
import '../../core/constants.dart';
import '../../core/l10n/app_locale.dart';
import '../../services/account_service.dart';

class PaywallScreen extends StatelessWidget {
  const PaywallScreen({super.key, required this.onChanged});

  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final name = CompanySession.instance.companyName;
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 40, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr('Подписка', 'Subscription'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                name.isEmpty
                    ? context.tr(
                        'Пробный период закончился. Чтобы продолжить работу со своей компанией, нужна подписка.',
                        'The trial ended. A subscription is required to keep using your company.',
                      )
                    : context.tr(
                        'Пробный период для «$name» закончился. Подписка откроет CRM снова.',
                        'The trial for "$name" ended. Subscribe to open the CRM again.',
                      ),
                style: const TextStyle(color: Colors.white70, height: 1.4, fontSize: 16),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        context.tr(
                          'Оплата через Google Play подключим следующим шагом. Сейчас это заготовка экрана.',
                          'Google Play billing comes next. This screen is the gate.',
                        ),
                      ),
                    ),
                  );
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: const Color(0xFF1A1A1A),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  context.tr('Оформить подписку', 'Subscribe'),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          context.tr(
                            'Подписку меняет сервер. Для отладки в Firebase: companies → subscription.status = active.',
                            'Billing is server-side. For debug, set companies → subscription.status = active in Firebase.',
                          ),
                        ),
                      ),
                    );
                    onChanged();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54),
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: Text(
                    context.tr(
                      'Как открыть вручную',
                      'How to unlock manually',
                    ),
                  ),
                ),
              ],
              const Spacer(),
              TextButton(
                onPressed: AccountService.instance.signOut,
                child: Text(
                  context.tr('Выйти', 'Sign out'),
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
