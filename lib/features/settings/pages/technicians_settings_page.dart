import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/ui_scale.dart';
import '../../../models/technician.dart';
import '../../../services/technician_service.dart';
import '../../../shared/widgets/app_bar_save.dart';
import '../../../shared/widgets/dirty_leave_scope.dart';
import '../../technicians/technician_settlements_screen.dart';
import '../widgets/settings_ui.dart';

/// Раздел «Настройки → Мастера»: список частных мастеров, создание/редактирование
/// профиля (вход, процент, собственные реквизиты и HST), блокировка в одно касание.
class TechniciansSettingsPage extends StatefulWidget {
  const TechniciansSettingsPage({super.key});

  @override
  State<TechniciansSettingsPage> createState() =>
      _TechniciansSettingsPageState();
}

class _TechniciansSettingsPageState extends State<TechniciansSettingsPage> {
  late final Stream<List<TechnicianProfile>> _stream =
      TechnicianService.streamAll();
  final Set<String> _toggling = {};

  void _openEditor([TechnicianProfile? existing]) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _TechnicianEditorPage(existing: existing),
      ),
    );
  }

  Future<void> _toggleActive(TechnicianProfile tech, bool next) async {
    if (_toggling.contains(tech.uid)) return;
    setState(() => _toggling.add(tech.uid));
    try {
      await TechnicianService.setTechnicianActive(uid: tech.uid, active: next);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$e'),
            backgroundColor: const Color(0xFFE53935),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _toggling.remove(tech.uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.tr('Мастера', 'Technicians'),
      actions: [
        IconButton(
          tooltip: context.tr('Расчёт с мастерами', 'Settlements'),
          icon: const Icon(Icons.account_balance_wallet_outlined),
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const TechnicianSettlementsScreen(),
              ),
            );
          },
        ),
        IconButton(
          tooltip: context.tr('Добавить мастера', 'Add technician'),
          icon: const Icon(Icons.person_add_alt_1),
          onPressed: () => _openEditor(),
        ),
      ],
      body: StreamBuilder<List<TechnicianProfile>>(
        stream: _stream,
        builder: (context, snapshot) {
          final items = snapshot.data ?? const <TechnicianProfile>[];
          return ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 28),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Material(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const TechnicianSettlementsScreen(),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.account_balance_wallet,
                            color: Color(0xFFFCC520),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              context.tr(
                                'Открыть сверку расчётов с мастерами',
                                'Open technician settlements',
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right,
                            color: Colors.white70,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (items.isEmpty)
                SettingsGroup(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Text(
                            context.tr(
                              'Добавьте частного мастера: вы задаёте ему логин и пароль, процент от чистой прибыли и его собственные реквизиты для счетов.',
                              'Add an independent technician: set login credentials, profit split % and their own invoice details.',
                            ),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.inkMuted),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => _openEditor(),
                            icon: const Icon(Icons.person_add_alt_1),
                            label: Text(
                              context.tr('Добавить мастера', 'Add technician'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              else
                SettingsGroup(
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _buildRow(context, items[i]),
                    ],
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRow(BuildContext context, TechnicianProfile tech) {
    final busy = _toggling.contains(tech.uid);
    return ListTile(
      onTap: () => _openEditor(tech),
      leading: CircleAvatar(
        backgroundColor: tech.active ? tech.color : Colors.grey,
        child: Text(
          tech.initials,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(
        tech.displayName,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          decoration: tech.active ? null : TextDecoration.lineThrough,
        ),
      ),
      subtitle: Text(
        '${tech.email} · ${context.tr('Мастеру', 'Tech')} ${tech.clampedTechPercent.toStringAsFixed(0)}% / ${context.tr('Мне', 'Me')} ${tech.ownerSharePercent.toStringAsFixed(0)}%'
        '${tech.hasOwnTax ? ' · HST' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Switch(
        value: tech.active,
        activeTrackColor: const Color(0xFF22C55E),
        onChanged: busy ? null : (next) => _toggleActive(tech, next),
      ),
    );
  }
}

class _TechnicianEditorPage extends StatefulWidget {
  final TechnicianProfile? existing;

  const _TechnicianEditorPage({this.existing});

  @override
  State<_TechnicianEditorPage> createState() => _TechnicianEditorPageState();
}

class _TechnicianEditorPageState extends State<_TechnicianEditorPage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _passwordCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _shareCtrl;
  late final TextEditingController _businessCtrl;
  late final TextEditingController _hstCtrl;
  late final TextEditingController _etransferCtrl;

  late int _colorValue;
  late bool _collectsHst;
  late bool _active;

  bool _dirty = false;
  bool _saving = false;
  bool _obscurePassword = true;
  String _error = '';

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final t = widget.existing;
    _nameCtrl = TextEditingController(text: t?.name ?? '');
    _emailCtrl = TextEditingController(text: t?.email ?? '');
    _passwordCtrl = TextEditingController();
    _phoneCtrl = TextEditingController(text: t?.phone ?? '');
    _shareCtrl = TextEditingController(
      text: (t?.profitSharePercent ?? 50).toStringAsFixed(0),
    );
    _businessCtrl = TextEditingController(text: t?.businessName ?? '');
    _hstCtrl = TextEditingController(text: t?.hstNumber ?? '');
    _etransferCtrl = TextEditingController(text: t?.etransferEmail ?? '');
    _colorValue = t?.colorValue ?? TechnicianProfile.palette.first;
    _collectsHst = t?.collectsHst ?? false;
    _active = t?.active ?? true;

    for (final c in [
      _nameCtrl,
      _emailCtrl,
      _passwordCtrl,
      _phoneCtrl,
      _shareCtrl,
      _businessCtrl,
      _hstCtrl,
      _etransferCtrl,
    ]) {
      c.addListener(_markDirty);
    }
  }

  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _phoneCtrl.dispose();
    _shareCtrl.dispose();
    _businessCtrl.dispose();
    _hstCtrl.dispose();
    _etransferCtrl.dispose();
    super.dispose();
  }

  Future<bool> _save() async {
    if (_saving) return false;
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    final share =
        double.tryParse(_shareCtrl.text.trim().replaceAll(',', '.')) ?? -1;

    if (name.isEmpty) {
      setState(
        () => _error = context.tr('Введите имя мастера', 'Enter technician name'),
      );
      return false;
    }
    if (email.isEmpty || !email.contains('@')) {
      setState(
        () => _error = context.tr(
          'Введите корректный email для входа',
          'Enter a valid login email',
        ),
      );
      return false;
    }
    if (!_isEdit && password.length < 6) {
      setState(
        () => _error = context.tr(
          'Пароль должен быть не короче 6 символов',
          'Password must be at least 6 characters',
        ),
      );
      return false;
    }
    if (_isEdit && password.isNotEmpty && password.length < 6) {
      setState(
        () => _error = context.tr(
          'Новый пароль должен быть не короче 6 символов',
          'New password must be at least 6 characters',
        ),
      );
      return false;
    }
    if (share < 0 || share > 100) {
      setState(
        () => _error = context.tr(
          'Процент прибыли мастера должен быть от 0 до 100',
          'Profit share must be between 0 and 100',
        ),
      );
      return false;
    }

    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      if (_isEdit) {
        await TechnicianService.updateTechnician(
          uid: widget.existing!.uid,
          name: name,
          email: email,
          newPassword: password,
          phone: _phoneCtrl.text.trim(),
          colorValue: _colorValue,
          profitSharePercent: share,
          businessName: _businessCtrl.text.trim(),
          collectsHst: _collectsHst,
          hstNumber: _hstCtrl.text.trim(),
          etransferEmail: _etransferCtrl.text.trim(),
          active: _active,
        );
      } else {
        await TechnicianService.createTechnician(
          name: name,
          email: email,
          password: password,
          phone: _phoneCtrl.text.trim(),
          colorValue: _colorValue,
          profitSharePercent: share,
          businessName: _businessCtrl.text.trim(),
          collectsHst: _collectsHst,
          hstNumber: _hstCtrl.text.trim(),
          etransferEmail: _etransferCtrl.text.trim(),
        );
      }
      if (!mounted) return true;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      Navigator.pop(context);
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final shareVal =
        (double.tryParse(_shareCtrl.text.trim().replaceAll(',', '.')) ?? 50)
            .clamp(0.0, 100.0);
    final ownerVal = (100.0 - shareVal).clamp(0.0, 100.0);

    return ListenableBuilder(
      listenable: AppUiSettings.instance,
      builder: (context, _) {
        return DirtyLeaveScope(
          dirty: _dirty,
          onSave: _save,
          child: Scaffold(
            backgroundColor: AppColors.surface,
            appBar: AppBar(
              title: Text(
                _isEdit
                    ? context.tr('Профиль мастера', 'Technician profile')
                    : context.tr('Новый мастер', 'New technician'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              actions: [
                AppBarSaveButton(
                  dirty: _dirty,
                  saving: _saving,
                  onPressed: _save,
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
              children: [
                if (_error.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE53935).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE53935)),
                    ),
                    child: Text(
                      _error,
                      style: const TextStyle(
                        color: Color(0xFFE53935),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                _sectionCard(
                  title: context.tr('Вход и связь', 'Login & phone'),
                  children: [
                    TextField(
                      controller: _nameCtrl,
                      decoration: InputDecoration(
                        labelText: context.tr('Имя мастера', 'Technician name'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: context.tr(
                          'Email (логин для входа)',
                          'Login email',
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordCtrl,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        labelText: _isEdit
                            ? context.tr(
                                'Новый пароль (оставьте пустым, если не меняете)',
                                'New password (leave blank to keep)',
                              )
                            : context.tr(
                                'Пароль для входа (минимум 6 символов)',
                                'Login password (min 6 chars)',
                              ),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: context.tr(
                          'Личный сотовый мастера (для звонков через рабочий мост)',
                          'Technician cell phone (for call bridge)',
                        ),
                        hintText: '+1XXXXXXXXXX',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (_isEdit) ...[
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          context.tr('Доступ к приложению открыт', 'Access enabled'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          context.tr(
                            'Выключите, чтобы мгновенно закрыть вход мастеру',
                            'Turn off to revoke access immediately',
                          ),
                        ),
                        value: _active,
                        activeTrackColor: const Color(0xFF22C55E),
                        onChanged: (v) => setState(() {
                          _active = v;
                          _dirty = true;
                        }),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 14),
                _sectionCard(
                  title: context.tr(
                    'Цвет на календаре и деление чистой прибыли',
                    'Calendar color & net profit split',
                  ),
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final c in TechnicianProfile.palette)
                          GestureDetector(
                            onTap: () => setState(() {
                              _colorValue = c;
                              _dirty = true;
                            }),
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: Color(c),
                                shape: BoxShape.circle,
                                border: _colorValue == c
                                    ? Border.all(
                                        color: AppColors.ink,
                                        width: 3,
                                      )
                                    : null,
                              ),
                              child: _colorValue == c
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 18,
                                    )
                                  : null,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _shareCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: context.tr(
                          'Доля мастера от чистой прибыли (%)',
                          'Technician share of net profit (%)',
                        ),
                        suffixText: '%',
                        helperText:
                            '${context.tr('Мастеру', 'Technician')}: ${shareVal.toStringAsFixed(0)}% · ${context.tr('Тебе (офис)', 'You (office)')}: ${ownerVal.toStringAsFixed(0)}%',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _sectionCard(
                  title: context.tr(
                    'Собственные реквизиты ИП мастера для его счетов',
                    'Technician contractor details for invoices',
                  ),
                  children: [
                    Text(
                      context.tr(
                        'Клиент получает счёт от имени частного мастера, с его собственным HST и почтой для оплаты — твои налоги и твоя почта в его счетах не светятся.',
                        'Client invoices show the independent contractor details, HST and e-Transfer email instead of yours.',
                      ),
                      style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _businessCtrl,
                      decoration: InputDecoration(
                        labelText: context.tr(
                          'Название ИП мастера на счёте (если пусто — имя)',
                          'Business name on invoice (defaults to name)',
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _etransferCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: context.tr(
                          'Почта мастера для приёма e-Transfer от клиентов',
                          'Technician e-Transfer email for client payments',
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        context.tr(
                          'У мастера есть свой номер HST/GST',
                          'Technician collects own HST/GST',
                        ),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      value: _collectsHst,
                      onChanged: (v) => setState(() {
                        _collectsHst = v;
                        _dirty = true;
                      }),
                    ),
                    if (_collectsHst) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _hstCtrl,
                        decoration: InputDecoration(
                          labelText: context.tr(
                            'Личный номер HST/GST мастера',
                            'Technician HST/GST number',
                          ),
                          hintText: '123456789 RT0001',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sectionCard({
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 14.5,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}
